import Foundation
import Combine

/// Subscription state
enum SubscriptionState: Equatable {
    case disconnected
    case connecting
    case subscribed
    case failover
    case failed
}

/// Manages UTXO subscriptions with sticky primary + warm standby pattern
/// Provides automatic failover and state resync on reconnection
@MainActor
final class UtxoSubscriptionManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var state: SubscriptionState = .disconnected
    @Published private(set) var primaryEndpoint: Endpoint? {
        didSet { if primaryEndpoint?.key != oldValue?.key { syncPinnedConnections() } }
    }
    @Published private(set) var standbyEndpoint: Endpoint? {
        didSet { if standbyEndpoint?.key != oldValue?.key { syncPinnedConnections() } }
    }
    /// Not `@Published`: every notification sets it - block-added ones about ten times a second
    /// on mainnet - and nothing observes it. Only the primary's handler delivers notifications, so
    /// this is also when the primary last spoke, which spares a keepalive ping (`checkPrimaryHealth`).
    private(set) var lastNotificationAt: Date?
    /// The last moment the primary subscription was verified alive: a successful subscribe, or
    /// a keepalive ping answered. Consumers that back the subscription up (the foreground
    /// contact sweep) stand down while this is recent and step in when it goes stale.
    @Published private(set) var lastHealthyAt: Date?

    // MARK: - Dependencies

    private let registry: NodeRegistry
    private let selector: NodeSelector
    private let connectionPool: GRPCConnectionPool
    private let epochMonitor: NetworkEpochMonitor

    // MARK: - State

    private var subscribedAddresses: [String] = []
    private var notificationHandlers: [UUID: (KaspaRPCNotification, Data) -> Void] = [:]
    private var primaryConnection: GRPCStreamConnection?
    private var standbyConnection: GRPCStreamConnection?
    private var primaryHandlerId: UUID?
    /// `GRPCStreamConnection.connectionGeneration` of the primary at the moment our
    /// notifyUtxosChanged request was accepted. A stream drop + transparent self-reconnect
    /// (sleep/wake, network blip, `reconnectDisconnected` on foreground) leaves `isConnected`
    /// true and getInfo pings passing while the node-side subscription is GONE - utxosChanged
    /// has no natural heartbeat, so nothing else can tell. The health check compares the live
    /// generation against this and re-sends the subscription when they differ.
    private var primaryConnectionGeneration: Int?

    /// Whether a consumer (e.g. broadcast channel scanning) currently wants block-added
    /// notifications. Piggybacks on the primary UTXO subscription connection rather than
    /// opening a second stream; re-registered automatically on every (re)connect of that
    /// connection, including failover and epoch-change resubscribes.
    private var wantsBlockAdded = false
    /// Held off while the app is in the background (`setBlockAddedSuspended`): stopped on the wire, the
    /// clients' wish kept, so the foreground brings the stream back.
    private var blockAddedSuspended = false
    /// The primary connection's current stream is registered for block-added: a start was
    /// answered on it and no stop since. A stream that reconnects loses it.
    private var blockAddedOnPrimary = false
    /// A start or stop is on its way (`applyBlockAddedState`); it re-checks when answered.
    private var blockAddedApplying = false
    private var effectiveWantsBlockAdded: Bool { wantsBlockAdded && !blockAddedSuspended }

    /// Last time an actual block-added push notification arrived (regardless of its content).
    /// Kaspa produces blocks roughly once a second, so if `wantsBlockAdded` is true and nothing
    /// has arrived in a while, the node's subscription for it has likely silently expired/dropped
    /// server-side even though the connection itself still answers pings fine (getInfo has
    /// nothing to do with whether push notifications are still flowing) - this is used to detect
    /// that and proactively re-send the subscription request rather than requiring the user to
    /// force-quit the app to recover.
    private var lastBlockAddedNotificationAt: Date?
    private let blockAddedStaleThreshold: TimeInterval = 20

    /// Health check timer
    private var healthCheckTask: Task<Void, Never>?

    /// Consecutive failures on primary
    private var primaryFailures: Int = 0
    private let maxPrimaryFailures = 1  // Immediate failover on first ping failure

    /// Failover in progress
    private var isFailingOver = false

    /// Consecutive failed failover attempts, and when the last one happened - drives backoff so
    /// repeated failures don't re-trigger an immediate retry every healthCheckInterval (15s)
    /// indefinitely. This matters most with a single manually-pinned node (nowhere else to fail
    /// over to, so every attempt just retries the same node) - without it, a node that's
    /// rejecting new streams (e.g. it's hit its own connection-capacity limit) gets hit with a
    /// fresh attempt every 15s forever, independent of and not slowed by the connection-level
    /// backoff in GRPCStreamConnection.scheduleAutoReconnect(). Reset to 0 on success.
    private var failoverAttempts: Int = 0
    private var lastFailoverAttemptAt: Date?

    /// Retries a subscribe that failed on every node. By then the health loop is gone (the
    /// subscribe's cleanup cancelled it), so nothing else would ever try again.
    private var resubscribeRetryTask: Task<Void, Never>?

    /// This manager is retrying a failed subscribe on its own backoff. It owns the retry: a
    /// consumer shouldn't run a second loop beside it.
    var isRetryingSubscribe: Bool { resubscribeRetryTask != nil }

    // MARK: - Configuration

    /// Health check interval: 15 s, or 45 s on an expensive path (cellular, hotspot, Low Data
    /// Mode), where every wake-up keeps the radio from idling. Both stay well under the ~100 s a
    /// proxy such as Cloudflare lets a connection sit idle. Read on every tick.
    private var healthCheckInterval: TimeInterval {
        epochMonitor.isExpensivePath ? 45 : 15
    }

    /// The longest the primary can go between proofs of life while healthy: a tick whose ping
    /// is spared by a notification just inside the interval, then a full interval to the next
    /// ping and its answer. Consumers that back the subscription up (ChatService's
    /// `isUtxoSubscriptionHealthy`) should trust `lastHealthyAt` for this long.
    var healthyWindow: TimeInterval {
        2 * healthCheckInterval + pingTimeout + 5
    }

    /// Ping timeout
    private let pingTimeout: TimeInterval = 5.0
    /// When the standby was last pinged (`pingStandbyIfDue`).
    private var lastStandbyPingAt: Date?
    private let standbyPingInterval: TimeInterval = 60

    // MARK: - Initialization

    init(
        registry: NodeRegistry,
        selector: NodeSelector,
        connectionPool: GRPCConnectionPool,
        epochMonitor: NetworkEpochMonitor
    ) {
        self.registry = registry
        self.selector = selector
        self.connectionPool = connectionPool
        self.epochMonitor = epochMonitor

        // Subscribe to epoch changes
        epochMonitor.onEpochChange { [weak self] _ in
            Task { @MainActor in
                await self?.handleEpochChange()
            }
        }
    }

    /// Tells the pool which connections are the subscription's (primary and standby): only those
    /// reconnect without end and are never pruned. Read when it runs, so the last change wins.
    private func syncPinnedConnections() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let keys = Set([self.primaryEndpoint?.key, self.standbyEndpoint?.key].compactMap { $0 })
            await self.connectionPool.setPinned(keys)
        }
    }

    // MARK: - Public API

    /// The subscribe running now. Subscribes run one at a time (IOS-071): two interleaving at
    /// the cleanup `await` both added a handler to the same connection, and only the last was
    /// remembered, so every utxosChanged batch arrived twice from then on.
    private var subscribeInFlight: Task<Void, Error>?

    /// Subscribe to UTXO changes for addresses
    /// Tries all capable nodes in pool in sequence, throws if all fail
    /// `reuseConnection`: when only addresses are being added on the node already serving the
    /// subscription, send the wider list on the live connection instead of tearing it down
    /// (callers that mean to change nodes - failover, epoch change, reconnects - leave it off).
    func subscribe(addresses: [String], excluding: Set<String> = [], reuseConnection: Bool = false) async throws {
        guard !addresses.isEmpty else { return }
        // Chained, never a wait loop: awaiting a task that has already finished doesn't
        // suspend, so `while let running = subscribeInFlight` spun on the main thread until the
        // finished subscribe's owner cleared it - which needs the main thread. Two subscribes
        // close together (starting a new chat) froze the app.
        let previous = subscribeInFlight
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            if reuseConnection, await self.widenLiveSubscription(to: addresses, excluding: excluding) { return }
            try await self.performSubscribe(addresses: addresses, excluding: excluding)
        }
        subscribeInFlight = task
        defer { if subscribeInFlight == task { subscribeInFlight = nil } }
        try await task.value
    }

    /// Adds addresses on the subscription that is up: the new list goes out on the primary's own
    /// connection. The full path disconnects that connection first - and it is the pooled one
    /// every other request to the node shares, so starting a chat failed whatever was in flight,
    /// paid a TLS reconnect and dropped utxosChanged for the gap. Only for a superset: dropping
    /// addresses goes the full way. False when it didn't apply or the node refused.
    private func widenLiveSubscription(to addresses: [String], excluding: Set<String>) async -> Bool {
        guard state == .subscribed, !subscribedAddresses.isEmpty,
              let conn = primaryConnection, let endpoint = primaryEndpoint,
              !excluding.contains(endpoint.key),
              Set(addresses).isSuperset(of: subscribedAddresses),
              await conn.isConnected else { return false }
        let previous = subscribedAddresses
        subscribedAddresses = addresses
        let generation = await conn.connectionGeneration
        do {
            try await sendNotifyUtxosChanged(on: conn)
        } catch {
            AppLog.log("[UtxoSub] Widening on %@ failed (%@); resubscribing", endpoint.key, error.localizedDescription)
            subscribedAddresses = previous
            return false
        }
        // a stream that flipped meanwhile is re-armed by the health check, as after a subscribe
        if primaryConnectionGeneration == nil { primaryConnectionGeneration = generation }
        AppLog.log("[UtxoSub] Subscription widened to %d addresses on %@", addresses.count, endpoint.key)
        return true
    }

    private func performSubscribe(addresses: [String], excluding: Set<String>) async throws {

        // Clean up any existing subscription state before retrying
        if state != .disconnected {
            AppLog.log("[UtxoSub] Cleaning up previous subscription state before retry")
            await cleanupExistingSubscription()
        }

        self.subscribedAddresses = addresses
        state = .connecting

        // Get all capable nodes, sorted by score
        let allCapableNodes = await selector.eligibleNodes(for: .subscribeUtxosChanged)
        let availableNodes = allCapableNodes.filter { !excluding.contains($0.endpoint.key) }

        guard !availableNodes.isEmpty else {
            state = .failed
            scheduleResubscribeRetry()
            if allCapableNodes.isEmpty {
                throw KasiaError.networkError("No capable nodes in pool (need synced + UTXO indexed)")
            } else {
                throw KasiaError.networkError("All \(allCapableNodes.count) capable nodes already tried")
            }
        }

        AppLog.log("[UtxoSub] Trying subscription on %d capable nodes", availableNodes.count)

        // Try each node in sequence until one succeeds
        var lastError: Error?
        for (index, nodeRecord) in availableNodes.enumerated() {
            // unsubscribed meanwhile: stop here rather than subscribe again
            if Task.isCancelled {
                state = .disconnected
                throw CancellationError()
            }
            let endpoint = nodeRecord.endpoint

            AppLog.log("[UtxoSub] Attempt %d/%d: trying %@", index + 1, availableNodes.count, endpoint.key)

            do {
                primaryEndpoint = endpoint

                try await subscribeOn(endpoint: endpoint, isPrimary: true)
                // Unsubscribed while that ran: undo it rather than leave it live.
                if Task.isCancelled {
                    await undoCancelledSubscribe(addresses: addresses)
                    throw CancellationError()
                }
                state = .subscribed
        lastHealthyAt = Date()
                primaryFailures = 0

                // Start health monitoring
                startHealthCheck()

                // Select standby from remaining nodes
                let standbyNodes = await selector.pickBest(
                    for: .subscribeUtxosChanged,
                    count: 2,
                    excluding: Set([endpoint.key])
                )
                if standbyNodes.count > 1 {
                    standbyEndpoint = standbyNodes[1]
                    Task {
                        await warmupStandby(standbyNodes[1])
                    }
                }

                AppLog.log("[UtxoSub] Subscribed successfully on %@", endpoint.key)
                return  // Success!

            } catch {
                // Unsubscribed meanwhile: stop here, leaving the state unsubscribe set (not
                // "failed" with a retry armed).
                if error is CancellationError { throw error }
                AppLog.log("[UtxoSub] Subscription failed on %@: %@", endpoint.key, error.localizedDescription)
                // As for a failed ping: the failure feeds the public fallback's trigger.
                await registry.recordResult(
                    endpoint: endpoint,
                    epochId: epochMonitor.epochId,
                    latencyMs: nil,
                    isTimeout: error.localizedDescription.lowercased().contains("timeout"),
                    isError: true
                )
                lastError = error
                // Continue immediately to next node
            }
        }

        // All nodes failed
        state = .failed
        scheduleResubscribeRetry()
        throw lastError ?? KasiaError.networkError("All capable nodes failed")
    }

    /// A subscribe that finished on the node after `unsubscribe()`: its handler and its start go.
    private func undoCancelledSubscribe(addresses: [String]) async {
        if let conn = primaryConnection {
            if let handlerId = primaryHandlerId { await conn.removeNotificationHandler(handlerId) }
            await Self.sendNotifyStop(addresses: addresses, on: conn)
        }
        primaryConnection = nil
        primaryHandlerId = nil
        primaryConnectionGeneration = nil
        blockAddedOnPrimary = false
        primaryEndpoint = nil
        standbyEndpoint = nil
        state = .disconnected
    }

    /// Stops utxosChanged for `addresses` on `conn`. Never with an empty list: that would stop
    /// every subscription on the stream. Best effort: a dead connection has nothing to stop.
    private static func sendNotifyStop(addresses: [String], on conn: GRPCStreamConnection) async {
        guard !addresses.isEmpty, await conn.isConnected else { return }
        var msg = Protowire_KaspadMessage()
        var req = Protowire_NotifyUtxosChangedRequestMessage()
        req.addresses = addresses
        req.command = .notifyStop
        msg.notifyUtxosChangedRequest = req
        do {
            _ = try await conn.sendRequest(msg, type: .notifyUtxosChanged,
                                           timeout: OperationClass.subscribeUtxosChanged.timeout)
            AppLog.log("[UtxoSub] Stopped utxosChanged for %d addresses on %@", addresses.count, conn.endpoint.key)
        } catch {
            AppLog.log("[UtxoSub] Stop on %@ failed: %@", conn.endpoint.key, error.localizedDescription)
        }
    }

    /// Keeps retrying on a capped backoff (1, 2, 4, 8, 16, 30, 30...s) while the subscription
    /// stays failed and wanted. What arrived meanwhile is left to the consumers' catch-up.
    /// Offline, it waits for the network instead of retrying (every attempt would fail), then
    /// starts the backoff over.
    private func scheduleResubscribeRetry() {
        guard resubscribeRetryTask == nil else { return }
        let monitor = epochMonitor
        resubscribeRetryTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                if !monitor.isOnline {
                    await monitor.waitUntilOnline()
                    attempt = 0
                }
                let backoff = min(30.0, pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                guard let self, !Task.isCancelled, self.state == .failed,
                      !self.subscribedAddresses.isEmpty else { break }
                if !monitor.isOnline { continue }
                do {
                    try await self.subscribe(addresses: self.subscribedAddresses)
                    AppLog.log("[UtxoSub] Resubscribed after %d failed retries", attempt)
                    NotificationCenter.default.post(name: .rpcSubscriptionsRestored, object: nil)
                    break
                } catch {
                    attempt += 1
                }
            }
            // unsubscribe() clears it itself, and a newer retry may have taken the slot by then
            if !Task.isCancelled { self?.resubscribeRetryTask = nil }
        }
    }

    /// Clean up existing subscription without changing state to disconnected
    private func cleanupExistingSubscription() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        // Remove notification handler from old connection
        if let conn = primaryConnection, let handlerId = primaryHandlerId {
            await conn.removeNotificationHandler(handlerId)
        }

        // Actually close the old connection(s), not just drop our reference to them - a
        // GRPCStreamConnection has no way to know it's being abandoned here, so it would
        // otherwise keep believing it's "connected" (e.g. right after a WiFi<->cellular switch,
        // before it's independently noticed the old socket is dead) and linger in the shared
        // pool - and the node it was talking to may not release that connection slot until its
        // own timeout eventually kicks in. Awaited (not fire-and-forget) so the immediately
        // following subscribeOn() on this same endpoint can't race a stale in-flight connect.
        if let conn = primaryConnection {
            await conn.disconnect()
        }
        if let conn = standbyConnection, conn !== primaryConnection {
            await conn.disconnect()
        }

        primaryConnection = nil
        standbyConnection = nil
        primaryHandlerId = nil
        primaryConnectionGeneration = nil
        blockAddedOnPrimary = false
        primaryFailures = 0
        failoverAttempts = 0
        lastFailoverAttemptAt = nil
        isFailingOver = false
    }

    /// Unsubscribe from UTXO changes
    func unsubscribe() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        // a subscribe still queued or running must not re-subscribe after this
        subscribeInFlight?.cancel()
        resubscribeRetryTask?.cancel()
        resubscribeRetryTask = nil

        // Remove notification handlers from connections
        if let conn = primaryConnection, let handlerId = primaryHandlerId {
            Task {
                await conn.removeNotificationHandler(handlerId)
            }
        }

        // A start is additive on the node's side: without a stop, the old account's addresses
        // stay subscribed on this pooled connection and their changes reach the next account's
        // handler. The stop runs in line with subscribes, so the next start comes after it and
        // a re-login on the same addresses isn't stopped behind its back.
        // The block stream stops with it: the connection stays in the pool, and the node would
        // otherwise keep pushing blocks nobody reads until the connection is pruned.
        if let conn = primaryConnection, !subscribedAddresses.isEmpty {
            let stale = subscribedAddresses
            let blocksOn = blockAddedOnPrimary
            let previous = subscribeInFlight
            subscribeInFlight = Task<Void, Error> { @MainActor in
                _ = try? await previous?.value
                await Self.sendNotifyStop(addresses: stale, on: conn)
                if blocksOn, await conn.isConnected { await self.sendNotifyBlockAdded(on: conn, start: false) }
            }
        }

        primaryConnection = nil
        standbyConnection = nil
        primaryHandlerId = nil
        primaryConnectionGeneration = nil
        blockAddedOnPrimary = false
        subscribedAddresses = []
        primaryEndpoint = nil
        standbyEndpoint = nil
        state = .disconnected

        AppLog.log("[UtxoSub] Unsubscribed")
    }

    /// Add notification handler
    func addNotificationHandler(_ handler: @escaping (KaspaRPCNotification, Data) -> Void) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    /// Remove notification handler
    func removeNotificationHandler(_ id: UUID) {
        notificationHandlers.removeValue(forKey: id)
    }

    /// Enable or disable block-added notifications on the primary connection. Disabling sends
    /// the node a stop (`command = .notifyStop`; wRPC's "unsubscribe"): without it the node kept
    /// pushing every full block, about ten a second, for the rest of the connection's life.
    func setBlockAddedWanted(_ wanted: Bool) async {
        wantsBlockAdded = wanted
        await applyBlockAddedState()
    }

    /// The app went to the background (true) or came back (false). Set synchronously by the
    /// scene phase change, before anything awaits, so a late background step can't hold the
    /// stream off in the foreground (audit 2026-11-25 N2). Stopped or started on the wire by
    /// `applyBlockAddedSuspension`; the clients' wish is kept either way.
    func setBlockAddedSuspended(_ suspended: Bool) {
        blockAddedSuspended = suspended
    }

    /// Sends the block-added stop or start the hold above calls for. `applyBlockAddedState`
    /// re-reads the hold after each answer, so a phase that flips while one is on its way ends
    /// with the latest.
    func applyBlockAddedSuspension() async {
        await applyBlockAddedState()
    }

    /// Brings the primary's block-added registration in line with what's wanted, sending a start
    /// or a stop. One at a time: a change made while one is on its way is picked up when it's
    /// answered. A failed one is retried by the next health check.
    private func applyBlockAddedState() async {
        guard !blockAddedApplying else { return }
        blockAddedApplying = true
        defer { blockAddedApplying = false }
        while state == .subscribed, let conn = primaryConnection {
            let want = effectiveWantsBlockAdded
            guard want != blockAddedOnPrimary else { return }
            guard await sendNotifyBlockAdded(on: conn, start: want) else { return }
        }
    }

    /// Sends a block-added start or stop on `conn`; true when the node answered without an error.
    /// Records the result in `blockAddedOnPrimary` while `conn` is still the primary.
    @discardableResult
    private func sendNotifyBlockAdded(on conn: GRPCStreamConnection, start: Bool) async -> Bool {
        var msg = Protowire_KaspadMessage()
        var req = Protowire_NotifyBlockAddedRequestMessage()
        req.command = start ? .notifyStart : .notifyStop
        msg.notifyBlockAddedRequest = req
        do {
            let response = try await conn.sendRequest(
                msg,
                type: .notifyBlockAdded,
                timeout: OperationClass.subscribeUtxosChanged.timeout
            )
            if case .notifyBlockAddedResponse(let r) = response.payload, r.hasError, !r.error.message.isEmpty {
                throw KasiaError.networkError(r.error.message)
            }
            if start {
                // Baseline the staleness clock from here, not from the next actual notification -
                // otherwise a node that's simply slow for the first block after subscribing would
                // look "stale" and trigger an immediate, unnecessary re-send.
                lastBlockAddedNotificationAt = Date()
            } else {
                AppLog.log("[UtxoSub] Stopped block-added notifications on %@", conn.endpoint.key)
            }
            if primaryConnection === conn { blockAddedOnPrimary = start }
            return true
        } catch {
            AppLog.log("[UtxoSub] Failed to %@ block-added notifications: %@",
                       start ? "register" : "stop", error.localizedDescription)
            return false
        }
    }

    /// Reconnect to lowest latency node if not already connected to it
    func reconnectToBestNodeIfNeeded() async {
        // Act whenever we're not actively mid-attempt - deliberately NOT gated on
        // state == .subscribed only. This is called right after switching/clearing the trusted
        // node (see NodePoolService.setTrustedNodeAddress); if the old pinned node was already
        // broken (state .failed/.disconnected, e.g. it was rejecting connections), gating on
        // .subscribed meant this silently did nothing, leaving the app never subscribed to the
        // new node at all.
        guard state != .connecting, state != .failover else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Get best nodes
        let eligibleNodes = await selector.eligibleNodes(for: .subscribeUtxosChanged)
        guard let bestNode = eligibleNodes.first else { return }

        // Check if we're already connected to the best node - only meaningful when we're
        // actually subscribed; a stale primaryEndpoint from a broken prior state isn't grounds
        // to skip reconnecting.
        if state == .subscribed, let currentPrimary = primaryEndpoint, currentPrimary.key == bestNode.endpoint.key {
            AppLog.log("[UtxoSub] Already connected to best node: %@", currentPrimary.key)
            return
        }

        // Get latency info for logging
        let bestLatency = bestNode.health.latencyMs.value ?? bestNode.health.globalLatencyMs.value ?? 0
        let currentLatency: Double?
        if let currentPrimary = primaryEndpoint {
            let currentRecord = await registry.get(currentPrimary)
            currentLatency = currentRecord?.health.latencyMs.value ?? currentRecord?.health.globalLatencyMs.value
        } else {
            currentLatency = nil
        }

        AppLog.log("[UtxoSub] Pool is healthy - reconnecting to lowest latency node: %@ (%.0fms, was: %@)",
              bestNode.endpoint.key,
              bestLatency,
              currentLatency.map { String(format: "%.0fms", $0) } ?? "none")

        // Resubscribe to best node
        let wasSubscribed = state == .subscribed
        do {
            try await subscribe(addresses: subscribedAddresses)
            // Every route that brings a broken subscription back (the stats pass, the public
            // fallback's adopt and hand-back, a pin switch) says so, as the retry loop does: the
            // consumers put their handlers back and catch up the dead window. Without it a
            // pending retry saw `.subscribed` and stopped quietly, and nothing read utxosChanged
            // (audit 2026-11-25 N1). Not after a plain move between two live nodes.
            if !wasSubscribed, state == .subscribed {
                NotificationCenter.default.post(name: .rpcSubscriptionsRestored, object: nil)
            }
        } catch {
            AppLog.log("[UtxoSub] Failed to reconnect to best node: %@", error.localizedDescription)
        }
    }

    /// Reconnect to a specific endpoint (triggered by better node detection)
    func reconnectToEndpoint(_ endpoint: Endpoint) async {
        // Only reconnect if currently subscribed
        guard state == .subscribed else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Check if we're already connected to this endpoint
        if let currentPrimary = primaryEndpoint, currentPrimary.key == endpoint.key {
            AppLog.log("[UtxoSub] Already connected to endpoint: %@", endpoint.key)
            return
        }

        // Get latency info for logging
        let targetRecord = await registry.get(endpoint)
        let targetLatency = targetRecord?.health.latencyMs.value ?? targetRecord?.health.globalLatencyMs.value ?? 0

        let currentLatency: Double?
        if let currentPrimary = primaryEndpoint {
            let currentRecord = await registry.get(currentPrimary)
            currentLatency = currentRecord?.health.latencyMs.value ?? currentRecord?.health.globalLatencyMs.value
        } else {
            currentLatency = nil
        }

        AppLog.log("[UtxoSub] Reconnecting to better node: %@ (%.0fms, was: %@)",
              endpoint.key,
              targetLatency,
              currentLatency.map { String(format: "%.0fms", $0) } ?? "none")

        // Resubscribe to target node
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            AppLog.log("[UtxoSub] Failed to reconnect to better node: %@", error.localizedDescription)
        }
    }

    // MARK: - Internal Subscription

    private func subscribeOn(endpoint: Endpoint, isPrimary: Bool) async throws {
        let conn = await connectionPool.connection(for: endpoint)

        // Connect if needed
        if await !conn.isConnected {
            try await conn.connect()
        }

        // Read the generation BEFORE sending: if the stream flips between the request and the
        // health check, the next tick sees a newer generation and re-arms (never the reverse).
        let generationAtSubscribe = await conn.connectionGeneration

        // Subscribe request
        let subscribeStart = Date()
        try await sendNotifyUtxosChanged(on: conn)

        // An accepted subscription is a full request/response roundtrip - record it so the
        // registry (and the blocked-network detector reading it) sees this success immediately,
        // not only at the next 15s health ping.
        await registry.recordResult(
            endpoint: endpoint,
            epochId: epochMonitor.epochId,
            latencyMs: Date().timeIntervalSince(subscribeStart) * 1000,
            isTimeout: false,
            isError: false
        )

        // One handler per subscription (IOS-071): the old primary's handler goes first - on the
        // same pooled connection (one node, a failover back to it) it would otherwise deliver
        // every batch a second time; on another node, that connection is closed too.
        if isPrimary, let old = primaryConnection {
            if let oldId = primaryHandlerId { await old.removeNotificationHandler(oldId) }
            primaryHandlerId = nil
            if old !== conn {
                await old.disconnect()
                primaryConnection = nil
            }
        }

        // Add notification handler to connection
        let handlerId = await conn.addNotificationHandler { [weak self] type, data in
            Task { @MainActor in
                self?.handleNotification(type, data: data)
            }
        }

        if isPrimary {
            primaryConnection = conn
            primaryHandlerId = handlerId
            primaryConnectionGeneration = generationAtSubscribe
            // A different connection, or this one's stream since replaced: not registered yet.
            blockAddedOnPrimary = false
            // The old primary's last word says nothing about this one (`checkPrimaryHealth`).
            lastNotificationAt = nil
            if effectiveWantsBlockAdded {
                await sendNotifyBlockAdded(on: conn, start: true)
            }
        } else {
            standbyConnection = conn
        }
    }

    /// Send the notifyUtxosChanged request for `subscribedAddresses` on `conn` and validate
    /// the response. Used both for the initial subscribe and for re-arming a subscription the
    /// node silently dropped when the underlying stream reconnected.
    private func sendNotifyUtxosChanged(on conn: GRPCStreamConnection) async throws {
        // An empty start means EVERY address to a node: never send one (an unsubscribe can
        // clear the list while a subscribe is still on its way).
        guard !subscribedAddresses.isEmpty else {
            throw KasiaError.networkError("No addresses to subscribe")
        }
        var msg = Protowire_KaspadMessage()
        var req = Protowire_NotifyUtxosChangedRequestMessage()
        req.addresses = subscribedAddresses
        msg.notifyUtxosChangedRequest = req

        let response = try await conn.sendRequest(
            msg,
            type: .notifyUtxosChanged,
            timeout: OperationClass.subscribeUtxosChanged.timeout
        )

        guard case .notifyUtxosChangedResponse(let subResponse) = response.payload else {
            throw KasiaError.networkError("Unexpected response type")
        }

        if subResponse.hasError && !subResponse.error.message.isEmpty {
            throw KasiaError.networkError(subResponse.error.message)
        }
    }

    // MARK: - Notification Handling

    private func handleNotification(_ type: KaspaRPCNotification, data: Data) {
        let now = Date()
        lastNotificationAt = now
        if type == .blockAdded {
            lastBlockAddedNotificationAt = now
        }
        // The primary speaking is as good as an answered ping. Throttled: blocks come ten a
        // second, and `lastHealthyAt` is published.
        if state == .subscribed, now.timeIntervalSince(lastHealthyAt ?? .distantPast) > 5 {
            lastHealthyAt = now
        }

        // Forward to all handlers
        for handler in notificationHandlers.values {
            handler(type, data)
        }
    }

    // MARK: - Health Monitoring

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.healthCheckInterval * 1_000_000_000))

                if !Task.isCancelled {
                    await checkPrimaryHealth()
                }
            }
        }
    }

    private func checkPrimaryHealth() async {
        guard let endpoint = primaryEndpoint, let conn = primaryConnection else { return }

        // Check if connection is still active
        if await !conn.isConnected {
            await handlePrimaryFailure()
            return
        }

        // Check if circuit breaker is open
        if await conn.isCircuitOpen {
            await handlePrimaryFailure()
            return
        }

        // The primary pushed a notification within the interval: it is alive and the stream
        // isn't idle, so the ping is spared (on a quiet subscription it still goes every tick).
        // Not when the stream was re-established since we subscribed: that needs the re-arm below.
        let interval = healthCheckInterval
        if let spoke = lastNotificationAt, Date().timeIntervalSince(spoke) < interval,
           await conn.connectionGeneration == primaryConnectionGeneration {
            primaryFailures = 0
            if spoke > (lastHealthyAt ?? .distantPast) { lastHealthyAt = spoke }
            await registry.recordAlive(endpoint: endpoint)
            await pingStandbyIfDue()
            await afterHealthyTick(conn: conn)
            return
        }

        // Send ping (getInfo) request to keep connection alive
        do {
            var msg = Protowire_KaspadMessage()
            msg.getInfoRequest = Protowire_GetInfoRequestMessage()

            let startTime = Date()
            _ = try await conn.sendRequest(msg, type: .getInfo, timeout: pingTimeout)
            let latencyMs = Date().timeIntervalSince(startTime) * 1000

            // Connection is alive
            primaryFailures = 0
            lastHealthyAt = Date()

            // Feed the success into the registry: the subscription is the app's primary
            // long-lived connection, but its pings previously left no trace there, so the
            // blocked-network detector (which reads registry lastSuccessAt) could see "zero
            // recent successes" while a perfectly healthy subscription was pinging every 15s.
            // Also keeps the primary's health/latency fresh between (slow) profiler probes.
            await registry.recordResult(
                endpoint: endpoint,
                epochId: epochMonitor.epochId,
                latencyMs: latencyMs,
                isTimeout: false,
                isError: false
            )

            AppLog.log("[UtxoSub] Ping OK on %@ (%.0fms)", endpoint.key, latencyMs)
            await pingStandbyIfDue()

            // The node answers again after a failover that found nothing: subscribe once more.
            if state == .failed {
                scheduleResubscribeRetry()
                return
            }

        } catch {
            AppLog.log("[UtxoSub] Ping failed on %@ - triggering immediate failover: %@", endpoint.key, error.localizedDescription)
            // Into the registry too: with a pinned node the profiler no longer probes it, and the
            // public fallback (`NodePoolService.evaluatePublicFallback`) starts on recent failures.
            await registry.recordResult(
                endpoint: endpoint,
                epochId: epochMonitor.epochId,
                latencyMs: nil,
                isTimeout: error.localizedDescription.lowercased().contains("timeout"),
                isError: true
            )
            await handlePrimaryFailure()
            return
        }

        // A ping that succeeds on a stream that was transparently re-established since we
        // subscribed is the silent-loss case: the node forgot our utxosChanged subscription
        // with the old stream, and this is the ONLY signal we have (no heartbeat exists for
        // utxosChanged). Re-arm it on the same connection before anything else.
        await resubscribeIfPrimaryReconnected(conn: conn, endpoint: endpoint)

        await afterHealthyTick(conn: conn)
    }

    /// The rest of a health tick on a primary that's alive: block-added brought in line (a start
    /// or stop that failed earlier goes again), and a block stream gone quiet re-registered.
    private func afterHealthyTick(conn: GRPCStreamConnection) async {
        guard state == .subscribed, primaryConnection === conn else { return }
        await applyBlockAddedState()

        // The ping above only proves the connection still answers requests - it says nothing
        // about whether the node is still actually pushing block-added notifications on it. Kaspa
        // produces a block roughly every second, so total silence for this long while we still
        // want them means that specific subscription silently died server-side; re-register it.
        if effectiveWantsBlockAdded, blockAddedOnPrimary {
            let staleness = lastBlockAddedNotificationAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if staleness > blockAddedStaleThreshold {
                AppLog.log("[UtxoSub] Block-added notifications stale (%.0fs) - re-registering", staleness)
                await sendNotifyBlockAdded(on: conn, start: true)
            }
        }
    }

    /// Re-arm the utxosChanged subscription if the primary stream was re-established since we
    /// subscribed (see `primaryConnectionGeneration`). Safe to call any time: no-op unless we're
    /// `.subscribed` and the generation moved. Called from the 15s health check and eagerly from
    /// `NodePoolService.reconnectStaleConnections()` on app foreground, so a subscription lost
    /// while backgrounded is restored immediately rather than up to a health tick later.
    func verifyPrimarySubscription() async {
        guard state == .subscribed, let endpoint = primaryEndpoint, let conn = primaryConnection else { return }
        guard await conn.isConnected else { return }
        await resubscribeIfPrimaryReconnected(conn: conn, endpoint: endpoint)
    }

    private func resubscribeIfPrimaryReconnected(conn: GRPCStreamConnection, endpoint: Endpoint) async {
        guard state == .subscribed else { return }
        let liveGeneration = await conn.connectionGeneration
        guard let subscribedGeneration = primaryConnectionGeneration, liveGeneration != subscribedGeneration else {
            return
        }

        AppLog.log("[UtxoSub] Primary %@ reconnected underneath us (gen %d -> %d) - re-sending utxosChanged subscription for %d addresses",
                   endpoint.key, subscribedGeneration, liveGeneration, subscribedAddresses.count)
        do {
            // The notification handler registered in subscribeOn() survives the reconnect (it's
            // keyed on the GRPCStreamConnection, not the stream), so only the request is re-sent.
            try await sendNotifyUtxosChanged(on: conn)
            primaryConnectionGeneration = liveGeneration
            // The old stream's block-added registration went with it.
            blockAddedOnPrimary = false
            if effectiveWantsBlockAdded {
                await sendNotifyBlockAdded(on: conn, start: true)
            }
            AppLog.log("[UtxoSub] utxosChanged subscription re-armed on %@", endpoint.key)
            // Anything that confirmed during the dead window never reached us - let ChatService
            // run its catch-up sync (observer of this name; honors push-reliability debounce).
            NotificationCenter.default.post(name: .rpcSubscriptionsRestored, object: nil)
        } catch {
            AppLog.log("[UtxoSub] Re-arming subscription on %@ failed: %@ - failing over", endpoint.key, error.localizedDescription)
            await handlePrimaryFailure()
        }
    }

    // MARK: - Failover

    private func handlePrimaryFailure() async {
        primaryFailures += 1

        // Immediate failover on first failure
        if primaryFailures >= maxPrimaryFailures {
            await failoverInQueue()
        }
    }

    /// The failover, in line with subscribes (`subscribeInFlight`): one running beside a
    /// subscribe both called `subscribeOn`, leaking a handler (every batch twice) and writing
    /// the failover's endpoints over the fresh subscription. Once its turn comes it runs only if
    /// nothing replaced the failing primary meanwhile and the subscription is still wanted.
    private func failoverInQueue() async {
        let failing = primaryEndpoint
        let previous = subscribeInFlight
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard self.state != .disconnected, !self.subscribedAddresses.isEmpty,
                  self.primaryEndpoint == failing, self.primaryFailures >= self.maxPrimaryFailures else { return }
            await self.performFailover()
        }
        subscribeInFlight = task
        defer { if subscribeInFlight == task { subscribeInFlight = nil } }
        _ = try? await task.value
    }

    private func performFailover() async {
        guard !isFailingOver else { return }

        // Capped exponential backoff (1, 2, 4, 8, 16, 30, 30...s) between attempts once at
        // least one has already failed - see failoverAttempts' doc comment.
        if failoverAttempts > 0, let lastAttempt = lastFailoverAttemptAt {
            let backoff = min(30.0, pow(2.0, Double(failoverAttempts - 1)))
            guard Date().timeIntervalSince(lastAttempt) >= backoff else { return }
        }
        failoverAttempts += 1
        lastFailoverAttemptAt = Date()

        isFailingOver = true
        state = .failover

        AppLog.log("[UtxoSub] Starting failover from %@", primaryEndpoint?.key ?? "unknown")

        // Try standby first
        if let standby = standbyEndpoint {
            do {
                try await subscribeOn(endpoint: standby, isPrimary: true)

                // Demote old primary, promote standby
                let oldPrimary = primaryEndpoint
                primaryEndpoint = standby
                standbyEndpoint = oldPrimary  // Can try to recover later

                // Resync state by fetching current UTXOs
                await resyncUtxoState()

                state = .subscribed
        lastHealthyAt = Date()
                primaryFailures = 0
                failoverAttempts = 0
                isFailingOver = false

                AppLog.log("[UtxoSub] Failover to standby successful: %@", standby.key)
                return

            } catch {
                AppLog.log("[UtxoSub] Standby failover failed: %@", error.localizedDescription)
            }
        }

        // Standby failed or not available, pick new endpoints
        if let selection = await selector.pickPrimaryAndStandby(for: .subscribeUtxosChanged) {
            do {
                try await subscribeOn(endpoint: selection.primary, isPrimary: true)
                primaryEndpoint = selection.primary
                standbyEndpoint = selection.standby

                await resyncUtxoState()

                state = .subscribed
        lastHealthyAt = Date()
                primaryFailures = 0
                failoverAttempts = 0
                isFailingOver = false

                AppLog.log("[UtxoSub] Failover to new primary: %@", selection.primary.key)
                return

            } catch {
                AppLog.log("[UtxoSub] New primary failover failed: %@", error.localizedDescription)
            }
        }

        // Complete failure
        state = .failed
        isFailingOver = false
        AppLog.log("[UtxoSub] Failover failed - no working endpoints")
        // Nothing else would try again: the health check only re-arms a subscribed primary.
        scheduleResubscribeRetry()
    }

    // MARK: - State Resync

    /// After a failover: what confirmed during the dead window is caught up by the consumers'
    /// own catch-up (ChatService's debounced sync, AddressActivityNotifier's balance diff), as
    /// when a subscription is re-armed. The node's current UTXO set used to be replayed as a
    /// utxosChanged batch - every old coin arrived as newly "added" (the response's entries share
    /// field 1 with `added`), firing "Received X KAS" for months-old funds and a REST fetch per
    /// coin (IOS-070).
    private func resyncUtxoState() async {
        guard let primary = primaryEndpoint else { return }
        AppLog.log("[UtxoSub] Failover on %@: asking for a catch-up sync", primary.key)
        NotificationCenter.default.post(name: .rpcSubscriptionsRestored, object: nil)
    }

    // MARK: - Standby Warmup

    /// Keep standby connection warm
    /// The standby is warmed once and then carries nothing. A proxy in front of a node closes a
    /// connection idle for about 100 s (Cloudflare does), and a pinned standby reconnects without
    /// end, so it was cut and redialed every couple of minutes. A GetInfo on it every 60 s keeps
    /// it open - on the health check's own tick, so it costs no extra wake-up (every tick when
    /// ticks are 45 s apart, on an expensive path).
    private func pingStandbyIfDue() async {
        // Every 60 s on 15 s ticks (Wi-Fi). `min(60, tick) - 1` made it every 14 s there, four
        // times the traffic meant (audit 2026-11-25 N6). On 45 s ticks every tick: waiting for
        // the second (90 s) would come close to a proxy's ~100 s idle cut.
        let tick = healthCheckInterval
        let due = (tick * 2 > standbyPingInterval ? tick : standbyPingInterval) - 1
        guard Date().timeIntervalSince(lastStandbyPingAt ?? .distantPast) >= due else { return }
        guard let conn = standbyConnection, await conn.isConnected else { return }
        lastStandbyPingAt = Date()
        var msg = Protowire_KaspadMessage()
        msg.getInfoRequest = Protowire_GetInfoRequestMessage()
        let startTime = Date()
        do {
            _ = try await conn.sendRequest(msg, type: .getInfo, timeout: pingTimeout)
            await registry.recordResult(
                endpoint: conn.endpoint,
                epochId: epochMonitor.epochId,
                latencyMs: Date().timeIntervalSince(startTime) * 1000,
                isTimeout: false,
                isError: false
            )
        } catch {
            // it reconnects on its own; the next failover finds out whether it's any use
            AppLog.log("[UtxoSub] Standby keepalive failed on %@: %@", conn.endpoint.key, error.localizedDescription)
        }
    }

    private func warmupStandby(_ endpoint: Endpoint) async {
        let conn = await connectionPool.connection(for: endpoint)

        do {
            if await !conn.isConnected {
                try await conn.connect()
            }

            // Verify node is responsive with getInfo
            var msg = Protowire_KaspadMessage()
            msg.getInfoRequest = Protowire_GetInfoRequestMessage()
            _ = try await conn.sendRequest(msg, type: .getInfo, timeout: 5)

            // Explicitly reset circuit breaker after successful warmup
            await conn.resetCircuitBreaker()

            standbyConnection = conn
            lastStandbyPingAt = Date()
            AppLog.log("[UtxoSub] Standby warmed up: %@", endpoint.key)

        } catch {
            AppLog.log("[UtxoSub] Standby warmup failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Background

    /// Closes the pool's connections that carry nothing the app needs while in the background:
    /// every one but the subscription's primary and standby (none, once push mode has
    /// unsubscribed) and those with a request waiting. Includes the former primary, which
    /// `unsubscribe()` left open. Requests in the foreground dial again on demand.
    /// `stillInBackground` is asked before each close: the app coming back stops the closing.
    /// The subscription's endpoints are read again then too, so one a foreground subscribe has
    /// just picked is kept (audit 2026-11-25 N2).
    func closeIdleConnectionsForBackground(stillInBackground: @escaping @MainActor @Sendable () -> Bool) async {
        let keep = Set([primaryEndpoint?.key, standbyEndpoint?.key].compactMap { $0 })
        await connectionPool.closeIdleConnections(keeping: keep) { [weak self] key in
            let manager = self
            return await MainActor.run {
                guard stillInBackground(), let manager else { return false }
                return key != manager.primaryEndpoint?.key && key != manager.standbyEndpoint?.key
            }
        }
    }

    // MARK: - Epoch Changes

    /// A GetInfo on the primary; true when it answered in time.
    private func pingPrimary(_ conn: GRPCStreamConnection, timeout: TimeInterval) async -> Bool {
        var msg = Protowire_KaspadMessage()
        msg.getInfoRequest = Protowire_GetInfoRequestMessage()
        return (try? await conn.sendRequest(msg, type: .getInfo, timeout: timeout)) != nil
    }

    private func handleEpochChange() async {
        // Deliberately not gated on state == .subscribed - a WiFi<->cellular switch (or any
        // other path change) can happen while the subscription is already broken for an
        // unrelated reason (e.g. .failed/.disconnected), and that's exactly when resubscribing
        // matters most. Gating on .subscribed only meant a phone that flips networks while
        // already disconnected just stayed disconnected until something else happened to retry.
        guard state != .connecting, state != .failover else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Many path changes leave the primary's socket working (a VPN coming up, an interface
        // appearing beside the one in use). Ask it first: if it answers, the subscription is
        // kept (re-armed on the same connection if its stream was re-established meanwhile),
        // with no teardown and no full catch-up. A socket the change killed fails the ping.
        if state == .subscribed, let conn = primaryConnection, let endpoint = primaryEndpoint,
           await conn.isConnected, await pingPrimary(conn, timeout: 3) {
            AppLog.log("[UtxoSub] Network epoch changed - primary %@ still answers, subscription kept", endpoint.key)
            lastHealthyAt = Date()
            await resubscribeIfPrimaryReconnected(conn: conn, endpoint: endpoint)
            return
        }

        AppLog.log("[UtxoSub] Network epoch changed - resubscribing")

        // Resubscribe to current addresses
        do {
            try await subscribe(addresses: subscribedAddresses)
            // The old path's socket died with the change: what arrived in between needs catching up.
            NotificationCenter.default.post(name: .rpcSubscriptionsRestored, object: nil)
        } catch {
            // performSubscribe has armed the retry if this was a real failure
            AppLog.log("[UtxoSub] Resubscription after epoch change failed: %@", error.localizedDescription)
        }
    }
}
