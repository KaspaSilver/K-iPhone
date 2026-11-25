import Foundation

// MARK: - Node Store Protocol

/// Protocol for persisting node records
protocol NodeStore: Sendable {
    func loadAll(network: NetworkType) throws -> [NodeRecord]
    func saveAll(_ records: [NodeRecord], network: NetworkType) throws
    /// The pool as it was before a node was pinned (`NodeRegistry.setTrustedNode`), kept apart
    /// from the live list until the pin is cleared.
    func loadPrePinStash(network: NetworkType) -> [NodeRecord]?
    func savePrePinStash(_ records: [NodeRecord], network: NetworkType) throws
    func removePrePinStash(network: NetworkType)
}

extension NodeStore {
    func loadPrePinStash(network: NetworkType) -> [NodeRecord]? { nil }
    func savePrePinStash(_ records: [NodeRecord], network: NetworkType) throws {}
    func removePrePinStash(network: NetworkType) {}
}

struct ActivePoolRebalanceResult: Sendable {
    let promoted: Int
    let demoted: Int
    let activeCount: Int
    let eligibleCount: Int
}

struct PrefixPerformanceStats: Sendable {
    let sampleCount: Int
    let p50LatencyMs: Double
    let averageErrorRate: Double
    let averageTcpRttMs: Double?
}

// MARK: - File Node Store

/// The node records, one JSON file per network in Application Support/NodePool: a mainnet node
/// answers a `kaspatest:` address with the mainnet chain's coins, so the two pools must never
/// mix. Up to 3,000 records used to be one UserDefaults blob, which iOS rewrites whole (and keeps
/// in memory) on every save; the first load moves an existing list over and removes the key.
final class FileNodeStore: NodeStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let directory: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NodePool", isDirectory: true)
    }

    /// The UserDefaults key an older build saved the list under.
    static func legacyKey(for network: NetworkType) -> String {
        network == .mainnet ? "com.kachat.nodepool.records" : "com.kachat.nodepool.records.testnet"
    }

    private func fileURL(for network: NetworkType) -> URL? {
        directory?.appendingPathComponent(network == .mainnet ? "records-mainnet.json" : "records-testnet.json")
    }

    /// The UserDefaults key an older build kept the pre-pin stash under.
    static func legacyPrePinKey(for network: NetworkType) -> String {
        network == .mainnet ? "com.kachat.nodepool.records.prepin" : "com.kachat.nodepool.records.prepin.testnet"
    }

    private func prePinURL(for network: NetworkType) -> URL? {
        directory?.appendingPathComponent(network == .mainnet ? "prepin-mainnet.json" : "prepin-testnet.json")
    }

    /// The pre-pin stash moves to a file beside the records, once: up to 3,000 records in
    /// UserDefaults were read into memory at every launch and rewritten whole (audit 2026-11-25
    /// N11). A file already there wins over a blob left behind.
    private func moveLegacyPrePinStashIfNeeded(network: NetworkType) {
        let key = Self.legacyPrePinKey(for: network)
        guard let legacy = defaults.data(forKey: key) else { return }
        if let url = prePinURL(for: network), FileManager.default.fileExists(atPath: url.path) {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            try write(legacy, to: prePinURL(for: network))
            defaults.removeObject(forKey: key)
            AppLog.log("[NodeRegistry] Moved the pre-pin node stash from UserDefaults to a file")
        } catch {
            AppLog.log("[NodeRegistry] Moving the pre-pin node stash to a file failed: %@", error.localizedDescription)
        }
    }

    func loadPrePinStash(network: NetworkType) -> [NodeRecord]? {
        moveLegacyPrePinStashIfNeeded(network: network)
        guard let url = prePinURL(for: network), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([NodeRecord].self, from: data)
    }

    func savePrePinStash(_ records: [NodeRecord], network: NetworkType) throws {
        try write(try JSONEncoder().encode(records), to: prePinURL(for: network))
        defaults.removeObject(forKey: Self.legacyPrePinKey(for: network))
    }

    func removePrePinStash(network: NetworkType) {
        defaults.removeObject(forKey: Self.legacyPrePinKey(for: network))
        if let url = prePinURL(for: network) { try? FileManager.default.removeItem(at: url) }
    }

    func loadAll(network: NetworkType) throws -> [NodeRecord] {
        moveLegacyPrePinStashIfNeeded(network: network)
        let key = Self.legacyKey(for: network)
        if let url = fileURL(for: network), let data = try? Data(contentsOf: url) {
            // A file written, then an old blob left behind (a crash between the two): the file wins.
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return try JSONDecoder().decode([NodeRecord].self, from: data)
        }
        guard let legacy = defaults.data(forKey: key) else { return [] }
        let records = try JSONDecoder().decode([NodeRecord].self, from: legacy)
        do {
            try write(legacy, network: network)
            defaults.removeObject(forKey: key)
            AppLog.log("[NodeRegistry] Moved %d node records from UserDefaults to a file", records.count)
        } catch {
            AppLog.log("[NodeRegistry] Moving node records to a file failed: %@", error.localizedDescription)
        }
        return records
    }

    func saveAll(_ records: [NodeRecord], network: NetworkType) throws {
        try write(try JSONEncoder().encode(records), network: network)
    }

    private func write(_ data: Data, network: NetworkType) throws {
        try write(data, to: fileURL(for: network))
    }

    private func write(_ data: Data, to url: URL?) throws {
        guard let directory, let url else {
            throw KasiaError.networkError("No Application Support directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Node Registry Actor

/// Thread-safe registry for managing node records
/// Uses actor isolation for safe concurrent access
actor NodeRegistry {
    // MARK: - Properties

    private var records: [String: NodeRecord] = [:]  // key = endpoint.key
    private let store: NodeStore?
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    /// When set (Kaspium-style fixed-node mode), `upsert` refuses every endpoint except this one.
    private var trustedNodeKey: String?
    /// A node is pinned: nothing else joins the registry (but `addPublicFallback`).
    var hasTrustedNode: Bool { trustedNodeKey != nil }
    /// The network this registry's records belong to - set by `load(network:)`, and the list
    /// every save writes to.
    private(set) var network: NetworkType = .mainnet

    // Configuration
    private let maxNodes = 3000
    /// The longest a change waits to be saved. Counted from the first unsaved change, never
    /// restarted: every keepalive ping records a result, and a restarting debounce never fired.
    private let autoSaveInterval: TimeInterval = 60

    // MARK: - Initialization

    init(store: NodeStore? = FileNodeStore()) {
        self.store = store
    }

    /// Whether a node belongs to `network`, judged by the network name it reported when profiled
    /// or, before that, by its gRPC port family. A node with neither (e.g. a TLS node on 443,
    /// never profiled) is given the benefit of the doubt until its first profile.
    static func belongs(_ record: NodeRecord, to network: NetworkType) -> Bool {
        if let name = record.profile.networkName?.lowercased(), !name.isEmpty {
            return network == .mainnet ? name == "kaspa-mainnet" : name.hasPrefix("kaspa-testnet")
        }
        let mainnetPorts: Set<Int> = [15110, 15111, 16110, 16111]
        let testnetPorts: Set<Int> = [15210, 15211, 16210, 16211]
        let otherPorts = network == .mainnet ? testnetPorts : mainnetPorts
        return !otherPorts.contains(record.endpoint.port)
    }

    /// Load the records saved for `network`. Records of the other network are dropped: before
    /// the per-network lists, both shared one list.
    func load(network: NetworkType) {
        self.network = network
        records = [:]
        guard let store = store else { return }
        do {
            let all = try store.loadAll(network: network)
            let loaded = all.filter { Self.belongs($0, to: network) }
            if loaded.count < all.count {
                AppLog.log("[NodeRegistry] Dropped %d saved %@ records that belong to the other network",
                      all.count - loaded.count, network.displayName)
            }
            records = Dictionary(loaded.map { ($0.endpoint.key, $0) }, uniquingKeysWith: { first, _ in first })

            // Quarantine and circuit-breaker verdicts are in-session protection, not a
            // permanent blacklist: persisted across launches they can depopulate the boot race
            // (quickBoot selects by state, and a prior session's failure bursts can leave most
            // records .quarantined/.suspect for up to an hour of wall-clock time). The runtime
            // epoch-change reset clears the same fields, but on a cold launch it races
            // quickBoot's candidate selection nondeterministically - so clear them here,
            // deterministically, before anything selects. updateState() then lifts the records
            // back into .candidate/.verified so every persisted node is raceable at boot.
            var sanitized = 0
            for (key, record) in records {
                var fresh = record
                let wasBlocked = fresh.health.quarantineUntil != nil
                    || fresh.health.circuitBreakerOpenUntil != nil
                    || fresh.health.consecutiveFailures > 0
                fresh.health.quarantineUntil = nil
                fresh.health.circuitBreakerOpenUntil = nil
                fresh.health.circuitBreakerFailures = 0
                fresh.health.consecutiveFailures = 0
                fresh.updateState()
                records[key] = fresh
                if wasBlocked { sanitized += 1 }
            }

            AppLog.log("[NodeRegistry] Loaded %d node records (%d cleared of stale quarantine/failure state)",
                  records.count, sanitized)
        } catch {
            AppLog.log("[NodeRegistry] Failed to load records: %@", error.localizedDescription)
        }
    }

    /// Initialize with seed nodes for the given network
    /// Note: Seeds are now populated via DNS resolution in NodeProfiler.quickBoot()
    func initializeSeeds(for network: NetworkType) {
        AppLog.log("[NodeRegistry] Seed nodes will be populated via DNS resolution")
    }

    // MARK: - CRUD Operations

    /// Get a node record by endpoint
    func get(_ endpoint: Endpoint) -> NodeRecord? {
        records[endpoint.key]
    }

    /// Get a node record by key
    func get(key: String) -> NodeRecord? {
        records[key]
    }

    /// Get all records
    func allRecords() -> [NodeRecord] {
        Array(records.values)
    }

    /// Get records filtered by state
    func records(inState state: NodeState) -> [NodeRecord] {
        records.values.filter { $0.state == state }
    }

    /// Get records that can handle an operation
    func records(canHandle op: OperationClass) -> [NodeRecord] {
        records.values.filter { $0.canHandle(op) }
    }

    /// Pins the registry to exactly one node (Kaspium-style fixed-node mode) - clears
    /// every other record and refuses to add any other one until cleared.
    ///
    /// Returns the endpoint that WAS pinned before this call, if any and if it's actually
    /// changing - a `GRPCStreamConnection` has no concept of "trusted" and will otherwise keep
    /// reconnecting to a node that's no longer relevant forever, so the caller needs this to
    /// close that now-orphaned connection (see NodePoolService.setTrustedNodeAddress).
    @discardableResult
    func setTrustedNode(_ endpoint: Endpoint?) -> Endpoint? {
        let previousEndpoint = trustedNodeKey.flatMap { records[$0]?.endpoint }

        guard let endpoint else {
            // Drop the now-stale pinned record too, so it doesn't linger with origin
            // .userAdded (which forces it "active" unconditionally - see
            // NodeRecord.updateState()) even after it's no longer actually pinned.
            if let trustedNodeKey {
                records.removeValue(forKey: trustedNodeKey)
            }
            trustedNodeKey = nil
            // Bring back the pool that existed before pinning (stashed below when the pin was
            // applied) - switching back to Automatic Scan must dial known-good nodes
            // immediately, not restart discovery from an empty registry (which previously left
            // the app with NO nodes at all until the next cold launch, because nothing after
            // this point ever re-resolved DNS seeds).
            let restored = restoreStashedRecords()
            if restored > 0 {
                AppLog.log("[NodeRegistry] Restored %d pre-pin node records for Automatic Scan", restored)
            }
            scheduleSave()
            return previousEndpoint
        }

        guard previousEndpoint?.key != endpoint.key else {
            // Re-pinning the same endpoint - nothing stale to report.
            return nil
        }

        // Entering pinned mode from Automatic Scan: stash the discovered pool before wiping it,
        // so known-good nodes survive the pinned period and can be dialed the instant the user
        // switches back. Not done when moving pin -> pin (the registry only holds the old pinned
        // record then, and overwriting the stash with it would destroy the real pre-pin pool).
        if trustedNodeKey == nil {
            stashRecordsBeforePinning(excluding: endpoint.key)
        }

        trustedNodeKey = endpoint.key
        records = records.filter { $0.key == endpoint.key }
        if records[endpoint.key] == nil {
            records[endpoint.key] = NodeRecord(endpoint: endpoint, origin: .userAdded)
        }
        scheduleSave()
        return previousEndpoint
    }

    /// Snapshot every non-pinned record so the discovered pool survives the pinned period. In a
    /// file beside the records (`FileNodeStore.savePrePinStash`), not UserDefaults.
    private func stashRecordsBeforePinning(excluding pinnedKey: String) {
        let toStash = records.values.filter { $0.endpoint.key != pinnedKey }
        guard !toStash.isEmpty, let store else { return }
        do {
            try store.savePrePinStash(Array(toStash), network: network)
            AppLog.log("[NodeRegistry] Stashed %d node records before pinning", toStash.count)
        } catch {
            AppLog.log("[NodeRegistry] Stashing node records before pinning failed: %@", error.localizedDescription)
        }
    }

    /// Restore the pre-pin snapshot into the live registry (existing keys win). The stash is
    /// consumed: records rejoin the normal lifecycle and are re-persisted with everything else.
    /// Stale entries are harmless - they fail their probes like any other node and get pruned.
    private func restoreStashedRecords() -> Int {
        guard let store, let stashed = store.loadPrePinStash(network: network) else { return 0 }
        store.removePrePinStash(network: network)
        var restored = 0
        for record in stashed where records[record.endpoint.key] == nil && Self.belongs(record, to: network) {
            // Same sanitize as load(): quarantine/circuit verdicts from the stash era are not
            // evidence about the present, and would depopulate the instant-switch race.
            var fresh = record
            fresh.health.quarantineUntil = nil
            fresh.health.circuitBreakerOpenUntil = nil
            fresh.health.circuitBreakerFailures = 0
            fresh.health.consecutiveFailures = 0
            fresh.updateState()
            records[fresh.endpoint.key] = fresh
            restored += 1
        }
        return restored
    }

    /// Insert or update a node record
    func upsert(endpoint: Endpoint, origin: NodeOrigin = .discovered) {
        if let trustedNodeKey, endpoint.key != trustedNodeKey { return }
        // Public wss nodes come only through `addPublicFallback`.
        if origin == .publicFallback { return }
        if var existing = records[endpoint.key] {
            existing.lastSeenAt = Date()
            records[endpoint.key] = existing
        } else {
            let record = NodeRecord(endpoint: endpoint, origin: origin)
            records[endpoint.key] = record
        }
        scheduleSave()
    }

    /// Update profile for an endpoint
    func updateProfile(_ endpoint: Endpoint, _ mutate: (inout NodeProfile) -> Void) {
        guard var record = records[endpoint.key] else { return }
        mutate(&record.profile)
        record.profile.lastProfiledAt = Date()
        record.updateState()
        records[endpoint.key] = record
        scheduleSave()
    }

    /// Update lightweight profile metadata without affecting profiling timestamps/state transitions.
    func updateProfileMetadata(_ endpoint: Endpoint, _ mutate: (inout NodeProfile) -> Void) {
        guard var record = records[endpoint.key] else { return }
        mutate(&record.profile)
        records[endpoint.key] = record
        scheduleSave()
    }

    /// Record a request result
    func recordResult(
        endpoint: Endpoint,
        epochId: Int,
        latencyMs: Double?,
        isTimeout: Bool,
        isError: Bool
    ) {
        guard var record = records[endpoint.key] else { return }

        if isError || isTimeout {
            record.health.recordFailure(isTimeout: isTimeout, epochId: epochId)
            // A pinned trusted node is always used regardless of health (see
            // NodePoolService.setTrustedNodeAddress / registry.upsert's trusted-only guard) -
            // quarantine is meaningless for it and was previously showing up, and blocking
            // isActiveEligible, after a handful of transient probe failures.
            if endpoint.key == trustedNodeKey {
                record.health.quarantineUntil = nil
            }
        } else if let latencyMs = latencyMs {
            record.health.recordSuccess(latencyMs: latencyMs, epochId: epochId)
        }

        let stateBefore = record.state
        record.updateState()
        records[endpoint.key] = record
        if isError || isTimeout || record.state != stateBefore {
            scheduleSave()
        } else {
            // A latency sample on a node whose standing didn't change: worth keeping, not worth
            // a write of its own. Every keepalive ping lands here, so scheduling a save made the
            // registry write itself every minute the app was open (audit 2026-11-25 N7). Saved
            // with the next real change, and on background (`NodePoolService.enterBackground`).
            isDirty = true
        }
    }

    /// Reset epoch-local stats for all nodes (called on network change)
    func resetEpochStats(newEpochId: Int) {
        for key in records.keys {
            records[key]?.health.resetForNewEpoch(newEpochId)
            records[key]?.updateState()
        }
        AppLog.log("[NodeRegistry] Reset epoch stats for %d nodes (epoch: %d)", records.count, newEpochId)
        scheduleSave()
    }

    /// Update TCP ping result for a node
    func updateTcpPingResult(
        _ endpoint: Endpoint,
        passed: Bool,
        checkedAt: Date = Date(),
        rttMs: Double? = nil
    ) {
        guard var record = records[endpoint.key] else { return }
        record.health.tcpPingPassed = passed
        record.health.tcpPingCheckedAt = checkedAt
        if let rttMs, rttMs.isFinite, rttMs > 0 {
            record.health.lastTcpRttMs = rttMs
            record.health.tcpConnectRttMs.update(sample: rttMs, alpha: 0.30)
        }
        records[endpoint.key] = record
        // Don't schedule save for TCP ping results - they're ephemeral
    }

    /// Aggregate prefix-level performance for prioritizing new/discovered nodes.
    func prefixPerformanceStats(minSamples: Int = 3) -> [String: PrefixPerformanceStats] {
        var grouped: [String: [(latency: Double, errorRate: Double, tcpRtt: Double?)]] = [:]

        for record in records.values {
            guard let prefix = Self.ipv4Prefix24(record.endpoint.host) else { continue }
            let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value
            guard let latency, latency.isFinite, latency > 0 else { continue }
            let errorRate = record.health.errorRate.value ?? record.health.globalErrorRate.value ?? 0.0
            let tcpRtt = record.health.tcpConnectRttMs.value ?? record.health.lastTcpRttMs
            grouped[prefix, default: []].append((latency, errorRate, tcpRtt))
        }

        var result: [String: PrefixPerformanceStats] = [:]
        for (prefix, values) in grouped where values.count >= minSamples {
            let latencies = values.map(\.latency).sorted()
            let p50 = latencies[latencies.count / 2]
            let avgError = values.map(\.errorRate).reduce(0, +) / Double(values.count)

            let tcpSamples = values.compactMap(\.tcpRtt)
            let avgTcp = tcpSamples.isEmpty ? nil : (tcpSamples.reduce(0, +) / Double(tcpSamples.count))

            result[prefix] = PrefixPerformanceStats(
                sampleCount: values.count,
                p50LatencyMs: p50,
                averageErrorRate: avgError,
                averageTcpRttMs: avgTcp
            )
        }
        return result
    }

    /// Remove a node
    func remove(_ endpoint: Endpoint) {
        records.removeValue(forKey: endpoint.key)
        scheduleSave()
    }

    /// Remove nodes that haven't been seen recently (LRU eviction)
    func pruneOldNodes(olderThan threshold: TimeInterval = 7 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-threshold)
        var removed = 0

        for (key, record) in records {
            // Don't remove seeds or user-added nodes
            guard record.origin == .discovered else { continue }
            // Don't remove active nodes
            guard record.state != .active else { continue }

            if record.lastSeenAt < cutoff {
                records.removeValue(forKey: key)
                removed += 1
            }
        }

        // Also enforce max size
        if records.count > maxNodes {
            let sortedByLastSeen = records.values
                .filter { $0.origin == .discovered && $0.state != .active }
                .sorted { $0.lastSeenAt < $1.lastSeenAt }

            let toRemove = records.count - maxNodes
            for record in sortedByLastSeen.prefix(toRemove) {
                records.removeValue(forKey: record.endpoint.key)
                removed += 1
            }
        }

        if removed > 0 {
            AppLog.log("[NodeRegistry] Pruned %d old nodes", removed)
            scheduleSave()
        }
    }

    /// Clear all dynamically discovered nodes and optionally reset remaining nodes to fresh state.
    func clearDiscoveredNodes(resetRemaining: Bool = true) {
        let totalBefore = records.count
        records = records.filter { $0.value.origin != .discovered }

        if resetRemaining {
            for key in records.keys {
                var record = records[key]
                record?.state = .candidate
                record?.profile = NodeProfile()
                record?.health = NodeHealth()
                record?.lastSeenAt = Date()
                if let record {
                    records[key] = record
                }
            }
        }

        let removed = totalBefore - records.count
        AppLog.log("[NodeRegistry] Cleared %d discovered nodes (kept: %d)", removed, records.count)
        scheduleSave()
    }

    /// How far behind the median DAA score an active node may be: about a minute of blocks.
    static let maxActiveDaaLag: UInt64 = 600

    /// Rebalance active node pool to keep the best latency nodes within a target band.
    /// - Parameters:
    ///   - minActive: Minimum desired active nodes when enough eligible nodes exist
    ///   - maxActive: Maximum active nodes
    ///   - maxReplacementsPerCycle: Maximum active/inactive swaps per rebalance cycle
    ///   - minImprovementRatio: Required relative latency improvement for replacement swaps
    @discardableResult
    func rebalanceActivePool(
        minActive: Int = 8,
        maxActive: Int = 12,
        maxReplacementsPerCycle: Int = 1,
        minImprovementRatio: Double = 0.15
    ) -> ActivePoolRebalanceResult {
        guard minActive > 0, maxActive >= minActive else {
            return ActivePoolRebalanceResult(
                promoted: 0,
                demoted: 0,
                activeCount: records.values.filter { $0.state == .active }.count,
                eligibleCount: 0
            )
        }

        var promoted = 0
        var demoted = 0

        // Refresh state machine decisions first.
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            let previous = record.state
            record.updateState()
            if previous == .active && record.state != .active {
                demoted += 1
            }
            records[key] = record
        }

        // Active also needs the node to have reported this network's name, and a DAA score no
        // more than `maxActiveDaaLag` behind the median (carried forward to now, as
        // NodeSelector does). `isActiveEligible` alone let a node that never said which network
        // it is on, or one far behind, serve sends and balances. When too few nodes pass that,
        // the old rule applies, rather than leaving the pool short.
        let now = Date()
        let network = self.network
        func projectedDaa(_ record: NodeRecord) -> UInt64? {
            guard let daa = record.profile.virtualDaaScore,
                  let profiledAt = record.profile.lastProfiledAt else { return nil }
            let age = now.timeIntervalSince(profiledAt)
            guard age >= 0, age <= record.profile.profileTTL else { return nil }
            let (projected, overflow) = daa.addingReportingOverflow(UInt64(age * 10))
            return overflow ? UInt64.max : projected
        }
        let namedOnNetwork: (NodeRecord) -> Bool = { record in
            guard let name = record.profile.networkName, !name.isEmpty else { return false }
            return NodeRegistry.belongs(record, to: network)
        }
        let projectedScores = records.values
            .filter { $0.isActiveEligible && namedOnNetwork($0) }
            .compactMap(projectedDaa)
            .sorted()
        let medianDaa: UInt64? = projectedScores.count >= 3 ? projectedScores[projectedScores.count / 2] : nil
        let strictFit: (NodeRecord) -> Bool = { record in
            guard record.isActiveEligible, namedOnNetwork(record) else { return false }
            guard let medianDaa, let daa = projectedDaa(record) else { return true }
            return daa >= medianDaa || medianDaa - daa <= Self.maxActiveDaaLag
        }
        let strictCount = records.values.filter(strictFit).count
        let useStrict = strictCount >= minActive
        let isFit: (NodeRecord) -> Bool = { record in
            if record.origin == .userAdded { return record.isActiveEligible }
            return useStrict ? strictFit(record) : (record.isActiveEligible && NodeRegistry.belongs(record, to: network))
        }

        // An active node that no longer fits steps down (a pinned node keeps its own rule).
        for key in Array(records.keys) {
            guard var record = records[key], record.state == .active,
                  record.origin != .userAdded, !isFit(record) else { continue }
            record.state = .verified
            records[key] = record
            demoted += 1
        }

        let compareBetter: (NodeRecord, NodeRecord) -> Bool = { lhs, rhs in
            // `rankingLatencyMs`: a WebSocket node is ranked as slower than it is (B10).
            if lhs.rankingLatencyMs != rhs.rankingLatencyMs {
                return lhs.rankingLatencyMs < rhs.rankingLatencyMs
            }

            let lhsErr = lhs.health.errorRate.value ?? lhs.health.globalErrorRate.value ?? 0
            let rhsErr = rhs.health.errorRate.value ?? rhs.health.globalErrorRate.value ?? 0
            if lhsErr != rhsErr {
                return lhsErr < rhsErr
            }

            if lhs.health.consecutiveSuccesses != rhs.health.consecutiveSuccesses {
                return lhs.health.consecutiveSuccesses > rhs.health.consecutiveSuccesses
            }

            if lhs.origin != rhs.origin {
                if lhs.origin == .userAdded { return true }
                if rhs.origin == .userAdded { return false }
            }

            return lhs.endpoint.key < rhs.endpoint.key
        }

        let eligible = records.values
            .filter { isFit($0) }
            .sorted(by: compareBetter)

        let eligibleCount = eligible.count
        let desiredCount: Int
        if eligibleCount < minActive {
            desiredCount = eligibleCount
        } else {
            desiredCount = min(maxActive, eligibleCount)
        }

        // Hard cap active nodes to maxActive by demoting worst active nodes first.
        var activeEligible = records.values
            .filter { $0.state == .active && isFit($0) }
            .sorted(by: compareBetter)

        if activeEligible.count > maxActive {
            let overflow = activeEligible.count - maxActive
            for record in activeEligible.suffix(overflow) {
                guard var stored = records[record.endpoint.key] else { continue }
                stored.state = .verified
                records[record.endpoint.key] = stored
                demoted += 1
            }

            activeEligible = records.values
                .filter { $0.state == .active && isFit($0) }
                .sorted(by: compareBetter)
        }

        // Ensure at least desiredCount active nodes by promoting best eligible nodes.
        if activeEligible.count < desiredCount {
            let needed = desiredCount - activeEligible.count
            for record in eligible where needed > promoted {
                guard var stored = records[record.endpoint.key], stored.state != .active else { continue }
                stored.state = .active
                records[record.endpoint.key] = stored
                promoted += 1
            }
        }

        // Keep active count at desiredCount if we still have excess.
        activeEligible = records.values
            .filter { $0.state == .active && isFit($0) }
            .sorted(by: compareBetter)

        if activeEligible.count > desiredCount {
            let toTrim = activeEligible.count - desiredCount
            for record in activeEligible.suffix(toTrim) {
                guard var stored = records[record.endpoint.key] else { continue }
                stored.state = .verified
                records[record.endpoint.key] = stored
                demoted += 1
            }
        }

        // In-band optimization: replace worst active nodes with clearly better candidates.
        var replacements = 0
        while replacements < maxReplacementsPerCycle {
            let activeNow = records.values
                .filter { $0.state == .active && isFit($0) }
                .sorted(by: compareBetter)

            guard activeNow.count >= minActive else { break }
            guard let worstActive = activeNow.last else { break }

            let bestInactive = eligible.first {
                guard let stored = records[$0.endpoint.key] else { return false }
                return stored.state != .active
            }

            guard let candidate = bestInactive else { break }
            guard worstActive.rankingLatencyMs.isFinite, candidate.rankingLatencyMs.isFinite else { break }
            guard worstActive.rankingLatencyMs > 0 else { break }

            let improvement = (worstActive.rankingLatencyMs - candidate.rankingLatencyMs) / worstActive.rankingLatencyMs
            guard improvement >= minImprovementRatio else { break }

            if var demotedRecord = records[worstActive.endpoint.key] {
                demotedRecord.state = .verified
                records[worstActive.endpoint.key] = demotedRecord
                demoted += 1
            }

            if var promotedRecord = records[candidate.endpoint.key] {
                promotedRecord.state = .active
                records[candidate.endpoint.key] = promotedRecord
                promoted += 1
            }

            replacements += 1
        }

        let finalActiveCount = records.values.filter { $0.state == .active }.count

        if promoted > 0 || demoted > 0 {
            AppLog.log(
                "[NodeRegistry] Rebalanced active pool: promoted=%d demoted=%d active=%d eligible=%d",
                promoted,
                demoted,
                finalActiveCount,
                eligibleCount
            )
            scheduleSave()
        }

        return ActivePoolRebalanceResult(
            promoted: promoted,
            demoted: demoted,
            activeCount: finalActiveCount,
            eligibleCount: eligibleCount
        )
    }

    // MARK: - Statistics

    /// Count of nodes by state
    func stateCounts() -> [NodeState: Int] {
        var counts: [NodeState: Int] = [:]
        for state in NodeState.allCases {
            counts[state] = 0
        }
        for record in records.values {
            counts[record.state, default: 0] += 1
        }
        return counts
    }

    /// Current pool health
    func poolHealth() -> PoolHealth {
        // A manually-pinned node is meant to always be treated as "it's working" (see
        // NodeRecord.updateState()) - the 5/2/1/0-active-node healthy/degraded/critical/failed
        // thresholds below are tuned for a large auto-discovered pool and would otherwise show
        // "Critical" for a single pinned node that's actually working completely fine.
        if trustedNodeKey != nil {
            return .healthy
        }
        let activeCount = records.values.filter { $0.state == .active }.count
        return PoolHealth(activeCount: activeCount)
    }

    /// Distinct nodes with a recent success/failure, for the blocked-network heuristic
    /// (see NodePoolService.updatePoolStats): many distinct nodes failing with zero successes
    /// while the device is online is the signature of gRPC being blocked wholesale
    /// (firewall/DPI), as opposed to a few individually-bad nodes.
    ///
    /// Only events at or after `anchor` count - the caller anchors this to the most recent
    /// boot / pin-switch / network-epoch change, so failures persisted from a previous launch
    /// or earned on a previous network path can never contribute to a verdict about this one.
    /// Chronic dead-weight candidates (known for over an hour, never once answered - e.g.
    /// seeder entries behind Cloudflare that cannot serve raw gRPC anywhere) are excluded from
    /// the failed count: they fail on every network and are evidence about nothing. Freshly
    /// discovered nodes still count, so a first launch under censorship still trips.
    func connectivitySnapshot(
        since anchor: Date,
        window: TimeInterval = 600
    ) -> (recentFailedNodes: Int, recentSuccessfulNodes: Int, failedKeys: [String]) {
        let now = Date()
        let cutoff = max(anchor, now.addingTimeInterval(-window))
        let chronicCutoff = now.addingTimeInterval(-3600)
        var failedKeys: [String] = []
        var succeeded = 0
        for record in records.values {
            if let successAt = record.health.lastSuccessAt, successAt >= cutoff {
                succeeded += 1
            } else if let failureAt = record.health.lastFailureAt, failureAt >= cutoff {
                let neverSucceeded = record.health.lastSuccessAt == nil
                let knownForever = record.firstSeenAt < chronicCutoff
                if neverSucceeded && knownForever { continue }
                failedKeys.append(record.endpoint.key)
            }
        }
        return (failedKeys.count, succeeded, failedKeys)
    }

    // MARK: - Persistence

    /// Schedule a save operation: at most `autoSaveInterval` after the first unsaved change. A
    /// save already scheduled is left alone, so a steady stream of changes still gets saved.
    private func scheduleSave() {
        isDirty = true
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(autoSaveInterval * 1_000_000_000))
            if !Task.isCancelled {
                self.persistNow()
            }
        }
    }

    /// Force immediate save
    func persistNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let store = store else { return }
        do {
            // Public fallback nodes are for this session's outage only.
            let kept = records.values.filter { $0.origin != .publicFallback }
            try store.saveAll(kept, network: network)
            isDirty = false
            AppLog.log("[NodeRegistry] Persisted %d node records", kept.count)
        } catch {
            AppLog.log("[NodeRegistry] Failed to persist records: %@", error.localizedDescription)
        }
    }

    // MARK: - Public wss fallback (NodePoolService.evaluatePublicFallback)

    /// Adds a public wRPC node found through the Kaspa resolver. Allowed while a node is pinned:
    /// it is the pinned node that can't be reached. False when it was already known.
    @discardableResult
    func addPublicFallback(_ endpoint: Endpoint) -> Bool {
        guard records[endpoint.key] == nil else { return false }
        records[endpoint.key] = NodeRecord(endpoint: endpoint, origin: .publicFallback)
        return true
    }

    func publicFallbackEndpoints() -> [Endpoint] {
        records.values.filter { $0.origin == .publicFallback }.map(\.endpoint)
    }

    /// Public stand-ins that turned out dead: added over `grace` ago and never answered, or failing
    /// since their last answer, which is over `grace` old. An idle stand-in that answered and
    /// hasn't failed since is kept. Removed here; returned so their connections can be closed.
    func removeDeadPublicFallbacks(grace: TimeInterval) -> [Endpoint] {
        let now = Date()
        var gone: [Endpoint] = []
        for record in records.values where record.origin == .publicFallback {
            let health = record.health
            let dead: Bool
            if let success = health.lastSuccessAt {
                dead = now.timeIntervalSince(success) > grace && (health.lastFailureAt ?? .distantPast) > success
            } else {
                dead = now.timeIntervalSince(record.firstSeenAt) > grace
            }
            if dead { gone.append(record.endpoint) }
        }
        for endpoint in gone { records.removeValue(forKey: endpoint.key) }
        return gone
    }

    /// Automatic Scan's wss seeds (`NodeProfiler.refreshWssSeeds`): drops those known for over
    /// `staleAfter` with no answer in that time (removed and returned, so their connections can be
    /// closed), and returns the keys of the ones left, which count toward the cap.
    func pruneWssSeeds(staleAfter: TimeInterval) -> (removed: [Endpoint], live: [String]) {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        var removed: [Endpoint] = []
        var live: [String] = []
        for record in records.values where record.endpoint.isWebSocket && record.origin == .seed {
            if record.firstSeenAt < cutoff, (record.health.lastSuccessAt ?? .distantPast) < cutoff {
                removed.append(record.endpoint)
            } else {
                live.append(record.endpoint.key)
            }
        }
        for endpoint in removed { records.removeValue(forKey: endpoint.key) }
        if !removed.isEmpty { scheduleSave() }
        return (removed, live)
    }

    /// The node answered on its own (a notification on the subscription), with no request to
    /// time: a success for the connectivity checks, without a latency sample.
    func recordAlive(endpoint: Endpoint) {
        guard var record = records[endpoint.key] else { return }
        record.health.lastSuccessAt = Date()
        record.lastSeenAt = Date()
        records[endpoint.key] = record
    }

    /// Removes every public fallback node; returns them so their connections can be closed.
    @discardableResult
    func removePublicFallbacks() -> [Endpoint] {
        let gone = publicFallbackEndpoints()
        for endpoint in gone { records.removeValue(forKey: endpoint.key) }
        return gone
    }

    /// When a node the pool found itself last answered - a gRPC node, or a wss node Automatic Scan
    /// keeps among its seeds; anything but a public fallback - and how many failed within `window`.
    func grpcConnectivity(window: TimeInterval) -> (lastSuccess: Date?, recentFailures: Int) {
        let cutoff = Date().addingTimeInterval(-window)
        var lastSuccess: Date?
        var failures = 0
        for record in records.values where record.origin != .publicFallback {
            if let at = record.health.lastSuccessAt, at > (lastSuccess ?? .distantPast) { lastSuccess = at }
            if let at = record.health.lastFailureAt, at >= cutoff { failures += 1 }
        }
        return (lastSuccess, failures)
    }

    /// Snapshot of all records (for export/debugging)
    func snapshot() -> [NodeRecord] {
        Array(records.values)
    }
}

private extension NodeRegistry {
    static func ipv4Prefix24(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }
}

// MARK: - Migration from GrpcEndpoint

extension NodeRegistry {
    /// Migrate from old GrpcEndpoint format
    func migrateFromOldFormat(_ oldEndpoints: [GrpcEndpoint]) {
        for old in oldEndpoints where old.networkType == network {
            guard let endpoint = Endpoint(url: old.url) else { continue }

            if records[endpoint.key] == nil {
                var record = NodeRecord(endpoint: endpoint)

                // Map origin
                switch old.origin {
                case .preProvisioned:
                    record.origin = .seed
                case .userAdded:
                    record.origin = .userAdded
                case .dynamic:
                    record.origin = .discovered
                }

                // Map profile
                record.profile.isSynced = true  // Assume was working
                record.profile.isUtxoIndexed = true
                if let latency = old.latencyMs {
                    record.health.globalLatencyMs.update(sample: Double(latency), alpha: 1.0)
                }
                if let daa = old.lastDaaScore {
                    record.profile.virtualDaaScore = daa
                }

                // Map state based on old pool
                switch old.pool {
                case .hot:
                    record.state = .active
                case .warm:
                    record.state = .verified
                case .cold:
                    record.state = old.errorCount > 0 ? .suspect : .profiled
                }

                record.firstSeenAt = old.dateAdded
                record.lastSeenAt = old.lastSuccessDate ?? old.dateAdded

                records[endpoint.key] = record
            }
        }

        AppLog.log("[NodeRegistry] Migrated %d endpoints from old format", oldEndpoints.count)
        scheduleSave()
    }
}
