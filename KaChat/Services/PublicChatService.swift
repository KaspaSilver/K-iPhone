import Foundation
import Combine
import UIKit
import UserNotifications

/// KaChat 2.0 Public Chat feature: public, unencrypted, many-to-many channels.
/// Swift analog of the Android client's `PublicChatRepository` + `PublicChatScanningService`
/// combined - join/leave channels, send public chats, and scan new blocks for messages in
/// channels that are currently "wanted" (always-listen or actively viewed).
@MainActor
final class PublicChatService: ObservableObject {
    static let shared = PublicChatService()

    /// Hardcoded curated channels pinned to the top of the list, matching Android. Like every
    /// default room they are joined for every account (see `ensureDefaultChannelsJoined`), and
    /// these two start with notifications on.
    /// nonisolated: read from PublicChatStore's background prune (retention rule) as well as
    /// main-actor UI - immutable Sendable value, safe from anywhere.
    nonisolated static let featuredChannels = ["kaspa", "kachat-bugs"]

    /// Curated per-language rooms, listed straight in Public Chats under the two featured rooms
    /// (KaPosts lists every default room; the customize button switches off the unwanted ones).
    /// Indexer-tracked exactly like the featured rooms (30-day retention, indexer history, no
    /// retention gear, remote-push eligible). They are joined like the featured rooms but with
    /// notifications OFF, which is what keeps them cheap: the closed-room sweep and the push
    /// registration only cover rooms whose bell is on.
    /// Ordered alphabetically by display name, Latin scripts first (see `languageDisplayName`).
    nonisolated static let languageChannels = [
        "kaspa-indonesia",
        "kaspa-czech",
        "kaspa-german",
        "kaspa-espanol",
        "kaspa-francais",
        "kaspa-portugues",
        "kaspa-romania",
        "kaspa-slovak",
        "kaspa-russian",
        "kaspa-chinese",
        "kaspa-japanese",
        "kaspa-korean",
        "kaspa-hebrew",
    ]

    /// The rooms the app ships as defaults (Popular + the language rooms): always in the list,
    /// switched off rather than left, "Popular" in Room Info. Only auto-join and the pinned
    /// Popular list use `featuredChannels` alone.
    nonisolated static let curatedChannels = featuredChannels + languageChannels

    /// Whether the indexer keeps this room's history: the curated rooms, and any other room the
    /// indexer tracks - one the operator adds on the indexer (it then keeps 30 days of it) needs
    /// no app update. EVERYTHING that follows from "the indexer serves this room's history" keys
    /// off this - 30-day retention, remote-push registration, the block-stream skip,
    /// the push-covered local-banner skip, the "even when the app is closed" wording. See
    /// `IndexerTrackedRooms` for how the app learns the extra rooms.
    nonisolated static func isIndexerTracked(_ channel: String) -> Bool {
        let name = PublicChatChannelName.normalize(channel)
        return curatedChannels.contains(name) || IndexerTrackedRooms.contains(name)
    }

    /// Every room `isIndexerTracked` says yes to, as far as this phone knows.
    nonisolated static var indexerTrackedChannels: Set<String> {
        Set(curatedChannels).union(IndexerTrackedRooms.all())
    }

    /// Rooms the app uses as machinery, never shown as chats: the chess arena
    /// (ONLINE_CHESS.md). Hidden from Public Chats, no unread, no banners.
    nonisolated static let serviceChannels: Set<String> = [ChessTournamentCodec.arenaChannel]

    /// Native-language label for a curated language room, e.g. "kaspa-espanol" -> "Español".
    /// Native names (not English ones) so a speaker scanning the list finds their own language.
    nonisolated static func languageDisplayName(for channel: String) -> String? {
        switch PublicChatChannelName.normalize(channel) {
        case "kaspa-indonesia": return "Bahasa Indonesia"
        case "kaspa-czech": return "Čeština"
        case "kaspa-german": return "Deutsch"
        case "kaspa-espanol": return "Español"
        case "kaspa-francais": return "Français"
        case "kaspa-portugues": return "Português"
        case "kaspa-romania": return "Română"
        case "kaspa-slovak": return "Slovenčina"
        case "kaspa-russian": return "Русский"
        case "kaspa-chinese": return "中文"
        case "kaspa-japanese": return "日本語"
        case "kaspa-korean": return "한국어"
        case "kaspa-hebrew": return "עברית"
        default: return nil
        }
    }

    @Published private(set) var channels: [PublicChatChannel] = []
    @Published private(set) var messagesByChannel: [String: [PublicChatMessage]] = [:]
    /// Long voice notes in each room's loaded messages (`PublicChatVoiceParts`), worked out with
    /// them in `reloadMessages`, so the room draws each note as one bubble without sniffing
    /// every row on every pass. Set before `messagesByChannel`, which is what redraws.
    private(set) var voiceNotesByChannel: [String: PublicChatVoiceParts.Result] = [:]
    /// Each room's loaded messages by id (not the arena's), set with `messagesByChannel`: what a
    /// reply quotes is drawn from the message itself (`message(id:inChannel:)`), never from the
    /// sender and text the reply claims (audit #18).
    private var messagesByIdByChannel: [String: [String: PublicChatMessage]] = [:]
    /// This wallet's public chat reactions, keyed by channel then by targetTxId - mirrors
    /// KaChat's `GroupChatService.reactionsByGroupId`'s shape (as `PublicChatReactionSnapshot`,
    /// see `PublicChatStore.fetchReactions`). Loaded per channel on open (`acquire`) and kept
    /// live afterward by `sendPublicChatReaction` / the incoming-reaction interception in
    /// `processPublicChatHits` and `fetchFromIndexerAndMerge`.
    @Published private(set) var reactionsByChannel: [String: [String: [PublicChatReactionSnapshot]]] = [:]
    /// The newest edit per message txId, per room - see `MessageEditCodec`.
    @Published private(set) var editsByChannel: [String: [String: MessageEditSnapshot]] = [:]
    /// The room message whose text the composer is editing (the user's own) - see `sendPublicChatEdit`.
    @Published var editingMessage: PublicChatMessage?
    @Published var lastSendError: KasiaError?
    @Published var replyingTo: PublicChatMessage?
    /// Room edits whose send failed, by channel then target txId: the text, for Retry. The row
    /// itself goes back to what it read before, since that text never reached the chain.
    @Published private(set) var failedEditsByChannel: [String: [String: String]] = [:]
    /// Rows of the service channels (the chess arena) this phone sent whose block time is still
    /// this phone's own clock: the chain's time has not reached us yet. The arena's reducer
    /// orders these by the moves around them, never by the local stamp (see
    /// `ChessTournamentService.reduce`).
    var locallyStampedTxIds: Set<String> { Set(localStampSentAt.keys) }
    /// The same rows, by when this phone started waiting for them (wall ms). Kept across
    /// launches, so a row the network dropped before a relaunch is still found out
    /// (`checkUnconfirmedServiceRows`); a relaunch restarts the wait, as the chain's answer may
    /// have come while the app was closed. Per account, like the store the rows live in: filled
    /// by `setCurrentWallet`.
    private var localStampSentAt: [String: Int64] = [:] {
        didSet { Self.saveLocalStamps(localStampSentAt, wallet: walletAddress) }
    }
    private var isCheckingLocalStamps = false
    /// Set when a public chat-room notification is tapped, so the chat list can navigate to that
    /// room - mirrors `ChatService.pendingChatNavigation`'s cold-start handling.
    @Published var pendingPublicChatNavigation: String?

    /// Shows a "Popular" tab of curated channels in the list screen. Default matches Android.
    private let store = PublicChatStore.shared

    /// Reference count of open channel screens ("live viewing"), keyed by normalized name.
    private var liveViewRefCounts: [String: Int] = [:]
    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false
    /// pendingId of public chats with an auto-retry already scheduled - prevents scheduling a
    /// duplicate retry if `sendPublicChatInternal` fails again before the first retry fires.
    private var scheduledSendRetries: Set<String> = []

    /// Fast pre-filter for the public chat payload prefix, applied to the still-hex-encoded
    /// `Protowire_RpcTransaction.payload` before paying the cost of hex-decoding it - avoids
    /// decoding every transaction in every new block just to reject non-public chat ones.
    private nonisolated static func hexOf(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
    private nonisolated static let bcastPrefixHex: String = hexOf("kchat:1:bcast:")        // write + read
    private nonisolated static let legacyBcastPrefixHex: String = hexOf("ciph_msg:1:bcast:") // read-only

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // On expensive (cellular/metered) paths an open indexer-covered room keeps to its poll
        // (see scanWantedChannels) - re-evaluate whenever the path flips either way.
        NetworkEpochMonitor.shared.expensivePathPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateScanningStateIfNeeded()
            }
            .store(in: &cancellables)
        // The closed-room sweep runs only while the app is on screen (see sweepClosedRooms).
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.startForegroundSweep()
                self?.refreshIndexerTrackedRooms()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stopForegroundSweep() }
            .store(in: &cancellables)
        // A room the indexer turned out to track (or stopped tracking): its push registration,
        // cellular scanning and wording follow at once.
        NotificationCenter.default.publisher(for: IndexerTrackedRooms.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.updateScanningStateIfNeeded()
                Task { await PushNotificationManager.shared.updateWatchedAddresses() }
            }
            .store(in: &cancellables)
        // Before stamps were kept per account.
        UserDefaults.standard.removeObject(forKey: Self.localStampsKey)
    }

    /// True while the chess arena's indexer has stopped answering. The arena then lives on the
    /// block stream, with the REST API filling in the player's own games
    /// (`ChessTournamentService.readMyGamesFromChainIfDue`).
    @Published private(set) var arenaIndexerDown = false
    /// When the newest indexer answer for the arena was asked for (wall ms): rows up to then are
    /// in the store, so it only counts once any paging-in that was due has finished. A timeout
    /// claim waits for one newer than the flag.
    private(set) var arenaIndexerAnsweredAt: Int64 = 0

    /// The newest page of the arena answered at `arenaNewestAnsweredAt` (wall ms, when it was
    /// asked for), and the rows from `arenaCoveredFrom` (block time) up to then are all in the
    /// store: the newest page plus the older pages paged in after it. Kept while older history
    /// is still being paged - or keeps failing - so a game that started inside that stretch can
    /// be judged from a fresh answer (`arenaAnsweredAt(covering:)`).
    private var arenaNewestAnsweredAt: Int64 = 0
    private var arenaCoveredFrom: Int64 = .max

    private func noteArenaAnswered(channel: String, askedAt: Int64, coveredFrom: Int64?) {
        guard channel == ChessTournamentCodec.arenaChannel else { return }
        if let coveredFrom {
            arenaNewestAnsweredAt = max(arenaNewestAnsweredAt, askedAt)
            arenaCoveredFrom = coveredFrom
        }
        guard deepBackfilledChannels.contains(channel) else { return }
        arenaIndexerAnsweredAt = max(arenaIndexerAnsweredAt, askedAt)
    }

    /// When the newest indexer answer that holds every arena row since `since` (block time) was
    /// asked for (wall ms), or 0: the whole window paged in, or a newest page over a stretch
    /// paged in without a gap that reaches back to `since`.
    func arenaAnsweredAt(covering since: Int64) -> Int64 {
        if arenaBackfillDone { return arenaIndexerAnsweredAt }
        return since >= arenaCoveredFrom ? arenaNewestAnsweredAt : 0
    }

    /// The arena's history is paged in, as far as this session owes it.
    var arenaBackfillDone: Bool { deepBackfilledChannels.contains(ChessTournamentCodec.arenaChannel) }

    /// The latest word on the arena's indexer, after every read: state, not transitions, so a
    /// missed or reordered change can't leave it stuck either way.
    func arenaHealthObserved(down: Bool) {
        guard down != arenaIndexerDown else { return }
        AppLog.log("[PublicChat] Arena indexer %@", down ? "isn't answering: reading from the block stream and the Kaspa REST API" : "is answering again")
        arenaIndexerAvailabilityChanged(down: down)
        NotificationCenter.default.post(name: .arenaIndexerAvailabilityChanged, object: nil, userInfo: ["down": down])
    }

    /// The indexer's address was cleared while it was down: nothing would ever report it back.
    func resyncArenaIndexerIfUnset() {
        guard arenaIndexerDown, Self.indexerBaseURL(forChannel: ChessTournamentCodec.arenaChannel).isEmpty else { return }
        Task { await PublicChatIndexerClient.arenaHealth.reset() }
        arenaHealthObserved(down: false)
    }

    /// Pages the arena back to `since` on the next poll: one of this player's games shows a
    /// move missing, or a claim didn't take. Until that's done no answer counts as fresh.
    func repageArena(since: Int64) {
        requestRepage(channel: ChessTournamentCodec.arenaChannel, since: since - Self.repageMarginMs)
    }

    /// Whether the REST API shows this transaction accepted (a bot stamp).
    func isTransactionAccepted(txId: String) async -> Bool {
        if case .accepted = await Self.lookUpTransaction(txId: txId) { return true }
        return false
    }

    private static func skipsIndexer(_ channel: String) async -> Bool {
        guard channel == ChessTournamentCodec.arenaChannel else { return false }
        return await PublicChatIndexerClient.arenaHealth.shouldSkipIndexer()
    }

    /// Down: on cellular the block stream comes back on (`scanWantedChannels`). Back: the arena is
    /// paged in again, since the steady poll's newest rows can't reach back over an outage, and
    /// the indexer's block times replace what the stream gave meanwhile.
    /// Only the outage is paged again when the history before it was all in: a flaky indexer
    /// re-paged the whole 30 days on every return.
    private func arenaIndexerAvailabilityChanged(down: Bool) {
        arenaIndexerDown = down
        let channel = ChessTournamentCodec.arenaChannel
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        if down {
            arenaDownSince = wallNow
        } else {
            if deepBackfilledChannels.contains(channel), let since = arenaDownSince {
                requestRepage(channel: channel, since: since - Self.repageMarginMs)
            } else {
                deepBackfilledChannels.remove(channel)
                deepBackfillResume[channel] = nil
                deepBackfillFloor[channel] = nil
                arenaIndexerAnsweredAt = 0
                arenaNewestAnsweredAt = 0
                arenaCoveredFrom = .max
            }
            arenaDownSince = nil
        }
        updateScanningStateIfNeeded()
    }
    /// When the arena's indexer was last seen going down (wall ms).
    private var arenaDownSince: Int64?

    /// When the app-wide indexer was last asked which rooms it tracks.
    private var trackedRoomsCheckedAt: (base: String, at: Date)?

    /// Asks the app-wide public chat indexer which rooms it tracks (`/broadcast-channels`), at
    /// most once an hour per indexer - on app open and wallet switch. An indexer without the
    /// endpoint answers nothing and the set keeps what it learned from served rows.
    func refreshIndexerTrackedRooms() {
        let base = AppSettings.load().publicChatIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        if let last = trackedRoomsCheckedAt, last.base == base, Date().timeIntervalSince(last.at) < 3600 { return }
        trackedRoomsCheckedAt = (base, Date())
        Task {
            guard let channels = await PublicChatIndexerClient.fetchTrackedChannels(baseURL: base) else { return }
            IndexerTrackedRooms.setReported(channels)
        }
    }

    // MARK: - Wallet lifecycle

    /// Switch to a different wallet's public chat store. Call alongside
    /// `MessageStore.shared.setCurrentWallet` at every wallet-lifecycle transition.
    func setCurrentWallet(_ walletAddress: String?) {
        let normalized = walletAddress?.lowercased()
        let sameWallet = normalized == self.walletAddress
        if !sameWallet {
            // What was fetched and backfilled was the other wallet's store: this one's rooms
            // start from nothing.
            settledPendingChannels = []
            settledWhileIndexerDown = []
            deepBackfilledChannels = []
            deepBackfillResume = [:]
            deepBackfillFloor = [:]
            indexerFetchedChannels = []
            // "Load earlier messages" widened the other account's rooms, not this one's.
            windowSizeByChannel = [:]
            windowExhausted = []
        }
        // A room can already be on screen when the wallet lands: a cold launch from a room's
        // notification routes into it during loadWallet's awaits, before this ran. That room is
        // THIS wallet's and stays open, so its viewing state survives; only a real switch to
        // another wallet (whose screens are being torn down) resets it. Wiping it mid-view made
        // release() skip its mark-read (no refcount), and loadReadState() below replaced the
        // mark-read from acquire (which couldn't persist - the per-wallet key was still nil) -
        // so a room read straight from its notification stayed "unread", and the badge came
        // back on the next open.
        let tearingDownOtherWallet = self.walletAddress != nil && !sameWallet
        self.walletAddress = normalized
        if !sameWallet {
            primingRooms = []
            messagesByIdByChannel = [:]
            messagesByChannel = [:]
            reactionsByChannel = [:]
            editsByChannel = [:]
            failedEditsByChannel = [:]
            editingMessage = nil
            replyingTo = nil
            // Each wallet has its own store: what one applied says nothing about the other's.
            appliedIndexerRows = [:]
            indexerNewestSeen = [:]
            // A fetch, backfill or read still out for the account being left drops its answer
            // (`isCurrentWallet`) instead of writing it into this one's store and state.
            walletGeneration &+= 1
            // The other account's sends: what they leave behind is settled in its own store
            // (`markSendFailed`, `abortedSendsByWallet`), not kept "Sending" in this one's.
            pendingSendsThisRun = []
            // The arena's state was the other account's (from KaPlay, 2026-11-21): its paging,
            // its answers and its own rows still waiting for the chain's time.
            failedBackfillResumes = [:]
            arenaIndexerAnsweredAt = 0
            arenaNewestAnsweredAt = 0
            arenaCoveredFrom = .max
            indexerCoveredUntil = [:]
            localStampSentAt = normalized.map { Self.loadLocalStamps(wallet: $0) } ?? [:]
            localStampNextCheck = [:]
            droppedServiceRows = []
        }
        if tearingDownOtherWallet {
            liveViewRefCounts = [:]
            // The rooms' screens are going, and their release() finds no refcount to stop the
            // polling with: every room's 8 s poll (and the deep backfill it runs) stops here,
            // and the sweep with it. The new account's store restarts the sweep once it opens.
            for task in indexerPollTasks.values { task.cancel() }
            indexerPollTasks = [:]
            stopForegroundSweep()
        }
        loadReadState()
        // The store opens off the main thread now; the rooms are read once it says so.
        let targetWallet = normalized
        store.setCurrentWallet(walletAddress) { [weak self] in
            guard let self else { return }
            // The store calls back on the main thread (CoreDataStoreLoader); this is the
            // service's own actor, so no hop is needed.
            MainActor.assumeIsolated {
                guard self.walletAddress == targetWallet else { return }
                // Sends of this account that an account switch cut short: Failed, now that its
                // store is open again, so their Retry is offered.
                self.applyAbortedSends(walletAddress: targetWallet)
                // Joins the default rooms (and refreshes the list) as soon as the wallet's
                // store is open, so #kaspa and #kachat-bugs notify without Public Chats having
                // been opened first.
                self.ensureDefaultChannelsJoined()
                // Every room's last message and unread count for the Chats list, in one publish.
                self.primeChannelSummaries()
                // Rooms that were open before the wallet landed: their acquire read an empty
                // store and its mark-read was lost to loadReadState() - reload and mark read
                // now (persisted under the real key this time).
                for channel in self.liveViewRefCounts.keys {
                    self.loadMessages(for: channel)
                    self.markChannelRead(channel)
                }
                self.updateScanningStateIfNeeded()
                // Signed out: no rooms to sweep.
                if targetWallet != nil, UIApplication.shared.applicationState == .active { self.startForegroundSweep() }
                self.refreshIndexerTrackedRooms()
            }
        }
    }

    /// Bumped on every account change: work begun for one account checks it after each await
    /// and drops its result when the account is no longer the open one.
    private var walletGeneration = 0

    private func isCurrentWallet(_ generation: Int) -> Bool {
        generation == walletGeneration
    }

    // MARK: - Foreground sweep of closed rooms

    /// The loop behind `sweepClosedRooms`, alive while the app is active.
    private var foregroundSweepTask: Task<Void, Never>?
    /// Rooms the sweep has asked about at least once this session: only rows found after that
    /// first pass get an in-app banner; the first pass is history catching up.
    private var sweptChannels: Set<String> = []
    private static let foregroundSweepIntervalNanos: UInt64 = 20 * 1_000_000_000

    /// While the app is on screen, a room the user is NOT looking at used to be refreshed only
    /// by the live block scan - which misses blocks whenever the stream reconnects, and is off
    /// altogether for indexed rooms that aren't open (`scanWantedChannels`, on every connection
    /// since 2026-11-22) where the remote push that covers them is dropped in the foreground. So
    /// a message in #kaspa showed up only once the room was opened. This is the fix, the same shape as 1:1 chat's foreground
    /// contact sweep: every 20 s, each joined room with its bell on that is not open asks the
    /// indexer for its newest rows (one small request per room, sequential). The open room
    /// keeps its own 8 s poll; the block scan stays as the fast path.
    func startForegroundSweep() {
        guard foregroundSweepTask == nil, walletAddress != nil else { return }
        foregroundSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UIApplication.shared.applicationState == .active {
                    await self.sweepClosedRooms()
                }
                try? await Task.sleep(nanoseconds: Self.foregroundSweepIntervalNanos)
            }
        }
    }

    func stopForegroundSweep() {
        foregroundSweepTask?.cancel()
        foregroundSweepTask = nil
    }

    private func sweepClosedRooms() async {
        let targets = channels.filter {
            $0.notifyEnabled && !isViewing(channel: $0.channelName)
                && !Self.serviceChannels.contains($0.channelName)
                && !Self.indexerBaseURL(forChannel: $0.channelName).isEmpty
        }
        for channel in targets {
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            await fetchNewestAndMerge(channel: channel.channelName)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// One small newest-page fetch for a closed room, merged like any other indexer page;
    /// rows that are new to the store and recent get the same in-app banner the scan gives.
    /// Asks the indexer for a room's newest rows right now and merges them - what the chess
    /// arena does just before a player picks a room, so the choice is made on the freshest
    /// shared view rather than whatever this phone happened to hold. Returns false when there
    /// is no indexer for the room or the request failed.
    @discardableResult
    func refreshFromIndexerNow(channel rawChannel: String) async -> Bool {
        let channel = PublicChatChannelName.normalize(rawChannel)
        guard !Self.indexerBaseURL(forChannel: channel).isEmpty else { return false }
        return await fetchNewestAndMerge(channel: channel)
    }

    @discardableResult
    private func fetchNewestAndMerge(channel: String) async -> Bool {
        let base = Self.indexerBaseURL(forChannel: channel)
        guard !base.isEmpty else { return false }
        let generation = walletGeneration
        if await Self.skipsIndexer(channel) { return false }
        let askedAt = Int64(Date().timeIntervalSince1970 * 1000)
        repageIfPollingLapsed(channel: channel, now: askedAt)
        do {
            let page = try await PublicChatIndexerClient.fetchHistoryPage(baseURL: base, channel: channel, limit: 40)
            noteIndexerResult(base: base, failed: nil)
            // Asked for the account that has since logged out or switched: not this store's.
            guard isCurrentWallet(generation) else { return false }
            defer { noteArenaAnswered(channel: channel, askedAt: askedAt, coveredFrom: nil) }
            // Guarded: inserting an element that is already there still publishes, which
            // re-rendered an open room on every sweep for nothing.
            if !indexerFetchedChannels.contains(channel) { indexerFetchedChannels.insert(channel) }
            let hidden = store.hiddenSenderAddresses(forChannel: channel)
            var editsChanged = false
            for row in page.messages where !hidden.contains(row.senderAddress) {
                guard let edit = MessageEditCodec.parse(row.content) else { continue }
                if applyIncomingEdit(edit, channel: channel, senderAddress: row.senderAddress, editTxId: row.txId, blockTime: row.blockTime) {
                    editsChanged = true
                }
            }
            if editsChanged { loadEdits(for: channel) }
            let rows = page.messages
                .filter { !hidden.contains($0.senderAddress) && MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
                .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
            let known = await store.messageIds(forChannel: channel)
            guard isCurrentWallet(generation) else { return false }
            let fresh = rows.filter { !known.contains($0.id) }
            let firstPass = !sweptChannels.contains(channel)
            sweptChannels.insert(channel)
            var changed = false
            if Self.serviceChannels.contains(channel) {
                // Our own arena rows take the chain's block time - see processPublicChatHits.
                // A row whose time was already applied is skipped, as in the room's 8 s poll
                // (`mergeIndexerRows`): this runs every 2 s during a game, and each update is a
                // Core Data fetch on the main thread for all 40 rows.
                for row in rows {
                    // Our own row can have taken this phone's clock again after the indexer's
                    // time was applied (the send resolving late): that one is never skipped.
                    let onOwnClock = localStampSentAt[row.id] != nil || droppedServiceRows.remove(row.id) != nil
                    confirmLocalStamp(row.id)
                    let key = "\(row.id)@\(row.blockTime)"
                    guard onOwnClock || !wasApplied(key, channel: channel) else { continue }
                    if store.updateBlockTime(id: row.id, blockTime: row.blockTime) { changed = true }
                    // Only a row the store already held: a fresh one is inserted below with this
                    // time, and is marked on the next poll once it is surely there.
                    if store.isReady, known.contains(row.id) {
                        markApplied(key, channel: channel)
                        markApplied(Self.indexerTimedKey(row.id), channel: channel)
                    }
                }
            }
            // Awaited, not a deferred reload: the arena picks a room right after this returns
            // (`ChessTournamentService.joinPublicRoom`) and must read the rows just merged.
            guard !fresh.isEmpty else {
                if changed { await reloadMessagesNow(for: channel) }
                return true
            }
            let inserted = await store.insertMessages(fresh)
            guard isCurrentWallet(generation) else { return true }
            guard !inserted.isEmpty else {
                if changed { await reloadMessagesNow(for: channel) }
                return true
            }
            await store.pruneExpiredMessages()
            guard isCurrentWallet(generation) else { return true }
            await reloadMessagesNow(for: channel)
            if !firstPass {
                for row in fresh where inserted.contains(row.id) {
                    postInAppBanner(channel: channel, senderAddress: row.senderAddress, content: row.content, txId: row.id, blockTime: row.blockTime)
                }
            }
            return true
        } catch {
            // Best-effort; the next sweep tries again.
            noteIndexerResult(base: base, failed: error)
            AppLog.log("%@", "[PublicChat] Sweep fetch failed for #\(channel): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Read state (the Public Chats list's unread counts)

    private var walletAddress: String?
    /// Per room, the block time (ms) up to which the reader has seen it. Per wallet.
    @Published private(set) var lastReadByChannel: [String: Int64] = [:]
    /// Rooms marked unread by hand, which show a badge even with nothing new in them.
    @Published private(set) var manuallyUnreadChannels: Set<String> = []

    /// Default (curated) rooms switched off in Public Chats settings: gone from the list, never
    /// notifying, not counted. Per wallet.
    @Published private(set) var hiddenCuratedChannels: Set<String> = []
    private var hiddenCuratedKey: String? { walletAddress.map { "kachat_broadcast_hidden_curated_\($0)" } }

    /// The rooms the Public Chats list shows, in its order: the two Popular rooms on top, then
    /// every other joined room by latest activity. Service rooms and default rooms switched off
    /// in settings are left out. Shared by the list and by its Select All.
    var listedChannels: [PublicChatChannel] {
        let featured = Self.featuredChannels.compactMap { name in
            channels.first { $0.channelName == name }
        }
        .filter { isCuratedChannelShown($0.channelName) }
        func lastActivity(_ channel: PublicChatChannel) -> Int64 {
            messages(forChannel: channel.channelName).last?.blockTime
                ?? Int64((channel.joinedAt ?? .distantPast).timeIntervalSince1970 * 1000)
        }
        // Rooms with messages by latest activity; a language room nobody has written in yet
        // keeps its place in `languageChannels` (they are all joined at the same moment, so
        // their join times would order them at random).
        func sortKey(_ channel: PublicChatChannel) -> (Int64, Int) {
            if let latest = messages(forChannel: channel.channelName).last?.blockTime { return (latest, 0) }
            if let index = Self.languageChannels.firstIndex(of: channel.channelName) { return (0, -index) }
            return (lastActivity(channel), 0)
        }
        let others = channels
            .filter { !Self.featuredChannels.contains($0.channelName) }
            .filter { !Self.serviceChannels.contains($0.channelName) }
            // A default room switched off in Public Chats settings stays out of the list.
            .filter { isCuratedChannelShown($0.channelName) }
            .sorted { sortKey($0) > sortKey($1) }
        return featured + others
    }

    /// "Delete" from the room list. A room you added is left for good (`leaveChannel`, its
    /// messages go). A default room cannot really be deleted - it is simply switched off, the
    /// same as its toggle in Public Chats settings, and that toggle brings it back.
    func removeFromList(_ rawName: String) {
        let name = PublicChatChannelName.normalize(rawName)
        if Self.curatedChannels.contains(name) {
            setCuratedChannel(name, shown: false)
        } else {
            leaveChannel(name)
        }
    }

    /// The Languages switch on the customize screen: on while at least one language room is.
    var anyLanguageChannelOn: Bool {
        Self.languageChannels.contains { isCuratedChannelOn($0) }
    }

    /// Every language room off at once (out of the list, bells off), or all back on - each
    /// then switched off one by one if only some are wanted.
    func setAllLanguageChannels(shown: Bool) {
        for name in Self.languageChannels where isCuratedChannelOn(name) != shown {
            setCuratedChannel(name, shown: shown)
        }
    }

    func isCuratedChannelShown(_ name: String) -> Bool {
        !hiddenCuratedChannels.contains(PublicChatChannelName.normalize(name))
    }

    /// What a default room's switch in Public Chats settings reads: on only when the room is
    /// joined AND not switched off - i.e. it is in the list. Every default room is joined
    /// (`ensureDefaultChannelsJoined`), so in practice this is "not switched off".
    func isCuratedChannelOn(_ name: String) -> Bool {
        let normalized = PublicChatChannelName.normalize(name)
        return isCuratedChannelShown(normalized) && channels.contains { $0.channelName == normalized }
    }

    /// Off: the room leaves the list and its notifications stop (the bell goes off, which also
    /// takes it off the push service's watch list). On: it is joined if it wasn't (the same as
    /// joining it from the join sheet, so it appears in the list and the circles row at once)
    /// and comes back - #kaspa and #kachat-bugs with their bell on again, as they start; the
    /// language rooms with the bell a newly joined room gets.
    func setCuratedChannel(_ rawName: String, shown: Bool) {
        let name = PublicChatChannelName.normalize(rawName)
        guard Self.curatedChannels.contains(name) else { return }
        if shown {
            hiddenCuratedChannels.remove(name)
        } else {
            hiddenCuratedChannels.insert(name)
        }
        if let key = hiddenCuratedKey {
            UserDefaults.standard.set(Array(hiddenCuratedChannels), forKey: key)
        }
        if shown, !channels.contains(where: { $0.channelName == name }) {
            joinChannel(name)
        }
        let isJoined = channels.contains { $0.channelName == name }
        if !shown, isJoined {
            setNotifyEnabled(false, forChannel: name)
        } else if shown, isJoined, Self.featuredChannels.contains(name) {
            setNotifyEnabled(true, forChannel: name)
        }
    }

    private var lastReadKey: String? { walletAddress.map { "kachat_broadcast_last_read_\($0)" } }
    private var manualUnreadKey: String? { walletAddress.map { "kachat_broadcast_manual_unread_\($0)" } }

    private func loadReadState() {
        let defaults = UserDefaults.standard
        if let key = lastReadKey, let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            lastReadByChannel = decoded
        } else {
            lastReadByChannel = [:]
        }
        manuallyUnreadChannels = Set(manualUnreadKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
        hiddenCuratedChannels = Set(hiddenCuratedKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
    }

    private func persistReadState() {
        let defaults = UserDefaults.standard
        if let key = lastReadKey, let data = try? JSONEncoder().encode(lastReadByChannel) {
            defaults.set(data, forKey: key)
        }
        if let key = manualUnreadKey {
            defaults.set(Array(manuallyUnreadChannels), forKey: key)
        }
    }

    /// Messages from other people newer than the read marker. A room seen for the first time
    /// counts from now, not from the start of its history.
    func unreadCount(forChannel name: String) -> Int {
        let channel = PublicChatChannelName.normalize(name)
        guard !isViewing(channel: channel), !hiddenCuratedChannels.contains(channel) else { return 0 }
        let manual = manuallyUnreadChannels.contains(channel) ? 1 : 0
        guard let marker = lastReadByChannel[channel] else { return manual }
        let mine = WalletManager.shared.currentWallet?.publicAddress
        // A long voice note's parts count once.
        var seenNotes = Set<String>()
        let count = (messagesByChannel[channel] ?? []).reduce(0) { total, message in
            guard message.blockTime > marker && message.senderAddress != mine else { return total }
            if let note = PublicChatVoiceParts.noteKey(of: message), !seenNotes.insert(note).inserted {
                return total
            }
            return total + 1
        }
        return max(count, manual)
    }

    var totalUnreadCount: Int {
        channels.filter { !Self.serviceChannels.contains($0.channelName) }
            .reduce(0) { $0 + unreadCount(forChannel: $1.channelName) }
    }

    func markChannelRead(_ name: String) {
        let channel = PublicChatChannelName.normalize(name)
        // Up to the newest message seen, not up to now: a message sent just before you left
        // the room but delivered after (the block scan or the indexer lagging) has a block time
        // earlier than "now" and was counted as read without ever being shown. Never backward,
        // and from now only for a room with nothing loaded.
        let marker: Int64
        if let newest = messagesByChannel[channel]?.last?.blockTime {
            marker = max(newest, lastReadByChannel[channel] ?? 0)
        } else {
            marker = max(Int64(Date().timeIntervalSince1970 * 1000), lastReadByChannel[channel] ?? 0)
        }
        lastReadByChannel[channel] = marker
        manuallyUnreadChannels.remove(channel)
        persistReadState()
    }

    func markChannelUnread(_ name: String) {
        manuallyUnreadChannels.insert(PublicChatChannelName.normalize(name))
        persistReadState()
    }

    /// Loads every joined room's stored messages so the list can show last message, time and
    /// unread count, and starts a read marker for rooms that have none. One read per room, but
    /// published once for all of them (audit #30: each room used to publish on its own, about
    /// 16 Chats redraws at launch). The chess arena isn't read here: its whole history loads
    /// when a chess screen opens (`ChessTournamentService.acquire` -> `acquire`).
    func primeChannelSummaries() {
        let rooms = channels.map(\.channelName).filter { !Self.serviceChannels.contains($0) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var markers = lastReadByChannel
        for name in rooms where markers[name] == nil { markers[name] = now }
        if markers != lastReadByChannel {
            lastReadByChannel = markers
            persistReadState()
        }
        // Before the store is open there is nothing to read; its open primes them (setCurrentWallet).
        guard store.isReady else { return }
        let missing = rooms.filter { messagesByChannel[$0] == nil && !primingRooms.contains($0) }
        guard !missing.isEmpty else { return }
        primingRooms.formUnion(missing)
        Task { @MainActor [weak self] in
            await self?.loadRoomSummaries(missing)
        }
    }

    /// Rooms a `primeChannelSummaries` read is out for, so a second call doesn't read them again.
    private var primingRooms: Set<String> = []

    /// Each room's summary window read in turn, then published together. A room read again on
    /// its own meanwhile (opened, a new message) keeps that newer read.
    private func loadRoomSummaries(_ rooms: [String]) async {
        let walletAtStart = walletGeneration
        // A read for an account that's gone leaves the set alone: the switch emptied it.
        defer { if isCurrentWallet(walletAtStart) { primingRooms.subtract(rooms) } }
        var claimed: [String: Int] = [:]
        var read: [String: [PublicChatMessage]] = [:]
        for name in rooms {
            let generation = (messageLoadGeneration[name] ?? 0) + 1
            messageLoadGeneration[name] = generation
            claimed[name] = generation
            read[name] = await store.messages(forChannel: name, newestLimit: windowSize(for: name))
            guard isCurrentWallet(walletAtStart) else { return }
        }
        let rows = read
        let prepared = await Task.detached(priority: .userInitiated) {
            rows.mapValues { Self.preparedRows($0, indexed: true) }
        }.value
        guard isCurrentWallet(walletAtStart) else { return }
        var messages = messagesByChannel
        var changed = false
        for (name, result) in prepared where messageLoadGeneration[name] == claimed[name] {
            guard messages[name] != result.rows else { continue }
            voiceNotesByChannel[name] = result.voiceNotes
            messagesByIdByChannel[name] = result.byId
            messages[name] = result.rows
            changed = true
        }
        if changed { messagesByChannel = messages }
    }

    /// A room's stored rows as the room shows them: no reaction or edit envelopes (rows scanned
    /// by an app version that predates them), never two rows with one id, and its long voice
    /// notes worked out. Pure, run off the main actor.
    private nonisolated static func preparedRows(_ rows: [PublicChatMessage], indexed: Bool) -> (rows: [PublicChatMessage], voiceNotes: PublicChatVoiceParts.Result, byId: [String: PublicChatMessage]) {
        // never two rows with one id: the room's list is keyed by it, and a duplicate left a
        // blank gap in it (the store also deletes duplicates on read)
        var seen = Set<String>()
        let fresh = rows.filter {
            seen.insert($0.id).inserted
                && MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil
        }
        let byId = indexed ? Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        return (fresh, PublicChatVoiceParts.group(fresh), byId)
    }


    // MARK: - Channel membership

    func refreshChannels() {
        channels = store.joinedChannels()
    }

    /// Every default room is in Public Chats from the start: joined (a store row, so it is
    /// listed and has a bell), unless it was switched off with the customize button. Rooms join
    /// with notifications off; #kaspa and #kachat-bugs then get theirs switched on once per
    /// wallet, so a bell the user later turns off stays off.
    func ensureDefaultChannelsJoined() {
        for name in Self.curatedChannels where isCuratedChannelShown(name) {
            _ = store.joinChannel(name)
        }
        refreshChannels()
        applyDefaultNotificationsOnce()
    }

    private var defaultNotificationsAppliedKey: String? {
        walletAddress.map { "kaposts_broadcast_default_bells_\($0)" }
    }

    private func applyDefaultNotificationsOnce() {
        guard let key = defaultNotificationsAppliedKey,
              !UserDefaults.standard.bool(forKey: key) else { return }
        for name in Self.featuredChannels
        where isCuratedChannelShown(name) && channels.contains(where: { $0.channelName == name }) {
            setNotifyEnabled(true, forChannel: name)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        guard store.joinChannel(rawName) else { return false }
        refreshChannels()
        return true
    }

    func leaveChannel(_ name: String) {
        // Curated rooms (Popular and the language rooms alike) can't be left - both are
        // permanent fixtures of the list screen, so no UI offers it; guard against stray paths.
        guard !Self.curatedChannels.contains(PublicChatChannelName.normalize(name)) else { return }
        let normalized = PublicChatChannelName.normalize(name)
        // Whether the push service sends this room's pushes now (the list `updateWatchedAddresses`
        // sends is the joined, indexed rooms with their bell on): leaving takes it off.
        let wasWatched = Self.isIndexerTracked(normalized)
            && channels.contains { $0.channelName == normalized && $0.notifyEnabled }
        // An open room's poll (and deep backfill) would go on writing into a room that is gone.
        stopIndexerPolling(channel: normalized)
        store.leaveChannel(normalized)
        voiceNotesByChannel.removeValue(forKey: normalized)
        messagesByIdByChannel.removeValue(forKey: normalized)
        messagesByChannel.removeValue(forKey: normalized)
        reactionsByChannel.removeValue(forKey: normalized)
        editsByChannel.removeValue(forKey: normalized)
        failedEditsByChannel.removeValue(forKey: normalized)
        // The store no longer has what these say was fetched and applied: a rejoin this session
        // pages the room in again.
        deepBackfilledChannels.remove(normalized)
        deepBackfillResume[normalized] = nil
        deepBackfillFloor[normalized] = nil
        indexerNewestSeen[normalized] = nil
        appliedIndexerRows[normalized] = nil
        liveViewRefCounts.removeValue(forKey: normalized)
        refreshChannels()
        updateScanningStateIfNeeded()
        if wasWatched {
            Task { await PushNotificationManager.shared.updateWatchedAddresses() }
        }
    }

    /// Whether a room push (`broadcast:<room>`) arriving in the foreground is one this account
    /// still wants: a room it has joined, with its bell on, not switched off in Public Chats
    /// settings, and not a service room. Until the store is open nothing is known, and it shows.
    /// A new room message's banner while the app is open (`InAppBanner`): the room's bell is on,
    /// it isn't the room on screen, and the sender isn't you or hidden there. Same wording as the
    /// room's push: "#room", the sender, the message's preview.
    func postInAppBanner(channel: String, senderAddress: String, content: String, txId: String, blockTime: Int64) {
        guard !Self.serviceChannels.contains(channel),
              senderAddress != WalletManager.shared.currentWallet?.publicAddress,
              wantsRoomPush(channel: channel),
              !isViewing(channel: channel),
              !store.hiddenSenderAddresses(forChannel: channel).contains(senderAddress),
              InAppBanner.isRecent(blockTimeMs: blockTime),
              MessageReactionCodec.parse(content) == nil,
              MessageEditCodec.parse(content) == nil else { return }
        let settings = AppSettings.load()
        guard settings.notificationsEnabled else { return }
        let sender: String
        if let assigned = ContactsManager.shared.getContact(byAddress: senderAddress)?.assignedName {
            sender = assigned
        } else {
            sender = KachatLive.identityName(senderAddress) ?? Contact.generateDefaultAlias(from: senderAddress)
        }
        InAppBanner.post(
            txId: txId,
            title: "#\(KaPostsMarkdown.strippingBidiControls(channel))",
            subtitle: KaPostsMarkdown.strippingBidiControls(sender),
            body: KaPostsMarkdown.strippingBidiControls(MessageReplyCodec.previewText(for: content)),
            threadIdentifier: "broadcast:\(channel)",
            sound: settings.incomingNotificationSoundEnabled
        )
    }

    func wantsRoomPush(channel rawChannel: String) -> Bool {
        let name = PublicChatChannelName.normalize(rawChannel)
        guard store.isReady else { return true }
        guard !Self.serviceChannels.contains(name), isCuratedChannelShown(name),
              let room = channels.first(where: { $0.channelName == name }) else { return false }
        return room.notifyEnabled
    }

    /// Whether this account's room store is open, so `channels` is its real list.
    var isStoreReady: Bool { store.isReady }

    func setNotifyEnabled(_ enabled: Bool, forChannel name: String) {
        // Indexed channels' bells also gate remote push - sync the registration so the push
        // service starts/stops sending for this channel.
        if Self.isIndexerTracked(name) {
            Task { await PushNotificationManager.shared.updateWatchedAddresses() }
        }
        store.setNotifyEnabled(enabled, forChannel: name)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    // MARK: - Hidden senders

    func hideSender(_ address: String, inChannel channel: String) {
        store.hideSender(address, inChannel: channel)
        syncHiddenSendersToPushIfNeeded(channel: channel)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
        reloadLoadedReactions()
    }

    func unhideSender(_ address: String, inChannel channel: String) {
        store.unhideSender(address, inChannel: channel)
        syncHiddenSendersToPushIfNeeded(channel: channel)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
        reloadLoadedReactions()
    }

    /// The reactions of every room that has them loaded, read again: who is hidden or blocked
    /// changed, and their reactions go (or come back) with their messages.
    private func reloadLoadedReactions() {
        for channel in reactionsByChannel.keys {
            loadReactions(for: channel)
        }
    }

    /// The room's own hides, for its Hidden Users list. Blocked accounts are left out: they are
    /// undone on the Blocked screen.
    func hiddenSenderAddresses(forChannel channel: String) -> Set<String> {
        store.roomHiddenSenderAddresses(forChannel: channel)
    }

    /// Who `KaPostsModerationStore` has blocked. Their messages leave every room, and the push
    /// service stops sending them.
    func setBlockedSenders(_ addresses: Set<String>) {
        PublicChatStore.blockedSenders = addresses
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
        reloadLoadedReactions()
        Task { await PushNotificationManager.shared.updateWatchedAddresses() }
    }

    // MARK: - Per-room indexer

    /// Channel -> indexer base URL, for rooms the user pointed somewhere other than the app's
    /// configured public chat indexer.
    ///
    /// A public chat is on-chain, so any indexer that watches the same network serves the same
    /// room - which means a room can be read through whichever one you trust or host, without
    /// changing the app-wide setting that every OTHER room uses. Empty here means "use the
    /// app-wide one", which is what the curated Popular rooms do (KaChat's own indexer).
    // nonisolated: `indexerBaseURL(forChannel:)` is nonisolated so callers off the main actor
    // can resolve a room's indexer, and a main-actor-isolated constant is not reachable from it.
    // Per network: a room pointed at a mainnet indexer must not keep reading it on testnet.
    // Mainnet keeps the original key.
    private nonisolated static var indexerOverridesKey: String {
        AppSettings.load().networkType == .mainnet
            ? "kachat_broadcast_indexer_overrides"
            : "kachat_broadcast_indexer_overrides.testnet"
    }

    private var indexerOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.indexerOverridesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.indexerOverridesKey) }
    }

    /// The indexer this room reads from: its own override, or the app-wide public chat indexer.
    nonisolated static func indexerBaseURL(forChannel channel: String) -> String {
        let overrides = UserDefaults.standard.dictionary(forKey: indexerOverridesKey) as? [String: String] ?? [:]
        let own = overrides[PublicChatChannelName.normalize(channel)]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own, !own.isEmpty { return own }
        return AppSettings.load().publicChatIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// This room's override as the user typed it, or "" when it follows the app-wide setting.
    func indexerOverride(forChannel channel: String) -> String {
        indexerOverrides[PublicChatChannelName.normalize(channel)] ?? ""
    }

    /// Points one room at its own indexer. An empty (or whitespace) value clears the override so
    /// the room follows the app-wide setting again. Restarts this room's polling so the change
    /// takes effect without leaving the room.
    func setIndexerOverride(_ url: String, forChannel channel: String) {
        let key = PublicChatChannelName.normalize(channel)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var overrides = indexerOverrides
        if trimmed.isEmpty { overrides.removeValue(forKey: key) } else { overrides[key] = trimmed }
        indexerOverrides = overrides
        stopIndexerPolling(channel: key)
        if isViewing(channel: key) { startIndexerPollingIfConfigured(channel: key) }
        // A room with an indexer now (or none) leaves (or joins) the block stream.
        updateScanningStateIfNeeded()
    }

    func hiddenSendersByChannel() -> (global: Set<String>, perChannel: [String: Set<String>]) {
        store.hiddenSendersByChannel()
    }

    /// Hides in the indexed channels also gate server-side push - re-sync the registration so
    /// the push service stops (or resumes) sending for that sender.
    private func syncHiddenSendersToPushIfNeeded(channel: String) {
        guard Self.isIndexerTracked(channel) else { return }
        Task { await PushNotificationManager.shared.updateWatchedAddresses() }
    }

    // MARK: - Live viewing (reference counted)

    /// Call when a public chat channel screen appears; pairs with `release`.
    func acquire(_ name: String) {
        let normalized = PublicChatChannelName.normalize(name)
        // The composer's targets are one per app: those left over from another room go.
        if let editing = editingMessage, editing.channelName != normalized { editingMessage = nil }
        if let reply = replyingTo, reply.channelName != normalized { replyingTo = nil }
        ChatService.clearDeliveredNotifications(threadIdentifier: "broadcast:\(normalized)")
        liveViewRefCounts[normalized, default: 0] += 1
        Task { await store.pruneExpiredMessages() }
        loadMessages(for: normalized)
        // A room with no indexer has no history coming to wait for.
        if !Self.isIndexerTracked(normalized) { settlePendingSendsFromBeforeThisRun(channel: normalized) }
        markChannelRead(normalized)
        loadReactions(for: normalized)
        loadEdits(for: normalized)
        updateScanningStateIfNeeded()
        startIndexerPollingIfConfigured(channel: normalized)
    }

    /// Per-channel indexer poll loops, running while that channel's screen is open.
    private var indexerPollTasks: [String: Task<Void, Never>] = [:]
    /// Channels whose FULL indexer history (up to the 30-day window) was already paged in this
    /// session — the deep backfill runs once per room per launch; the 8s poll then only needs
    /// the newest page to stay fresh.
    private var deepBackfilledChannels: Set<String> = []
    /// Channels the indexer has answered at least once this session - the chess arena waits
    /// for this before letting a player pick a room (KaChat's `ChessTournamentService.historyReady`).
    @Published private(set) var indexerFetchedChannels: Set<String> = []

    /// Indexer rows already applied this session, per channel: reaction and edit txids that
    /// landed, and "txid@blockTime" for service-room block-time fixes. The steady-state poll
    /// re-serves the newest 30 rows every 8s, and each of those used to cost a synchronous
    /// Core Data fetch on the main actor again - reapplying is idempotent, so it only ever cost
    /// time. Not persisted: a fresh launch re-checks once, which is the safe direction.
    private var appliedIndexerRows: [String: Set<String>] = [:]
    private static let appliedIndexerRowsCap = 4_000

    private func wasApplied(_ key: String, channel: String) -> Bool {
        appliedIndexerRows[channel]?.contains(key) == true
    }

    private func markApplied(_ key: String, channel: String) {
        var set = appliedIndexerRows[channel] ?? []
        // Bounded by forgetting everything at the cap; the cost is one re-check per row.
        if set.count >= Self.appliedIndexerRowsCap { set.removeAll(keepingCapacity: true) }
        set.insert(key)
        appliedIndexerRows[channel] = set
    }
    /// The newest block time the indexer has shown for each room this session. A steady poll
    /// whose whole page is newer than this has a gap behind it.
    private var indexerNewestSeen: [String: Int64] = [:]
    /// Where an interrupted deep backfill picks up: the `before` cursor of the next page to
    /// ask for, and how many pages of the safety valve are left. Session-only, like the
    /// completed set above. Without this a single thrown page - one timeout on page 30 of a
    /// busy room - restarted the whole pager from page 1 on the next 8s tick, and kept doing
    /// so until every page happened to succeed in one go.
    private var deepBackfillResume: [String: (before: Int64, pagesLeft: Int)] = [:]
    /// Backfill attempts in a row that failed without paging anything, per channel; at
    /// `maxFailedBackfillResumes` the failing page is passed over.
    private var failedBackfillResumes: [String: Int] = [:]
    private static let maxFailedBackfillResumes = 3
    private static let indexerPollIntervalNanos: UInt64 = 8 * 1_000_000_000
    /// When the newest answered poll of a room was asked for (wall ms). Anything older than this
    /// that a newest-rows poll can't reach (app in the background, room closed, polls failing)
    /// is paged in again (`repageIfPollingLapsed`).
    private var indexerCoveredUntil: [String: Int64] = [:]
    private static let pollLapseMs: Int64 = 20_000
    private static let repageMarginMs: Int64 = 60_000

    /// The polls stopped for a while: the rows since then may be past what the newest page holds.
    private func repageIfPollingLapsed(channel: String, now: Int64) {
        guard deepBackfilledChannels.contains(channel), let covered = indexerCoveredUntil[channel],
              now - covered > Self.pollLapseMs else { return }
        requestRepage(channel: channel, since: covered - Self.repageMarginMs)
    }

    /// The next poll pages the room back to `since`. A backfill already running to an older
    /// point, or the whole window, is left to go there.
    private func requestRepage(channel: String, since: Int64) {
        if deepBackfilledChannels.remove(channel) != nil {
            deepBackfillFloor[channel] = since
            deepBackfillResume[channel] = nil
        } else if let floor = deepBackfillFloor[channel] {
            deepBackfillFloor[channel] = min(floor, since)
        }
        if channel == ChessTournamentCodec.arenaChannel {
            arenaIndexerAnsweredAt = 0
            arenaNewestAnsweredAt = 0
            arenaCoveredFrom = .max
        }
    }

    /// While a room is open, the KaChat public chat indexer is polled every few seconds and new
    /// rows merge into the local store (txid-deduped) - live block scanning alone proved
    /// unreliable for freshness (the indexer had messages the app never showed). First fetch
    /// fires immediately on open, so history backfill is included. No-op when the URL is unset;
    /// hidden senders and retention pruning apply exactly like scanned rows.
    private func startIndexerPollingIfConfigured(channel: String) {
        guard indexerPollTasks[channel] == nil else { return }
        let base = Self.indexerBaseURL(forChannel: channel)
        guard !base.isEmpty else { return }
        indexerPollTasks[channel] = Task { [weak self] in
            // Opening a chess screen asks at once whether the arena's indexer is back.
            if channel == ChessTournamentCodec.arenaChannel {
                await PublicChatIndexerClient.arenaHealth.allowProbeNow()
            }
            while !Task.isCancelled {
                // The room view stays mounted (and this loop alive) while the app is in the
                // background, but there is nobody to show a fresh row to - skip the network
                // work until the app is active again, the same gate the open-chat poll uses.
                if UIApplication.shared.applicationState == .active {
                    await self?.fetchFromIndexerAndMerge(baseURL: base, channel: channel)
                }
                try? await Task.sleep(nanoseconds: Self.indexerPollIntervalNanos)
            }
        }
    }

    private func stopIndexerPolling(channel: String) {
        indexerPollTasks[channel]?.cancel()
        indexerPollTasks[channel] = nil
    }

    private func fetchFromIndexerAndMerge(baseURL: String, channel: String) async {
        // Every answer below is for the account this started under: after a log out or switch
        // (or the room being left, which cancels its poll) it is dropped, not merged into the
        // next account's store or its backfill state.
        let generation = walletGeneration
        func stillWanted() -> Bool { isCurrentWallet(generation) && !Task.isCancelled }
        if await Self.skipsIndexer(channel) { return }
        let askedAt = Int64(Date().timeIntervalSince1970 * 1000)
        repageIfPollingLapsed(channel: channel, now: askedAt)
        do {
            // Steady-state polls only need the newest few rows (everything older is already in
            // the store, txid-deduped); re-fetching 200 rows every 8s was pure re-download. The
            // deep backfill below keeps the full 200-row pages. The indexer's `before`
            // parameter pages OLDER history, so it cannot act as a newest-side floor - the
            // small limit is the mechanism. A burst larger than the page is paged back below, and
            // rows a gap in the polling left out are paged in again (`repageIfPollingLapsed`).
            let steadyStateLimit = deepBackfilledChannels.contains(channel) ? 30 : 200
            let messages = try await PublicChatIndexerClient.fetchHistoryPage(
                baseURL: baseURL, channel: channel, limit: steadyStateLimit
            )
            noteIndexerResult(base: baseURL, failed: nil)
            guard stillWanted() else { return }
            // Guarded: a no-op insert still publishes, re-rendering the open room every poll.
            if !indexerFetchedChannels.contains(channel) { indexerFetchedChannels.insert(channel) }
            // The newest page goes in FIRST, before any history is paged. It used to wait for
            // the whole 30-day backfill below - up to 50 sequential requests on a busy room - so
            // the message a notification had just announced showed up seconds after the room
            // opened, not with it.
            await mergeIndexerRows(messages.messages, channel: channel, prune: true, generation: generation)
            guard stillWanted() else { return }
            indexerCoveredUntil[channel] = askedAt
            // More arrived since the last poll than the page holds (a busy room, or the app
            // away for a while): page back to the rows already seen, through the backfill below
            // and its limit, resume and floor. It used to stay missing until the next launch.
            if deepBackfilledChannels.contains(channel), messages.hasMore,
               let seen = indexerNewestSeen[channel],
               let oldest = messages.messages.map(\.blockTime).min(), oldest > seen {
                requestRepage(channel: channel, since: seen)
            }
            if let newest = messages.messages.map(\.blockTime).max() {
                indexerNewestSeen[channel] = max(newest, indexerNewestSeen[channel] ?? newest)
            }
            // How far back the rows in the store run without a gap, as of this answer (the
            // arena's timeout claims are judged from it).
            var coveredFrom: Int64? = messages.hasMore ? (messages.messages.map(\.blockTime).min() ?? askedAt) : 0
            // Deep backfill: page older history with `before` until the indexer runs out or we
            // reach its 30-day window, or the floor of a repeat after a gap. Without this, rooms
            // only ever showed the newest single page (200 rows) — busy rooms like
            // #kachat-bugs never loaded anywhere near the 30 days the indexer holds.
            if !deepBackfilledChannels.contains(channel) {
                let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - PublicChatStore.indexerRetentionMillis
                var hasMore: Bool
                var oldest: Int64?
                var pagesLeft: Int
                if let resume = deepBackfillResume[channel] {
                    // Picking up an interrupted pager: everything newer than this cursor is
                    // already in the store from the attempt that recorded it.
                    hasMore = true
                    oldest = resume.before
                    pagesLeft = resume.pagesLeft
                    if let from = coveredFrom { coveredFrom = min(from, resume.before) }
                } else {
                    hasMore = messages.hasMore
                    // From the oldest millisecond again (see the cursor in the loop below).
                    oldest = messages.messages.map(\.blockTime).min().map { $0 + 1 }
                    pagesLeft = 50 // safety valve: 50 × 200 = 10k rows, far beyond any real room
                }
                var interrupted = false
                var pagedSome = false
                let floor = max(cutoff, deepBackfillFloor[channel] ?? cutoff)
                while hasMore, let before = oldest, before > floor, pagesLeft > 0 {
                    pagesLeft -= 1
                    let page: (messages: [PublicChatIndexerClient.IndexedPublicChat], hasMore: Bool)
                    do {
                        page = try await PublicChatIndexerClient.fetchHistoryPage(
                            baseURL: baseURL, channel: channel, before: before, isBackfill: true
                        )
                    } catch {
                        guard stillWanted() else { return }
                        // Keep what this attempt did get: the pages already merged stay, and
                        // the cursor recorded after each of them is where the next 8s tick
                        // resumes - not page 1.
                        AppLog.log("%@", "[PublicChat] Deep backfill for #\(channel) paused at before=\(before): \(error.localizedDescription)")
                        interrupted = true
                        // The cursor this attempt stopped at, so a page that keeps failing is
                        // known as one (`maxFailedBackfillResumes`).
                        if deepBackfillResume[channel] == nil {
                            deepBackfillResume[channel] = (before: before, pagesLeft: pagesLeft + 1)
                        }
                        break
                    }
                    guard stillWanted() else { return }
                    pagedSome = true
                    guard !page.messages.isEmpty else { break }
                    // Each page merged as it arrives, oldest last.
                    await mergeIndexerRows(page.messages, channel: channel, prune: false, generation: generation)
                    guard stillWanted() else { return }
                    hasMore = page.hasMore
                    // The indexer's `before` is exclusive (`block_time < before`), and rows of one
                    // block share a millisecond: those cut off at a page's edge were skipped. So the
                    // next page asks from the oldest millisecond again (rows dedupe by txid). A page
                    // that is all that millisecond made no progress, and steps past it instead.
                    let pageOldest = page.messages.map(\.blockTime).min()
                    if let pageOldest, pageOldest + 1 < before {
                        oldest = pageOldest + 1
                    } else {
                        oldest = pageOldest
                    }
                    if coveredFrom != nil { coveredFrom = hasMore ? (pageOldest ?? before) : 0 }
                    if hasMore, let next = oldest {
                        deepBackfillResume[channel] = (before: next, pagesLeft: pagesLeft)
                    }
                }
                if interrupted {
                    // A page that fails attempt after attempt, with nothing paged past it, would
                    // hold the backfill - and the arena's joins and timeout claims, which wait
                    // for it - forever while the indexer reads as up. After a few such attempts
                    // it's passed over: the rows older than it are left out (a gap at the old
                    // end of the window, logged), and everything newer is in.
                    failedBackfillResumes[channel] = pagedSome ? 1 : (failedBackfillResumes[channel] ?? 0) + 1
                    if (failedBackfillResumes[channel] ?? 0) >= Self.maxFailedBackfillResumes {
                        let at = deepBackfillResume[channel]?.before ?? oldest ?? 0
                        AppLog.log("%@", "[PublicChat] Deep backfill for #\(channel) gave up at before=\(at): rows older than that are left out this session")
                        interrupted = false
                    }
                }
                // Marked done only once the pager actually finishes (or passed over a page that
                // kept failing); a paused one keeps its resume cursor and the next poll
                // continues from there.
                if !interrupted {
                    deepBackfilledChannels.insert(channel)
                    deepBackfillResume[channel] = nil
                    deepBackfillFloor[channel] = nil
                    failedBackfillResumes[channel] = nil
                    // The whole history is in, so a send that did land has its copy to match.
                    settlePendingSendsFromBeforeThisRun(channel: channel)
                }
            }
            noteArenaAnswered(channel: channel, askedAt: askedAt, coveredFrom: coveredFrom)
        } catch {
            // Best-effort on top of live scanning - the loop just tries again next tick.
            noteIndexerResult(base: baseURL, failed: error)
            AppLog.log("%@", "[PublicChat] Indexer fetch failed for #\(channel): \(error.localizedDescription)")
            if stillWanted(), unreachableIndexers[baseURL] != nil {
                settlePendingSendsFromBeforeThisRun(channel: channel, indexerDown: true)
            }
        }
    }

    /// One page of indexer rows into the room: edits and reactions to their indexes, the
    /// rest into the store, the room reloaded when anything was new.
    private func mergeIndexerRows(_ page: [PublicChatIndexerClient.IndexedPublicChat], channel: String, prune: Bool, generation: Int) async {
        guard isCurrentWallet(generation) else { return }
        let hidden = store.hiddenSenderAddresses(forChannel: channel)
        let visible = page.filter { !hidden.contains($0.senderAddress) }

        // Reactions never become visible message rows - route them to the per-channel
        // reactions index instead (newest-blockTime-wins per (target, reactor), so
        // re-serving the same history every poll is idempotent - see
        // `PublicChatStore.applyIncomingReaction`).
        // Collected here, applied in one background pass with one save (see
        // `PublicChatStore.applyIncoming`) - this was a main-thread fetch and save per row.
        var incomingReactions: [PublicChatStore.IncomingReaction] = []
        var incomingEdits: [PublicChatStore.IncomingEdit] = []
        for row in visible {
            if let edit = MessageEditCodec.parse(row.content) {
                guard !wasApplied(row.txId, channel: channel) else { continue }
                incomingEdits.append(.init(
                    targetTxId: edit.targetTxId, senderAddress: row.senderAddress,
                    text: edit.text, editTxId: row.txId, blockTime: row.blockTime
                ))
                continue
            }
            guard let reaction = MessageReactionCodec.parse(row.content) else { continue }
            guard !wasApplied(row.txId, channel: channel) else { continue }
            incomingReactions.append(.init(
                targetTxId: reaction.targetTxId, reactorAddress: row.senderAddress,
                emoji: reaction.action == "remove" ? nil : reaction.emoji,
                reactionTxId: row.txId, blockTime: row.blockTime
            ))
        }
        if !incomingReactions.isEmpty || !incomingEdits.isEmpty {
            let storeReady = store.isReady
            let result = await store.applyIncoming(reactions: incomingReactions, edits: incomingEdits, channel: channel)
            guard isCurrentWallet(generation) else { return }
            // A reaction row is keyed by target and reactor, not by the target's presence, so
            // once the store has seen its tx (applied, or superseded) it never needs it again.
            if storeReady {
                for reaction in incomingReactions { markApplied(reaction.reactionTxId, channel: channel) }
            }
            // Edits only once they land: one met before its target message (history pages come
            // newest first) has to be tried again when the target arrives.
            for editTxId in result.appliedEditTxIds { markApplied(editTxId, channel: channel) }
            if result.reactionsChanged { loadReactions(for: channel) }
            if !result.appliedEditTxIds.isEmpty { loadEdits(for: channel) }
        }

        let rows = visible
            .filter { MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
            .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
        var insertedCount = await store.insertMessages(rows).count
        guard isCurrentWallet(generation) else { return }
        if Self.serviceChannels.contains(channel) {
            // Rows this phone sent carry its own clock until the chain's time reaches us -
            // see processPublicChatHits.
            for row in rows {
                // Our own row can have taken this phone's clock again after the indexer's time
                // was applied (the send resolving late): that one is never "already applied".
                let onOwnClock = localStampSentAt[row.id] != nil || droppedServiceRows.remove(row.id) != nil
                confirmLocalStamp(row.id)
                let key = "\(row.id)@\(row.blockTime)"
                guard onOwnClock || !wasApplied(key, channel: channel) else { continue }
                if store.updateBlockTime(id: row.id, blockTime: row.blockTime) {
                    insertedCount += 1
                }
                if store.isReady {
                    markApplied(key, channel: channel)
                    markApplied(Self.indexerTimedKey(row.id), channel: channel)
                }
            }
        }
        if insertedCount > 0 {
            if prune { await store.pruneExpiredMessages() }
            guard isCurrentWallet(generation) else { return }
            loadMessages(for: channel)
        }
    }

    /// Marks a row whose block time came from the indexer, which then has the last word: the
    /// stream can see a transaction in a different block, with a different time.
    private static func indexerTimedKey(_ txId: String) -> String { "\(txId)@indexer" }

    /// Sends started in this run, by pending id. A row still pending that isn't one of these was left
    /// by a run that ended mid-send, and nothing is working on it.
    private var pendingSendsThisRun: Set<String> = []
    /// Rooms already checked for those rows, once per account per run.
    private var settledPendingChannels: Set<String> = []
    /// Rooms settled early because their indexer is down. They still get the full check once the
    /// backfill finishes, which drops a "Not confirmed" row whose delivered copy then arrived.
    private var settledWhileIndexerDown: Set<String> = []

    /// After the room's full history is in (the deep backfill), so a send that did land has its
    /// delivered copy to match. Also once while the room's indexer is confirmed down: no history
    /// is coming, and the rows would otherwise say "Sending" with no Retry all session.
    private func settlePendingSendsFromBeforeThisRun(channel: String, indexerDown: Bool = false) {
        guard store.isReady, !settledPendingChannels.contains(channel) else { return }
        if indexerDown {
            guard !settledWhileIndexerDown.contains(channel) else { return }
            settledWhileIndexerDown.insert(channel)
        } else {
            settledPendingChannels.insert(channel)
        }
        if store.settlePendingMessages(inChannel: channel, keeping: pendingSendsThisRun) {
            loadMessages(for: channel)
        }
    }


    /// True while this channel's room screen is open (the acquire/release refcount) - the
    /// notification policy's "currently open conversation": banners for a room the user is
    /// looking at are suppressed (here for scan-driven local banners, and in
    /// `AppDelegate.willPresent` for remote pushes), everything else fires even in-app.
    func isViewing(channel: String) -> Bool {
        liveViewRefCounts[PublicChatChannelName.normalize(channel)] != nil
    }

    /// Call when a public chat channel screen disappears; pairs with `acquire`.
    func release(_ name: String) {
        let normalized = PublicChatChannelName.normalize(name)
        guard let count = liveViewRefCounts[normalized] else { return }
        if count <= 1 {
            // Everything that arrived while the room was open has been seen.
            markChannelRead(normalized)
            liveViewRefCounts.removeValue(forKey: normalized)
            stopIndexerPolling(channel: normalized)
            // Closed: back to its summary (`summaryWindowSize`), and "Load earlier messages"
            // starts over next time, so every room ever opened doesn't keep 400+ rows all session.
            windowSizeByChannel.removeValue(forKey: normalized)
            windowExhausted.remove(normalized)
            if messagesByChannel[normalized] != nil { loadMessages(for: normalized) }
        } else {
            liveViewRefCounts[normalized] = count - 1
        }
        updateScanningStateIfNeeded()
    }

    private var wantedChannels: Set<String> {
        var wanted = Set(liveViewRefCounts.keys)
        // The bell is the one control: a room with notifications on is listened to while the app
        // is open (that is what lets it notify, and count unread), any room. The separate
        // "listen" switch is gone; a value stored by an older build is no longer read.
        for channel in channels where channel.notifyEnabled {
            wanted.insert(channel.channelName)
        }
        return wanted
    }

    // MARK: - Messages

    func messages(forChannel name: String) -> [PublicChatMessage] {
        messagesByChannel[PublicChatChannelName.normalize(name)] ?? []
    }

    /// One of the room's loaded messages, by id: nil when it isn't loaded (older than the
    /// room's window, from a hidden or blocked sender, or never seen here).
    func message(id: String, inChannel name: String) -> PublicChatMessage? {
        messagesByIdByChannel[PublicChatChannelName.normalize(name)]?[id]
    }

    /// The room's long voice notes: one bubble per note at its anchor, the other parts hidden.
    func voiceNotes(forChannel name: String) -> PublicChatVoiceParts.Result {
        voiceNotesByChannel[PublicChatChannelName.normalize(name)] ?? PublicChatVoiceParts.Result()
    }

    /// Aggregated reactions for a channel, keyed by the reacted-to message's txId. Reactions on
    /// a long voice note's hidden parts (sent by a client that shows parts one by one) are
    /// shown on the note's bubble, keyed by its anchor.
    func reactions(forChannel name: String) -> [String: [PublicChatReactionSnapshot]] {
        let channel = PublicChatChannelName.normalize(name)
        let byTarget = reactionsByChannel[channel] ?? [:]
        guard let anchors = voiceNotesByChannel[channel]?.anchorIdByPartId, !anchors.isEmpty else { return byTarget }
        var merged = byTarget
        for (partId, anchorId) in anchors {
            guard let partReactions = byTarget[partId], !partReactions.isEmpty else { continue }
            merged.removeValue(forKey: partId)
            var onAnchor = merged[anchorId] ?? []
            for reaction in partReactions where !onAnchor.contains(where: { $0.reactorAddress == reaction.reactorAddress }) {
                onAnchor.append(reaction)
            }
            merged[anchorId] = onAnchor
        }
        return merged
    }

    func edits(forChannel name: String) -> [String: MessageEditSnapshot] {
        editsByChannel[PublicChatChannelName.normalize(name)] ?? [:]
    }

    /// Read on a background context. Opening a room called this and `loadReactions`
    /// synchronously on the main thread, whole channel each, while the room was sliding in.
    /// A generation per channel keeps an older read that finishes late from overwriting a newer
    /// one (a local edit reloads straight after its write).
    private func loadEdits(for channel: String) {
        editLoadGeneration[channel, default: 0] &+= 1
        let generation = editLoadGeneration[channel]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fresh = await self.store.fetchEditsAsync(forChannel: channel)
            guard self.editLoadGeneration[channel] == generation,
                  self.editsByChannel[channel] != fresh else { return }
            self.editsByChannel[channel] = fresh
        }
    }
    private var editLoadGeneration: [String: Int] = [:]
    private var reactionLoadGeneration: [String: Int] = [:]

    /// An edit envelope seen in a room (scan, indexer page or sweep): applied if its sender
    /// sent the message it names and that message is text. Returns whether anything changed.
    private func applyIncomingEdit(_ edit: MessageEditContent, channel: String, senderAddress: String, editTxId: String, blockTime: Int64) -> Bool {
        guard let target = store.sender(ofMessage: edit.targetTxId),
              target.senderAddress == senderAddress,
              MessageEditCodec.isEditable(target.content) else { return false }
        return store.upsertEdit(targetTxId: edit.targetTxId, channel: channel, text: edit.text, editTxId: editTxId, blockTime: blockTime, deliveryStatus: nil)
    }

    // MARK: - Edit

    func startEditing(_ message: PublicChatMessage) {
        replyingTo = nil
        editingMessage = message
    }

    func cancelEditing() {
        editingMessage = nil
    }

    /// The message this room's composer is editing. Nil when the one in progress is another room's.
    func editTarget(inChannel name: String) -> PublicChatMessage? {
        guard let editing = editingMessage, editing.channelName == PublicChatChannelName.normalize(name) else { return nil }
        return editing
    }

    /// The message this room's composer is replying to. Nil when it's another room's.
    func replyTarget(inChannel name: String) -> PublicChatMessage? {
        guard let reply = replyingTo, reply.channelName == PublicChatChannelName.normalize(name) else { return nil }
        return reply
    }

    /// The text of this message's failed edit, when there is one to retry.
    func failedEditText(forChannel name: String, targetTxId: String) -> String? {
        failedEditsByChannel[PublicChatChannelName.normalize(name)]?[targetTxId]
    }

    func retryFailedEdit(channel: String, targetTxId: String) async throws {
        guard let text = failedEditText(forChannel: channel, targetTxId: targetTxId) else { return }
        try await sendPublicChatEdit(channel: channel, targetTxId: targetTxId, text: text)
    }

    /// Edits one of this wallet's own text messages in a room: applied locally at once
    /// (pending), then sent as an edit envelope exactly like a reaction - one transaction, no
    /// message row of its own. Sent or failed follow.
    func sendPublicChatEdit(channel rawChannel: String, targetTxId: String, text: String) async throws {
        let channel = PublicChatChannelName.normalize(rawChannel)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let privateKey = WalletManager.shared.getPrivateKey() else { throw KasiaError.keychainError("Could not get private key") }
        if editingMessage?.id == targetTxId { editingMessage = nil }
        failedEditsByChannel[channel]?[targetTxId] = nil
        // What the message reads now, to go back to if this never leaves the phone.
        let previous = editsByChannel[channel]?[targetTxId]
        let payload = MessageEditCodec.encode(targetTxId: targetTxId, text: clean)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.upsertEdit(targetTxId: targetTxId, channel: channel, text: clean, editTxId: nil, blockTime: now, deliveryStatus: "pending")
        loadEdits(for: channel)
        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendPublicChatInternal(
                    channel: channel, content: payload, walletAddress: wallet.publicAddress,
                    privateKey: privateKey, pendingId: "edit_\(UUID().uuidString)"
                )
            }
            store.upsertEdit(targetTxId: targetTxId, channel: channel, text: clean, editTxId: realTxId, blockTime: now, deliveryStatus: nil)
            loadEdits(for: channel)
        } catch let unknown as SendOutcomeUnknownError {
            // It may have landed: "Not confirmed" with no Retry, which could pay twice. Its
            // delivered copy turns it into a normal edit.
            store.upsertEdit(targetTxId: targetTxId, channel: channel, text: clean, editTxId: unknown.txId.isEmpty ? nil : unknown.txId, blockTime: now, deliveryStatus: "unconfirmed")
            loadEdits(for: channel)
            throw unknown
        } catch {
            // Never sent: the message goes back to what it read, and the text waits for Retry.
            store.restoreEdit(targetTxId: targetTxId, to: previous)
            failedEditsByChannel[channel, default: [:]][targetTxId] = clean
            loadEdits(for: channel)
            throw error
        }
    }

    /// Background read with a per-channel generation - see `loadEdits`.
    private func loadReactions(for channel: String) {
        reactionLoadGeneration[channel, default: 0] &+= 1
        let generation = reactionLoadGeneration[channel]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stored = await self.store.fetchReactionsAsync(forChannel: channel)
            // Reactions from blocked accounts and senders hidden in this room aren't shown, like
            // their messages (audit #22). Read once the fetch is back, so a block made meanwhile counts.
            let hidden = self.store.hiddenSenderAddresses(forChannel: channel)
            var fresh = stored
            if !hidden.isEmpty {
                for (target, list) in stored {
                    let shown = list.filter { !hidden.contains($0.reactorAddress) }
                    if shown.count == list.count { continue }
                    fresh[target] = shown.isEmpty ? nil : shown
                }
            }
            guard self.reactionLoadGeneration[channel] == generation,
                  self.reactionsByChannel[channel] != fresh else { return }
            self.reactionsByChannel[channel] = fresh
        }
    }

    /// How many of a room's newest messages are in memory. Enough to scroll through a busy
    /// day; "Load earlier messages" at the top of the room widens it. The chess arena has no
    /// window: its reducer replays the whole room.
    static let roomWindowSize = 400
    /// A room that isn't open keeps only its newest rows: enough for the list's last message and
    /// an unread count up to "99+".
    static let summaryWindowSize = 100
    private var windowSizeByChannel: [String: Int] = [:]
    /// Rooms whose last read came back shorter than the window: nothing older to load.
    private var windowExhausted: Set<String> = []
    /// A read that finishes after a newer one began is dropped, not published.
    private var messageLoadGeneration: [String: Int] = [:]

    private func windowSize(for channel: String) -> Int? {
        if Self.serviceChannels.contains(channel) { return nil }
        guard isViewing(channel: channel) else { return Self.summaryWindowSize }
        return windowSizeByChannel[channel] ?? Self.roomWindowSize
    }

    /// Whether the room may hold messages older than what is loaded.
    func hasOlderMessages(forChannel name: String) -> Bool {
        let channel = PublicChatChannelName.normalize(name)
        guard windowSize(for: channel) != nil else { return false }
        return !windowExhausted.contains(channel)
    }

    /// Widens the room's window by another `roomWindowSize` and reloads it.
    func loadOlderMessages(forChannel name: String) async {
        let channel = PublicChatChannelName.normalize(name)
        guard let current = windowSize(for: channel), !windowExhausted.contains(channel) else { return }
        windowSizeByChannel[channel] = current + Self.roomWindowSize
        await reloadMessages(for: channel)
    }

    /// Reads the room's window on a background context and publishes it if it changed. Not
    /// synchronous any more: the read used to be a main-thread `performAndWait` over the whole
    /// room, on every merge, prune and open.
    private func loadMessages(for channel: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reloadMessages(for: channel)
        }
    }

    /// Reloads until the reload that publishes is one started here: a newer reload already
    /// in flight would otherwise win and publish later, after the caller has read the rows.
    private func reloadMessagesNow(for channel: String) async {
        for _ in 0..<3 {
            if await reloadMessages(for: channel) { return }
        }
    }

    /// False when a newer reload of the channel took over before this one published.
    @discardableResult
    private func reloadMessages(for channel: String) async -> Bool {
        let generation = (messageLoadGeneration[channel] ?? 0) + 1
        messageLoadGeneration[channel] = generation
        let limit = windowSize(for: channel)
        let walletAtStart = walletGeneration
        let rows = await store.messages(forChannel: channel, newestLimit: limit)
        // A read of the store the account had before a switch is not this account's room (and
        // nothing a caller waits for: true, so `reloadMessagesNow` doesn't try again).
        guard isCurrentWallet(walletAtStart) else { return true }
        guard messageLoadGeneration[channel] == generation else { return false }
        // Only an open room's read says whether older history is left (a summary read is short).
        if let limit, isViewing(channel: channel) {
            if rows.count < limit { windowExhausted.insert(channel) } else { windowExhausted.remove(channel) }
        }
        // Reaction envelopes are never rendered as message rows - drop any that made it into
        // the message table (rows scanned by an app version that predates reactions).
        // Off the main actor: up to 400 rows, each a codec sniff, on every reload - and a
        // room's first backfill reloads once per history page.
        let indexed = !Self.serviceChannels.contains(channel)
        let (fresh, voiceNotes, byId) = await Task.detached(priority: .userInitiated) {
            Self.preparedRows(rows, indexed: indexed)
        }.value
        guard isCurrentWallet(walletAtStart) else { return true }
        guard messageLoadGeneration[channel] == generation else { return false }
        // Only actually publish when the content changed: `@Published` fires on every
        // assignment regardless of equality, and an unconditional assignment re-rendered the
        // whole message list - including an open avatar menu - even when nothing had changed.
        guard messagesByChannel[channel] != fresh else { return true }
        voiceNotesByChannel[channel] = voiceNotes
        messagesByIdByChannel[channel] = byId
        messagesByChannel[channel] = fresh
        return true
    }

    /// Prunes expired messages across all joined channels and refreshes the given channel's
    /// visible list - called on a timer while a channel screen is open so retention feels
    /// live. Off the main thread now, so the timer is cheap; it still only re-reads the room
    /// when something was actually removed.
    func pruneNowAndRefresh(forChannel name: String) async {
        if await store.pruneExpiredMessages() {
            await reloadMessages(for: PublicChatChannelName.normalize(name))
        }
    }

    // MARK: - Reply

    func startReplyTo(_ message: PublicChatMessage) {
        replyingTo = message
    }

    func cancelReply() {
        replyingTo = nil
    }

    // MARK: - Retry

    func retryPublicChat(_ message: PublicChatMessage) {
        guard message.deliveryStatus == .failed else { return }
        // A second tap before the list redraws still carries the Failed snapshot: without this
        // it sent the message again and paid twice.
        guard !pendingSendsThisRun.contains(message.id) else { return }
        guard let wallet = WalletManager.shared.currentWallet, wallet.publicAddress == message.senderAddress else { return }
        guard let privateKey = WalletManager.shared.getPrivateKey() else { return }

        pendingSendsThisRun.insert(message.id)
        store.updateMessageStatus(id: message.id, status: .pending)
        loadMessages(for: message.channelName)

        Task {
            try? await self.resendPending(message, walletAddress: wallet.publicAddress, privateKey: privateKey)
        }
    }

    /// Retry on a long voice note's bubble: only its failed parts, one after another in index
    /// order, so each spends the change of the one before. All of them show Sending at once;
    /// when one fails again, the ones after it go back to Failed for the next Retry.
    func retryPublicChatVoiceParts(_ failedParts: [PublicChatMessage]) {
        guard let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey() else { return }
        // Parts already resending (a second tap on a bubble that hasn't redrawn) are left out.
        let parts = failedParts.filter {
            $0.deliveryStatus == .failed && $0.senderAddress == wallet.publicAddress && !pendingSendsThisRun.contains($0.id)
        }
        guard let first = parts.first else { return }
        for part in parts {
            pendingSendsThisRun.insert(part.id)
            store.updateMessageStatus(id: part.id, status: .pending)
        }
        loadMessages(for: first.channelName)

        Task {
            let chatService = ChatService.shared
            for (offset, part) in parts.enumerated() {
                guard self.isStillSignedIn(as: wallet.publicAddress) else {
                    // Cut short by a log out or switch: these never went, so Failed (in their
                    // own account's store), not "Sending" for the rest of the run.
                    self.failRemainingParts(Array(parts[offset...]), walletAddress: wallet.publicAddress)
                    return
                }
                do {
                    let went = try await self.resendPending(part, walletAddress: wallet.publicAddress, privateKey: privateKey)
                    if !went {
                        // This part waits for a confirmed coin and retries itself: the rest
                        // follow it the same way, in order through the send queue, as in
                        // `sendPublicChatVoiceParts` - not straight away, ahead of it.
                        for later in parts[(offset + 1)...] {
                            self.schedulePublicChatRetry(
                                channel: later.channelName,
                                content: later.content,
                                walletAddress: wallet.publicAddress,
                                privateKey: privateKey,
                                pendingId: later.id,
                                delaySeconds: chatService.nextNoInputRetryDelay(for: later.id)
                            )
                        }
                        return
                    }
                } catch {
                    self.failRemainingParts(Array(parts[(offset + 1)...]), walletAddress: wallet.publicAddress)
                    return
                }
            }
        }
    }

    /// Sends a row that is already marked pending again, under its own id. Throws when it
    /// failed (the row is then Failed or Not confirmed); returns true when it went, false when it
    /// was held for a deferred retry (no confirmed inputs yet).
    @discardableResult
    private func resendPending(_ message: PublicChatMessage, walletAddress: String, privateKey: Data) async throws -> Bool {
        do {
            _ = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendPublicChatInternal(
                    channel: message.channelName,
                    content: message.content,
                    walletAddress: walletAddress,
                    privateKey: privateKey,
                    pendingId: message.id
                )
            }
            return true
        } catch {
            let deferred = ChatService.shared.isNoConfirmedInputsError(error)
            try await handleSendFailure(
                error,
                channel: message.channelName,
                content: message.content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: message.id
            )
            return !deferred
        }
    }

    /// False once the account that started a send has logged out or been switched away from: the
    /// rest of a long voice note must not go out from the old account under the new one's
    /// session (the rows belong to the old account's store and stay for its next sign-in).
    private func isStillSignedIn(as address: String) -> Bool {
        WalletManager.shared.currentWallet?.publicAddress == address && !WalletManager.shared.isLoggedOut
    }

    /// The parts after one that failed never went: Failed too, so one Retry sends them in order.
    private func failRemainingParts(_ parts: [PublicChatMessage], walletAddress: String) {
        for part in parts {
            ChatService.shared.clearNoInputRetryState(for: part.id)
            markSendFailed(part.id, walletAddress: walletAddress, channel: part.channelName)
        }
    }

    /// Pending ids, per account (lowercased address), of sends that ended without going out
    /// while another account's store was open: marked Failed when that account's store opens
    /// again (`applyAbortedSends`). Not persisted: after a relaunch `settlePendingMessages`
    /// settles them as rows from a run that ended.
    private var abortedSendsByWallet: [String: Set<String>] = [:]

    /// A send that ended without going out: no longer "in this run", and Failed so Retry is
    /// offered - in the store of the account it was sent as. When that store isn't the open one
    /// (the account logged out or switched meanwhile), it is recorded for when it is.
    private func markSendFailed(_ pendingId: String, walletAddress: String, channel: String) {
        pendingSendsThisRun.remove(pendingId)
        let owner = walletAddress.lowercased()
        if store.isReady, self.walletAddress == owner, store.currentWalletAddress?.lowercased() == owner {
            store.markMessageFailed(pendingId: pendingId)
            loadMessages(for: channel)
        } else {
            abortedSendsByWallet[owner, default: []].insert(pendingId)
        }
    }

    /// The sends `markSendFailed` recorded for `walletAddress`, now that its store is open. Only
    /// rows still pending: anything else was settled since.
    private func applyAbortedSends(walletAddress: String?) {
        guard let owner = walletAddress?.lowercased(), store.isReady,
              let ids = abortedSendsByWallet.removeValue(forKey: owner) else { return }
        for id in ids where store.deliveryStatus(ofMessage: id) == .pending {
            store.markMessageFailed(pendingId: id)
        }
    }

    // MARK: - Reactions

    /// Reacts to `targetTxId` with `emoji` ("add"), or removes this wallet's existing reaction
    /// on it ("remove") - mirroring KaChat's `GroupChatService.sendGroupReaction`'s optimistic-apply/
    /// status-flip flow. The wire format is a NORMAL public chat whose content is the shared
    /// `MessageReactionCodec` JSON ({"type":"reaction","targetTxId":...,"emoji":...,"action":
    /// "add"|"remove"}), sent through the exact same tx pipeline as a text public chat (no reply
    /// wrapping) - Android and desktop speak the identical shape. Never creates a visible
    /// message row; receivers intercept it into their reactions index instead.
    func sendPublicChatReaction(channel rawChannel: String, targetTxId: String, emoji: String, action: String) async throws {
        let channel = PublicChatChannelName.normalize(rawChannel)
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        let payload = MessageReactionCodec.encode(targetTxId: targetTxId, emoji: emoji, action: action)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)

        // Optimistic local apply: pending "add" shows the pill immediately; "remove" clears it.
        // A remove is stored as a tombstone (emoji nil) rather than a row delete - see
        // `PublicChatStore`'s Reactions doc comment for why.
        store.upsertOwnReaction(
            targetTxId: targetTxId,
            channel: channel,
            reactorAddress: wallet.publicAddress,
            emoji: action == "remove" ? nil : emoji,
            reactionTxId: nil,
            blockTime: nowMillis,
            deliveryStatus: action == "remove" ? nil : "pending"
        )
        loadReactions(for: channel)

        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendPublicChatInternal(
                    channel: channel,
                    content: payload,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: "reaction_\(UUID().uuidString)"
                )
            }
            store.upsertOwnReaction(
                targetTxId: targetTxId,
                channel: channel,
                reactorAddress: wallet.publicAddress,
                emoji: action == "remove" ? nil : emoji,
                reactionTxId: realTxId,
                blockTime: Int64(Date().timeIntervalSince1970 * 1000),
                deliveryStatus: action == "remove" ? nil : "sent"
            )
            loadReactions(for: channel)
        } catch is SendOutcomeUnknownError {
            // It may have landed: left as it is, with no Retry that could send it twice.
            throw SendOutcomeUnknownError(txId: "")
        } catch {
            // The reaction tx failed to send. Flag it failed so the pill shows the red error
            // icon and a Retry appears under the message. A failed "remove" restores the
            // optimistically-cleared emoji (marked failed) so it isn't silently lost - Retry
            // re-attempts the correct action, matching group chat exactly.
            store.upsertOwnReaction(
                targetTxId: targetTxId,
                channel: channel,
                reactorAddress: wallet.publicAddress,
                emoji: emoji,
                reactionTxId: nil,
                blockTime: Int64(Date().timeIntervalSince1970 * 1000),
                deliveryStatus: "failed",
                failedAction: action
            )
            loadReactions(for: channel)
            throw error
        }
    }

    /// Re-attempts a public chat reaction whose send previously failed. `action` is the failed
    /// reaction's stored `failedAction` ("add"/"remove"). Delegates to `sendPublicChatReaction`,
    /// which clears the failed flag optimistically and re-flags it only if this attempt fails too.
    func retryPublicChatReaction(channel: String, targetTxId: String, emoji: String, action: String) async throws {
        try await sendPublicChatReaction(channel: channel, targetTxId: targetTxId, emoji: emoji, action: action)
    }

    // MARK: - Fee estimation

    /// Estimate the on-chain fee for sending `content` as a public chat right now, matching how
    /// 1:1 chat shows a live "fee: N sompi" preview while typing (`ChatService.estimateMessageFee`).
    /// Accounts for an active reply, since replies wrap the content in a larger envelope.
    func estimatePublicChatFee(channel rawChannel: String, content: String, feeOverride: UInt64? = nil) async throws -> UInt64 {
        if let feeOverride { return feeOverride }
        let channel = PublicChatChannelName.normalize(rawChannel)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.networkError("Message is empty")
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let payloadText: String
        if let reply = replyTarget(inChannel: channel) {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payloadText = MessageReplyCodec.encode(
                replyToId: reply.id,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payloadText = trimmed
        }

        let payload = KasiaTransactionBuilder.buildPublicChatPayload(channel: channel, content: payloadText)
        let utxos = try await ChatService.shared.fetchUtxosWithFallback(for: wallet.publicAddress)
        guard !utxos.isEmpty else {
            throw KasiaError.networkError(Self.notEnoughKasMessage)
        }
        return KasiaTransactionBuilder.estimatePublicChatFee(
            payload: payload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    /// Same estimate, but for a payload of a known byte size rather than real text - used for a
    /// live preview while a voice message is still being recorded (its final size isn't known
    /// yet), matching Android's `VoiceMessage.estimatedWirePayloadSize` heuristic.
    func estimatePublicChatFee(channel rawChannel: String, payloadByteCount: Int) -> UInt64? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            return nil
        }
        let dummyPayload = Data(count: max(0, payloadByteCount))
        return KasiaTransactionBuilder.estimatePublicChatFee(
            payload: dummyPayload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    // MARK: - Sending

    /// Send a voice message - wraps the same inline JSON shape used by 1:1 chat's
    /// `ChatService.sendAudio` (and matching Android's `VoiceMessageContent` field-for-field) so a
    /// voice message recorded on either platform plays back on both, then reuses `sendPublicChat`
    /// for the actual optimistic-send/reply-wrap/retry plumbing.
    func sendPublicChatAudio(
        channel: String,
        audioData: Data,
        fileName: String = "voice.webm",
        mimeType: String = "audio/webm"
    ) async throws {
        let base64 = audioData.base64EncodedString()
        // Deterministic field order (mimeType before content) - see MediaFileEnvelope.
        let jsonString = MediaFileEnvelope.json(
            name: fileName,
            size: audioData.count,
            mimeType: mimeType,
            dataUrlContent: "data:\(mimeType);base64,\(base64)"
        )
        try await sendPublicChat(channel: channel, content: jsonString)
    }

    /// The fee of a recorded voice note whose parts are `partSizes` bytes of WebM - the live
    /// fee while recording. One part is an untagged message; more are tagged parts.
    func estimatePublicChatVoiceFee(channel rawChannel: String, partSizes: [Int]) -> UInt64? {
        let channel = PublicChatChannelName.normalize(rawChannel)
        var total: UInt64 = 0
        for (offset, size) in partSizes.enumerated() {
            let tag = partSizes.count > 1
                ? VoicePartTag(id: String(repeating: "0", count: 32), index: offset + 1, count: partSizes.count)
                : nil
            let base64Length = 4 * ((max(0, size) + 2) / 3)
            let content = MediaFileEnvelope.json(
                name: tag?.fileName ?? "voice.webm",
                size: size,
                mimeType: "audio/webm",
                dataUrlContent: "data:audio/webm;base64," + String(repeating: "A", count: base64Length),
                voicePart: tag
            )
            let payload = KasiaTransactionBuilder.buildPublicChatPayload(channel: channel, content: content)
            guard let fee = estimatePublicChatFee(channel: channel, payloadByteCount: payload.count) else { return nil }
            total = ChatService.shared.addSompiSafely(total, fee)
        }
        return total
    }

    /// A long voice note: each part a complete WebM-Opus file sent as its own ordinary voice
    /// message, one transaction each, tagged `voicePart` with one random id (KaChat's format,
    /// KaChat MESSAGING.md "Long voice notes (multi-part)"). Parts belong together by (room,
    /// sender, id, count).
    ///
    /// The balance for every part is checked first. The parts then go out in index order, one
    /// after another through the send queue, so each spends the change of the one before.
    /// Parts never carry a reply: the reply envelope would push a part past what one
    /// transaction holds. A note of one part goes as an ordinary voice message
    /// (`sendPublicChatAudio`) instead.
    func sendPublicChatVoiceParts(channel rawChannel: String, parts: [Data], mimeType: String = "audio/webm") async throws {
        let channel = PublicChatChannelName.normalize(rawChannel)
        guard PublicChatChannelName.isValid(channel) else {
            throw KasiaError.networkError("Invalid channel name")
        }
        guard parts.count >= 2, parts.count <= VoicePartTag.maxParts, !parts.contains(where: \.isEmpty) else {
            throw KasiaError.networkError("Audio file is empty")
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        let noteId = VoicePartTag.newGroupId()
        var contents: [String] = []
        for (offset, data) in parts.enumerated() {
            guard let tag = VoicePartTag(id: noteId, index: offset + 1, count: parts.count) else {
                throw KasiaError.networkError("Audio file is empty")
            }
            contents.append(MediaFileEnvelope.json(
                name: tag.fileName,
                size: data.count,
                mimeType: mimeType,
                dataUrlContent: "data:\(mimeType);base64,\(data.base64EncodedString())",
                voicePart: tag
            ))
        }

        // The whole note first, before a single part goes out.
        try await ensureSufficientBalanceForVoiceParts(contents, channel: channel, walletAddress: wallet.publicAddress)

        // Every part shows at once, Sending, a millisecond apart so they keep their order.
        let start = Int64(Date().timeIntervalSince1970 * 1000)
        var pending: [PublicChatMessage] = []
        for (offset, content) in contents.enumerated() {
            let pendingId = "pending_\(UUID().uuidString)"
            pendingSendsThisRun.insert(pendingId)
            let blockTime = start + Int64(offset)
            store.insertMessage(
                id: pendingId,
                channel: channel,
                senderAddress: wallet.publicAddress,
                content: content,
                blockTime: blockTime,
                deliveryStatus: .pending
            )
            pending.append(PublicChatMessage(
                id: pendingId,
                channelName: channel,
                senderAddress: wallet.publicAddress,
                content: content,
                blockTime: blockTime,
                deliveryStatus: .pending
            ))
        }
        loadMessages(for: channel)
        // A part is never a reply, and the next message isn't one either.
        replyingTo = nil

        let chatService = ChatService.shared
        for (offset, part) in pending.enumerated() {
            guard isStillSignedIn(as: wallet.publicAddress) else {
                // Cut short by a log out or switch: the parts left never went - Failed, in
                // this account's own store, so its Retry finishes the note.
                failRemainingParts(Array(pending[offset...]), walletAddress: wallet.publicAddress)
                return
            }
            do {
                _ = try await chatService.enqueueOutgoingTxOperation {
                    try await self.sendPublicChatInternal(
                        channel: channel,
                        content: part.content,
                        walletAddress: wallet.publicAddress,
                        privateKey: privateKey,
                        pendingId: part.id
                    )
                }
            } catch {
                let rest = Array(pending[(offset + 1)...])
                if chatService.isNoConfirmedInputsError(error) {
                    // This part waits for a confirmed coin and retries itself; the rest follow
                    // it the same way, in order through the send queue.
                    try await handleSendFailure(
                        error,
                        channel: channel,
                        content: part.content,
                        walletAddress: wallet.publicAddress,
                        privateKey: privateKey,
                        pendingId: part.id
                    )
                    for later in rest {
                        schedulePublicChatRetry(
                            channel: channel,
                            content: later.content,
                            walletAddress: wallet.publicAddress,
                            privateKey: privateKey,
                            pendingId: later.id,
                            delaySeconds: chatService.nextNoInputRetryDelay(for: later.id)
                        )
                    }
                    return
                }
                failRemainingParts(rest, walletAddress: wallet.publicAddress)
                try await handleSendFailure(
                    error,
                    channel: channel,
                    content: part.content,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: part.id
                )
                return
            }
        }
    }

    /// What all of a note's parts cost together, against the coins there are, leaving the dust
    /// threshold over so the last part still has a change output to stand on. A check that
    /// can't be made (the node unreachable) lets the send go on and fail on its own.
    private func ensureSufficientBalanceForVoiceParts(_ contents: [String], channel: String, walletAddress: String) async throws {
        let chatService = ChatService.shared
        var totalFee: UInt64 = 0
        for content in contents {
            let payload = KasiaTransactionBuilder.buildPublicChatPayload(channel: channel, content: content)
            guard let fee = estimatePublicChatFee(channel: channel, payloadByteCount: payload.count) else { return }
            totalFee = chatService.addSompiSafely(totalFee, fee)
        }
        let utxos: [UTXO]
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
        } catch {
            AppLog.log("[PublicChatService] Voice note balance precheck unavailable, continuing send: %@", error.localizedDescription)
            return
        }
        let available = chatService.prepareMessageUtxos(confirmed: utxos)
            .reduce(UInt64(0)) { chatService.addSompiSafely($0, $1.amount) }
        guard available > 0 else {
            throw KasiaError.networkError(chatService.noSpendableFundsYetMessage())
        }
        let required = chatService.addSompiSafely(totalFee, KasiaTransactionBuilder.dustThreshold)
        guard available >= required else {
            throw chatService.formatInsufficientBalanceError(plannedSpendSompi: required, availableSompi: available)
        }
    }

    /// `deferNoInputRetry` false (the chess sends): a send whose coins are not spendable yet
    /// throws instead of being retried later in the background, so the caller - which retries a
    /// few times itself and then shows the error - never reports a move as sent that is not.
    /// Returns the transaction id; nil only when the send was deferred.
    /// `expectedSender` (the chess sends): the account that asked for this send. When the
    /// signed-in account is another one - now, or by the time the send's turn in the queue comes -
    /// nothing is sent (`SenderChangedError`), so a move, join, claim or stamp never goes out
    /// signed by the next account.
    @discardableResult
    func sendPublicChat(channel rawChannel: String, content: String, feeOverride: UInt64? = nil, deferNoInputRetry: Bool = true, expectedSender: String? = nil) async throws -> String? {
        let channel = PublicChatChannelName.normalize(rawChannel)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PublicChatChannelName.isValid(channel) else {
            throw KasiaError.networkError("Invalid channel name")
        }
        guard !trimmed.isEmpty else { return nil }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        if let expectedSender, wallet.publicAddress != expectedSender {
            throw SenderChangedError()
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            // Said in the app's language: it reaches the chess toasts as it is
            // (`friendlySendErrorMessage`).
            throw KasiaError.keychainError(AppLocalization.string("Private key unavailable."))
        }

        // If replying, wrap the content in the shared reply envelope (matches Android's
        // PublicChatViewModel.sendPublicChat) so the quote survives even if the original message is
        // later pruned or its sender hidden.
        let usedReply = replyTarget(inChannel: channel)
        let payload: String
        if let reply = usedReply {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payload = MessageReplyCodec.encode(
                replyToId: reply.id,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payload = trimmed
        }

        let pendingId = "pending_\(UUID().uuidString)"
        pendingSendsThisRun.insert(pendingId)
        let pendingBlockTime = Int64(Date().timeIntervalSince1970 * 1000)
        store.insertMessage(
            id: pendingId,
            channel: channel,
            senderAddress: wallet.publicAddress,
            content: payload,
            blockTime: pendingBlockTime,
            deliveryStatus: .pending
        )
        loadMessages(for: channel)

        do {
            let txId = try await ChatService.shared.enqueueOutgoingTxOperation {
                // Its turn came after other sends: the account may have switched meanwhile.
                if let expectedSender, WalletManager.shared.currentWallet?.publicAddress != expectedSender {
                    throw SenderChangedError()
                }
                return try await self.sendPublicChatInternal(
                    channel: channel,
                    content: payload,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: pendingId,
                    feeOverride: feeOverride
                )
            }
            // Sent: this reply has been used, and the next message isn't one. Only this reply:
            // another may have been started while the send was out.
            if let usedReply, replyingTo?.id == usedReply.id { replyingTo = nil }
            return txId
        } catch {
            try await handleSendFailure(
                error,
                channel: channel,
                content: payload,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                deferRetry: deferNoInputRetry
            )
            // Held for a deferred retry: the reply has been used too.
            if let usedReply, replyingTo?.id == usedReply.id { replyingTo = nil }
            return nil
        }
    }

    /// A send asked for by one account, when another is signed in: nothing went out.
    struct SenderChangedError: LocalizedError {
        var errorDescription: String? {
            AppLocalization.string("The account changed, so nothing was sent.")
        }
    }

    // MARK: - Own arena rows the chain has not shown yet

    /// When a due row may next be looked up (wall ms): one still in a mempool, or one the REST
    /// API could not answer for, is asked about again later, not on every tick.
    private var localStampNextCheck: [String: Int64] = [:]
    /// Own rows marked failed this session: if the chain shows one after all, it counts again.
    private var droppedServiceRows: Set<String> = []
    private nonisolated static let localStampsKey = "publicChatLocalStampSentAt"
    /// A row a node says it doesn't hold still waits this long from sending, for a REST API
    /// running behind - and never more than `restLagPastLookUpMs` past the caller's look-up
    /// (`olderThan`): the arena's is 60 s, so a move that never landed is the player's to play
    /// again by about 75 s, not two minutes on, with most of a five-minute clock still left.
    private static let restLagGraceMs: Int64 = 120_000
    private static let restLagPastLookUpMs: Int64 = 15_000

    private func trackLocalStamp(_ txId: String) {
        localStampSentAt[txId] = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// The chain (a scanned block or the indexer) showed the row: it carries the chain's time now.
    private func confirmLocalStamp(_ txId: String) {
        guard localStampSentAt[txId] != nil else { return }
        localStampSentAt[txId] = nil
        localStampNextCheck[txId] = nil
    }

    private nonisolated static func localStampsWalletKey(_ wallet: String) -> String { "\(localStampsKey).\(wallet)" }

    private nonisolated static func loadLocalStamps(wallet: String) -> [String: Int64] {
        guard let data = UserDefaults.standard.data(forKey: localStampsWalletKey(wallet)),
              let saved = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return saved.mapValues { _ in now }
    }

    private nonisolated static func saveLocalStamps(_ stamps: [String: Int64], wallet: String?) {
        guard let wallet, let data = try? JSONEncoder().encode(stamps) else { return }
        UserDefaults.standard.set(data, forKey: localStampsWalletKey(wallet))
    }

    /// Own arena rows the chain has not shown `bound` ms after they were sent. Each is looked up:
    /// accepted (REST API), it takes the block's time there; in a mempool or spent to a coin the
    /// address holds, it waits or counts as landed; found nowhere by a node that answered, once
    /// the REST API has had `restLagGraceMs` to catch up, it is marked failed, so the arena's
    /// reducer stops applying it and the board is the chain's again (a move is the player's to
    /// play again). A row the network cannot be asked about is given up after `giveUp` ms. A
    /// failed row the chain shows later takes its block time and counts again
    /// (`PublicChatStore.updateBlockTime`). Returns the ids marked failed.
    func checkUnconfirmedServiceRows(olderThan bound: Int64, giveUpAfter giveUp: Int64) async -> Set<String> {
        guard !isCheckingLocalStamps else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let due = localStampSentAt.filter { now - $0.value > bound && (localStampNextCheck[$0.key] ?? 0) <= now }
        guard !due.isEmpty else { return [] }
        let restLagGrace = min(Self.restLagGraceMs, bound + Self.restLagPastLookUpMs)
        isCheckingLocalStamps = true
        defer { isCheckingLocalStamps = false }
        var failed: Set<String> = []
        var changed = false
        for (txId, sentAt) in due {
            let lookup = await Self.lookUpTransaction(txId: txId)
            // The chain showed it while the lookup ran.
            guard localStampSentAt[txId] != nil else { continue }
            let later = Int64(Date().timeIntervalSince1970 * 1000) + 15_000
            switch lookup {
            case .accepted(let blockTime):
                confirmLocalStamp(txId)
                if let blockTime, store.updateBlockTime(id: txId, blockTime: blockTime) { changed = true }
                continue
            case .unanswered where now - sentAt <= giveUp:
                localStampNextCheck[txId] = later
                continue
            case .notAccepted:
                if await NodePoolService.shared.getMempoolEntry(txId: txId) != nil {
                    localStampNextCheck[txId] = later
                    continue
                }
                // Asked again well before the grace runs out, so the drop lands at it and not
                // up to a check interval after.
                let nextCheck = min(later, sentAt + restLagGrace + 1_000)
                // No mempool entry also comes back when no node could be asked, and a 404 from a
                // REST API running behind: neither says the transaction is gone.
                let address = WalletManager.shared.currentWallet?.publicAddress
                if let address, let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address], allowRestFallback: false) {
                    if utxos.contains(where: { $0.outpoint.transactionId == txId }) {
                        confirmLocalStamp(txId)
                        continue
                    }
                    if now - sentAt <= restLagGrace {
                        localStampNextCheck[txId] = max(nextCheck, Int64(Date().timeIntervalSince1970 * 1000) + 1_000)
                        continue
                    }
                } else if now - sentAt <= giveUp {
                    localStampNextCheck[txId] = later
                    continue
                }
            case .unanswered:
                break
            }
            // The chain showed it, or the account changed, while the lookups ran.
            guard localStampSentAt[txId] != nil else { continue }
            AppLog.log("[PublicChatService] Own arena tx %@ never reached the chain: dropped", String(txId.prefix(12)))
            localStampSentAt[txId] = nil
            localStampNextCheck[txId] = nil
            store.updateMessageStatus(id: txId, status: .failed)
            droppedServiceRows.insert(txId)
            failed.insert(txId)
            changed = true
        }
        if changed {
            for channel in Self.serviceChannels { loadMessages(for: channel) }
        }
        return failed
    }

    private enum TransactionLookup {
        case accepted(blockTime: Int64?)
        case notAccepted
        case unanswered
    }

    /// The REST API's view of a transaction: accepted (with its block's time), unknown or not
    /// accepted, or no answer.
    private static func lookUpTransaction(txId: String) async -> TransactionLookup {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=false&resolve_previous_outpoints=no") else { return .unanswered }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unanswered }
        if status == 404 { return .notAccepted }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unanswered }
        guard (json["is_accepted"] as? Bool) == true else { return .notAccepted }
        return .accepted(blockTime: (json["block_time"] as? NSNumber)?.int64Value)
    }

    /// What a chess send should say when the chatting address has no coins at all - not the
    /// "wait for confirmations" of a change output still being mined, which retries.
    static var notEnoughKasMessage: String {
        AppLocalization.string("Not enough KAS on your Chatting Address. Add some and try again.")
    }

    /// Worth trying again in a moment: the coins are there but not spendable yet (the change of
    /// the last send), or the node rejected the transaction as an orphan / already spent - none
    /// of which reached the chain. Anything else (no funds, a timeout whose outcome is unknown)
    /// is not retried blindly.
    static func isRetryableSendError(_ error: Error) -> Bool {
        let chatService = ChatService.shared
        if chatService.isNoConfirmedInputsError(error) || chatService.shouldRetrySendError(error) { return true }
        let confirming = AppLocalization.string("The network is still confirming your previous send. Please try again in a few seconds.").lowercased()
        return error.localizedDescription.lowercased().contains(confirming)
    }

    /// If sending too quickly back-to-back races the previous public chat's not-yet-confirmed
    /// UTXOs, `sendPublicChatInternal` surfaces that as a "no confirmed inputs" error - automatic-
    /// ally retry those with backoff (matches 1:1 chat's `scheduleOutgoingRetry`) instead of
    /// leaving the user to notice and manually tap retry. Any other error still fails immediately.
    private func handleSendFailure(
        _ error: Error,
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        deferRetry: Bool = true
    ) async throws {
        if let unknown = error as? SendOutcomeUnknownError {
            // It may have landed, so no Retry, which would post and pay twice. "Not confirmed"
            // until its delivered copy shows up.
            ChatService.shared.clearNoInputRetryState(for: pendingId)
            pendingSendsThisRun.remove(pendingId)
            store.markMessageUnconfirmed(pendingId: pendingId, txId: unknown.txId)
            loadMessages(for: channel)
            lastSendError = KasiaError.networkError(SendOutcomeUnknownError.message)
            // Kept as itself: a caller must be able to tell "may have gone through" from a
            // failure (a bot stamp offers no Retry for it - a second stamp of the same game).
            throw unknown
        }
        // `deferRetry` false (the chess sends): thrown for the caller to retry, never queued.
        if deferRetry, ChatService.shared.isNoConfirmedInputsError(error) {
            let delay = ChatService.shared.nextNoInputRetryDelay(for: pendingId)
            AppLog.log("[PublicChatService] Deferred retry (no confirmed inputs) for %@ in %.0fs",
                  String(pendingId.prefix(12)), delay)
            schedulePublicChatRetry(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                delaySeconds: delay
            )
            return
        }
        ChatService.shared.clearNoInputRetryState(for: pendingId)
        // No send is working on it any more, so its Retry may start one - in the store of the
        // account it was sent as, even if another account is open by now.
        markSendFailed(pendingId, walletAddress: walletAddress, channel: channel)
        // Surface a humanized message (never kaspad's raw "orphan is disallowed" text) - this is
        // what the composer's "Failed to send" toast renders, possibly while the user is already
        // typing their next message.
        let surfaced = KasiaError.networkError(Self.friendlySendErrorMessage(for: error))
        lastSendError = surfaced
        throw surfaced
    }

    private func schedulePublicChatRetry(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        delaySeconds: TimeInterval
    ) {
        guard !scheduledSendRetries.contains(pendingId) else { return }
        scheduledSendRetries.insert(pendingId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self else { return }
            self.scheduledSendRetries.remove(pendingId)
            guard self.isStillSignedIn(as: walletAddress) else {
                // The account it was sent as is gone: it never went, so Failed in that
                // account's store rather than "Sending" with nothing working on it.
                ChatService.shared.clearNoInputRetryState(for: pendingId)
                self.markSendFailed(pendingId, walletAddress: walletAddress, channel: channel)
                return
            }
            let currentStatus = self.store.deliveryStatus(ofMessage: pendingId)
            guard currentStatus == .pending else {
                ChatService.shared.clearNoInputRetryState(for: pendingId)
                return
            }
            do {
                _ = try await ChatService.shared.enqueueOutgoingTxOperation {
                    try await self.sendPublicChatInternal(
                        channel: channel,
                        content: content,
                        walletAddress: walletAddress,
                        privateKey: privateKey,
                        pendingId: pendingId
                    )
                }
            } catch {
                try? await self.handleSendFailure(
                    error,
                    channel: channel,
                    content: content,
                    walletAddress: walletAddress,
                    privateKey: privateKey,
                    pendingId: pendingId
                )
            }
        }
    }

    /// Returns the submitted transaction's id. For a normal message send the pending row is
    /// resolved to it in-store; reaction sends (which have no message row - their `pendingId` is
    /// synthetic) use the returned id to stamp the reaction's `reactionTxId`.
    @discardableResult
    private func sendPublicChatInternal(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        feeOverride: UInt64? = nil
    ) async throws -> String {
        let chatService = ChatService.shared

        // Fetch UTXOs fresh (not the 20s-stale `fetchCachedUtxos`) and merge in any pending
        // change output from a just-submitted public chat, excluding whatever it just spent - the
        // same in-flight UTXO chaining 1:1 messages use, so sending several public chats back-to-
        // back doesn't try to double-spend the same not-yet-confirmed UTXO.
        let freshUtxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
        let candidateUtxos = chatService.prepareMessageUtxos(confirmed: freshUtxos)
        guard !candidateUtxos.isEmpty else {
            // No coin that waiting frees up (one being mined, or spent by a send in flight): a
            // coin a scheduled post holds, or a mining reward, won't be free in seconds. Say so
            // instead of "wait for confirmations" - which retried in the background forever.
            let freedByWaiting = KaPostsScheduledStore.filterReserved(freshUtxos.filter { !$0.isCoinbase })
            if freedByWaiting.isEmpty { throw KasiaError.networkError(Self.notEnoughKasMessage) }
            throw KasiaError.networkError(chatService.noSpendableFundsYetMessage())
        }

        do {
            return try await buildSignSubmitPublicChat(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                utxos: candidateUtxos,
                feeOverride: feeOverride
            )
        } catch {
            // The node pool hedges submits across nodes, so the node this landed on can be a few
            // seconds behind the node that served the UTXO snapshot (or behind a just-accepted
            // public chat whose change we chained). It then rejects with kaspad's raw
            // "... is an orphan, where orphan is disallowed" / "already spent" text. That's a
            // transient state mismatch, not a user error - retry ONCE with a freshly fetched,
            // confirmed-only input set (mirrors the 1:1 path's confirmed-only fallback) before
            // giving up, instead of surfacing raw node text (see friendlySendErrorMessage).
            guard chatService.shouldRetrySendError(error) else { throw error }
            let refetched = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
            let confirmedOnly = chatService.prepareMessageUtxos(confirmed: refetched)
                .filter { $0.blockDaaScore > 0 }
            guard !confirmedOnly.isEmpty else { throw error }
            AppLog.log("[PublicChatService] Submit rejected (%@) for %@ - retrying with confirmed-only inputs",
                       error.localizedDescription, String(pendingId.prefix(12)))
            return try await buildSignSubmitPublicChat(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                utxos: confirmedOnly,
                feeOverride: feeOverride
            )
        }
    }

    /// One build -> sign -> submit -> bookkeeping attempt against a fixed candidate UTXO set.
    /// Split out of `sendPublicChatInternal` so the orphan/already-spent fallback there can rerun
    /// the whole attempt against a refreshed input set.
    private func buildSignSubmitPublicChat(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        utxos candidateUtxos: [UTXO],
        feeOverride: UInt64?
    ) async throws -> String {
        let chatService = ChatService.shared

        let tx = try KasiaTransactionBuilder.buildPublicChatTx(
            from: walletAddress,
            channel: channel,
            content: content,
            senderPrivateKey: privateKey,
            utxos: candidateUtxos,
            feeOverride: feeOverride
        )
        let spentUtxos = chatService.spentMessageUtxos(from: tx, candidates: candidateUtxos)
        let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }

        do {
            let (txId, _) = try await NodePoolService.shared.submitTransaction(tx, allowOrphan: usesUnconfirmedInputs)
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) {
                chatService.addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            chatService.clearNoInputRetryState(for: pendingId)
            let blockTime = Int64(Date().timeIntervalSince1970 * 1000)
            if Self.serviceChannels.contains(channel) { trackLocalStamp(txId) }
            store.resolvePendingMessage(pendingId: pendingId, realId: txId, blockTime: blockTime)
            loadMessages(for: channel)
            return txId
        } catch let unknown as SendOutcomeUnknownError {
            guard Self.serviceChannels.contains(channel) else {
                // Not held (see `recordPlainSend`), so another message picks the same coins if
                // this one never lands, and is refused rather than doubling up if it did.
                chatService.invalidateUtxoCache()
                throw unknown
            }
            // An arena row (from KaPlay, 2026-11-21): a node may hold it, so its coins stay
            // reserved (the reservation runs out by itself if it never lands), or the next move
            // would spend them again. It is kept as sent - a move's ply stays taken - and the
            // unconfirmed-row check settles it (`checkUnconfirmedServiceRows`): the chain shows
            // it, or it is dropped.
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) {
                chatService.addPendingOutputs(from: tx, txId: unknown.txId, senderScriptPubKey: senderScriptPubKey)
            }
            chatService.clearNoInputRetryState(for: pendingId)
            trackLocalStamp(unknown.txId)
            store.resolvePendingMessage(pendingId: pendingId, realId: unknown.txId, blockTime: Int64(Date().timeIntervalSince1970 * 1000))
            loadMessages(for: channel)
            return unknown.txId
        } catch {
            chatService.releaseMessageOutpoints()
            throw error
        }
    }

    /// Node-level rejection text ("transaction ... is an orphan, where orphan is disallowed",
    /// "already spent", ...) means "the network hasn't caught up with your previous send yet" -
    /// meaningless and alarming to a user mid-typing. Map it (after retries are exhausted) to a
    /// plain-language message. Everything else - a node's or the API's raw text included - goes
    /// through `UserFacingError.message`, which says it in the app's language; this is what the
    /// chess toasts show (`ChessTournamentService.send`).
    static func friendlySendErrorMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("orphan") || lower.contains("already spent") || lower.contains("double spend") {
            return AppLocalization.string("The network is still confirming your previous send. Please try again in a few seconds.")
        }
        if lower.contains("insufficient funds") { return notEnoughKasMessage }
        // The app's own errors whose English description `UserFacingError` passes on as it is.
        if let kasia = error as? KasiaError {
            switch kasia {
            case .walletNotFound:
                return AppLocalization.string("Account not found. Please create or import an account.")
            case .invalidAddress:
                return AppLocalization.string("Invalid Kaspa address format.")
            case .keychainError:
                return AppLocalization.string("Private key unavailable.")
            case .unknownError:
                return AppLocalization.string("Something went wrong. Please try again.")
            default:
                break
            }
        }
        // The app's own sentence as it was written, without "Network error: " in front - which
        // `handleSendFailure`'s wrapping then doubled. That's how a builder's message (no coins
        // on the chatting address, a balance spread over too many small coins to fit one
        // transaction) reaches the player as is.
        return UserFacingError.message(for: error)
    }

    // MARK: - Block scanning lifecycle

    /// The rooms that need the block stream, on every connection (audit #26, 2026-11-22: it used
    /// to stream every bell-on room on Wi-Fi, #kaspa and #kachat-bugs by default, which kept the
    /// app parsing about ten full blocks a second whenever it was open). A room needs it when:
    /// - the indexer doesn't cover it (no indexer keeps its history, its indexer is blank, or
    ///   isn't answering, or it's the arena while the arena's indexer is down): the stream is
    ///   its only live route;
    /// - it's open on screen, on Wi-Fi: the fast path on top of the room's 8 s indexer poll (the
    ///   chess arena counts as open while a chess screen is up). On an expensive (cellular)
    ///   path an open covered room keeps to its poll, as before.
    /// A covered room with its bell on that isn't open gets its new messages from the
    /// closed-room sweep (`sweepClosedRooms`, every 20 s) and remote push, on every connection.
    private var scanWantedChannels: Set<String> {
        let expensive = NetworkEpochMonitor.shared.isExpensivePath
        return wantedChannels.filter { channel in
            guard isIndexerCovered(channel) else { return true }
            return !expensive && isViewing(channel: channel)
        }
    }

    /// Whether the indexer serves this room's history and is answering for it right now. Per
    /// room, since each can point at its own indexer: a room whose override is blank uses the
    /// app-wide setting. An indexer that isn't answering covers nothing until it does.
    private func isIndexerCovered(_ channel: String) -> Bool {
        if channel == ChessTournamentCodec.arenaChannel, arenaIndexerDown { return false }
        guard Self.isIndexerTracked(channel) else { return false }
        let base = Self.indexerBaseURL(forChannel: channel)
        return !base.isEmpty && unreachableIndexers[base] == nil
    }

    /// The rooms the stream is on for, as of the last `updateScanningStateIfNeeded`: the block
    /// handler only checks authors for these.
    private var streamChannels: Set<String> = []

    /// Indexers confirmed down (the same rule as KaPost's: three failures in a row inside two
    /// minutes), and since when. Their rooms go back on the block stream.
    private var unreachableIndexers: [String: Date] = [:]
    private var indexerFailureRuns: [String: (count: Int, last: Date)] = [:]
    /// Oldest a room's next backfill needs to reach after an outage (ms): the indexer gets the
    /// last word on that stretch, without paging its whole 30 days again.
    private var deepBackfillFloor: [String: Int64] = [:]

    private func noteIndexerResult(base: String, failed: Error?) {
        // A 4xx is the indexer answering, whatever it thinks of this request; so is a body that
        // won't decode (the rule in CLAUDE.md, "With the indexer down").
        guard let failed, !Self.isClientRejection(failed), !(failed is DecodingError) else {
            indexerFailureRuns[base] = nil
            guard let since = unreachableIndexers.removeValue(forKey: base) else { return }
            AppLog.log("[PublicChat] Room indexer is answering again")
            rewindRoomsAfterOutage(base: base, since: since)
            updateScanningStateIfNeeded()
            return
        }
        guard KaPostsIndexerHealth.meansDown(failed) || Self.isServerFailure(failed) else { return }
        let now = Date()
        var run = indexerFailureRuns[base] ?? (count: 0, last: .distantPast)
        // A handoff fails every open room's poll at the same moment, and that is one failure.
        if now.timeIntervalSince(run.last) < 5 { return }
        if now.timeIntervalSince(run.last) > 120 { run.count = 0 }
        run.count += 1
        run.last = now
        indexerFailureRuns[base] = run
        guard run.count >= 3, unreachableIndexers[base] == nil else { return }
        unreachableIndexers[base] = now
        AppLog.log("[PublicChat] Room indexer isn't answering: rooms stay on the block stream")
        updateScanningStateIfNeeded()
    }

    private nonisolated static func isClientRejection(_ error: Error) -> Bool {
        guard case PublicChatIndexerClient.ClientError.badResponse(let code) = error else { return false }
        return (400..<500).contains(code) && !KaPostsIndexerHealth.meansDown(statusCode: code)
    }

    private nonisolated static func isServerFailure(_ error: Error) -> Bool {
        guard case PublicChatIndexerClient.ClientError.badResponse(let code) = error else { return false }
        return KaPostsIndexerHealth.meansDown(statusCode: code)
    }

    /// Rooms this indexer serves read that stretch from it again, from ten minutes before it went
    /// away: what the block stream missed comes in, and the indexer has the final word.
    private func rewindRoomsAfterOutage(base: String, since: Date) {
        let floor = Int64((since.timeIntervalSince1970 - 600) * 1000)
        for channel in deepBackfilledChannels where Self.indexerBaseURL(forChannel: channel) == base {
            deepBackfilledChannels.remove(channel)
            deepBackfillFloor[channel] = floor
        }
    }

    private func updateScanningStateIfNeeded() {
        let rooms = scanWantedChannels
        if rooms != streamChannels { streamChannels = rooms }
        let shouldScan = !rooms.isEmpty
        guard shouldScan != isScanningActive else { return }
        AppLog.log("%@", shouldScan
            ? "[PublicChat] Block stream on for \(rooms.count) room(s)"
            : "[PublicChat] Block stream off: the indexer covers every room")
        isScanningActive = shouldScan
        if shouldScan {
            startScanning()
        } else {
            stopScanning()
        }
    }

    private nonisolated static let blockScanQueue = DispatchQueue(label: "com.kachat.broadcastBlockScan", qos: .utility)

    /// One fully-parsed public chat candidate from a scanned block. `senderAddress` is what
    /// output 0 claims until `verifiedAuthors` has checked input 0 spends from it (XP-012).
    struct BlockScanHit {
        let channel: String
        let txId: String
        let senderAddress: String
        let content: String
        let blockTime: Int64
        var inputTxId: String = ""
        var inputIndex: UInt32 = 0
    }

    /// OFF-MAIN block scan over the stream's once-parsed `ScannedBlock` (the old path decoded
    /// the whole protobuf block again here, and again in KaChat's GroupChatService). Pure extraction,
    /// no state: wanted/hidden filtering happens on the main hop, which only fires for actual
    /// hits (almost every block has zero).
    private nonisolated static func extractPublicChatHits(_ block: ScannedBlock, hrp: String) -> [BlockScanHit] {
        var hits: [BlockScanHit] = []
        for tx in block.transactions {
            guard tx.payloadHex.hasPrefix(bcastPrefixHex) || tx.payloadHex.hasPrefix(legacyBcastPrefixHex) else { continue }
            guard let payloadData = CryptoUtils.hexToData(tx.payloadHex),
                  let payloadString = String(data: payloadData, encoding: .utf8),
                  let parsed = KasiaTransactionBuilder.parsePublicChatPayload(payloadString) else { continue }
            guard let scriptData = CryptoUtils.hexToData(tx.firstOutputScriptHex),
                  let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
            hits.append(BlockScanHit(
                channel: PublicChatChannelName.normalize(parsed.channel),
                txId: tx.txId,
                senderAddress: senderAddress,
                content: parsed.content,
                blockTime: tx.blockTime,
                inputTxId: tx.firstInputTxId,
                inputIndex: tx.firstInputIndex
            ))
        }
        return hits
    }

    /// XP-012: a public chat payload carries no signature, so its author is whoever signed the
    /// transaction. A post is kept only when the address its input 0 spends from is the address
    /// output 0 pays (the rule Desktop uses); otherwise anyone could post, edit messages and play
    /// chess as any address by paying them output 0. Input 0's address comes from a recent payload
    /// transaction's outputs (a poster's previous post) or else the REST API; a post whose input
    /// can't be resolved is dropped.
    private nonisolated static func verifiedAuthors(_ hits: [BlockScanHit], hrp: String) async -> [BlockScanHit] {
        await withTaskGroup(of: BlockScanHit?.self) { group in
            for hit in hits {
                group.addTask {
                    guard !hit.inputTxId.isEmpty,
                          let spentFrom = await inputAddress(txId: hit.inputTxId, index: hit.inputIndex, hrp: hrp),
                          spentFrom.lowercased() == hit.senderAddress.lowercased() else {
                        AppLog.log("[PublicChat] dropped %@: input 0 is not the posting address", hit.txId)
                        return nil
                    }
                    return hit
                }
            }
            var kept: [BlockScanHit] = []
            for await hit in group { if let hit { kept.append(hit) } }
            return kept
        }
    }

    /// The address an outpoint pays: from the recent-output cache, else the REST API (the
    /// previous transaction is older than the post, so it is indexed; retried briefly). The REST
    /// lookups go through `RoomAuthorLookups`: a few at a time, one per outpoint however many
    /// blocks ask for it, and none past a backlog a spammer could build (audit #23).
    private nonisolated static func inputAddress(txId: String, index: UInt32, hrp: String) async -> String? {
        if let script = RecentOutputScripts.shared.script(txId: txId, index: index),
           let data = CryptoUtils.hexToData(script) {
            return KaspaAddress.address(fromScriptPublicKey: data, hrp: hrp)
        }
        return await RoomAuthorLookups.shared.address(txId: txId, index: index, hrp: hrp)
    }

    /// The REST half of `inputAddress`, for `RoomAuthorLookups` to run.
    fileprivate nonisolated static func restInputAddress(txId: String, index: UInt32, hrp: String) async -> String? {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=true&resolve_previous_outpoints=no") else { return nil }
        // Its own timeout: `data(from:)` waits the default 60 s, and every block runs one of
        // these per room message at once, so a stalled REST server held each block's checks
        // for about 3 minutes and they piled up.
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outputs = j["outputs"] as? [[String: Any]] else { continue }
            let output = outputs.first { ($0["index"] as? NSNumber)?.uint32Value == index } ?? (Int(index) < outputs.count ? outputs[Int(index)] : nil)
            if let address = output?["script_public_key_address"] as? String { return address }
            if let script = output?["script_public_key"] as? String, let data = CryptoUtils.hexToData(script) {
                return KaspaAddress.address(fromScriptPublicKey: data, hrp: hrp)
            }
        }
        return nil
    }

    private func startScanning() {
        if blockNotificationHandlerId == nil {
            blockNotificationHandlerId = NodePoolService.shared.addBlockHandler { [weak self] block in
                Self.blockScanQueue.async {
                    let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
                    let hits = Self.extractPublicChatHits(block, hrp: hrp)
                    guard !hits.isEmpty else { return }
                    Task { @MainActor in
                        // Rooms we listen to and senders not hidden first: checking an author can
                        // cost REST lookups, and every room on the network posts.
                        guard let wanted = self?.hitsWorthVerifying(hits), !wanted.isEmpty else { return }
                        // only posts whose input 0 spends from the posting address (XP-012);
                        // verifiedAuthors is nonisolated, so the lookups run off the main actor
                        let verified = await Self.verifiedAuthors(wanted, hrp: hrp)
                        guard !verified.isEmpty else { return }
                        await self?.processPublicChatHits(verified)
                    }
                }
            }
        }
        Task { await NodePoolService.shared.subscribeBlockAdded(client: "broadcast-scan") }
    }

    private func stopScanning() {
        Task { await NodePoolService.shared.unsubscribeBlockAdded(client: "broadcast-scan") }
        // A connection that already registered for blocks keeps pushing them until it
        // reconnects (see NodePoolService.unsubscribeBlockAdded), and other clients (groups, the
        // inbox scan) can still want them. The handler goes, so no room's scan parses them.
        if let id = blockNotificationHandlerId {
            BlockScanRegistry.shared.remove(id)
            blockNotificationHandlerId = nil
        }
    }

    // MARK: - Block scanning

    /// The scan's hits in rooms the stream is on for, from senders not hidden there. Applied
    /// again in `processPublicChatHits`, since either can change while authors are checked.
    private func hitsWorthVerifying(_ hits: [BlockScanHit]) -> [BlockScanHit] {
        let wanted = streamChannels
        guard !wanted.isEmpty else { return [] }
        let hidden = store.hiddenSendersByChannel()
        return hits.filter { hit in
            wanted.contains(hit.channel)
                && !hidden.global.contains(hit.senderAddress)
                && hidden.perChannel[hit.channel]?.contains(hit.senderAddress) != true
        }
    }

    /// Main-actor tail of the block scan: runs ONLY when a block actually contained public chat
    /// payloads (rare). State filtering + store insert + UI refresh. The message rows go in as
    /// one background batch: a reconnect burst used to do one synchronous main-thread save per
    /// row.
    private func processPublicChatHits(_ hits: [BlockScanHit]) async {
        let wanted = wantedChannels
        guard !wanted.isEmpty else { return }
        let hidden = store.hiddenSendersByChannel()
        var touchedChannels = Set<String>()
        var reactionChannels = Set<String>()
        var editChannels = Set<String>()
        var messageHits: [BlockScanHit] = []
        var editHits: [(hit: BlockScanHit, edit: MessageEditContent)] = []

        for hit in hits {
            guard wanted.contains(hit.channel) else { continue }
            guard !hidden.global.contains(hit.senderAddress),
                  hidden.perChannel[hit.channel]?.contains(hit.senderAddress) != true else { continue }
            // Reactions are never shown as their own bubble (or notified) - just attached to the
            // message they target - so intercept and route to the reactions index before this
            // ever becomes a message row. Our own outgoing reactions already applied their local
            // update at send time (sendPublicChatReaction); newest-blockTime-wins dedupes the echo.
            if let edit = MessageEditCodec.parse(hit.content) {
                editHits.append((hit, edit))
                continue
            }
            if let reaction = MessageReactionCodec.parse(hit.content) {
                let changed = store.applyIncomingReaction(
                    targetTxId: reaction.targetTxId,
                    channel: hit.channel,
                    reactorAddress: hit.senderAddress,
                    emoji: reaction.action == "remove" ? nil : reaction.emoji,
                    reactionTxId: hit.txId,
                    blockTime: hit.blockTime
                )
                if changed { reactionChannels.insert(hit.channel) }
                continue
            }
            messageHits.append(hit)
        }

        if !messageHits.isEmpty {
            let inserted = await store.insertMessages(messageHits.map {
                (id: $0.txId, channel: $0.channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime)
            })
            for hit in messageHits {
                // Only a row still on this phone's clock, or given up on. Any other row already
                // has a chain time: a transaction can sit in several parallel blocks with
                // different times, and the indexer's is the one every phone ends up with.
                let takesStreamTime = Self.serviceChannels.contains(hit.channel)
                    && !inserted.contains(hit.txId)
                    && (localStampSentAt[hit.txId] != nil || store.deliveryStatus(ofMessage: hit.txId) == .failed)
                if Self.serviceChannels.contains(hit.channel) { confirmLocalStamp(hit.txId) }
                if inserted.contains(hit.txId) {
                    touchedChannels.insert(hit.channel)
                    postInAppBanner(channel: hit.channel, senderAddress: hit.senderAddress, content: hit.content, txId: hit.txId, blockTime: hit.blockTime)
                } else if takesStreamTime,
                          !wasApplied(Self.indexerTimedKey(hit.txId), channel: hit.channel),
                          store.updateBlockTime(id: hit.txId, blockTime: hit.blockTime) {
                    // Our own arena row, stamped with this phone's clock when it was submitted:
                    // the block's time is what every other phone sees, so take it (the reducer
                    // orders joins and runs the clocks by it).
                    droppedServiceRows.remove(hit.txId)
                    touchedChannels.insert(hit.channel)
                }
            }
        }

        // After the batch's messages are in: an edit can arrive in the same batch as its target.
        for (hit, edit) in editHits {
            if applyIncomingEdit(edit, channel: hit.channel, senderAddress: hit.senderAddress, editTxId: hit.txId, blockTime: hit.blockTime) {
                editChannels.insert(hit.channel)
            }
        }

        for channel in reactionChannels {
            loadReactions(for: channel)
        }
        for channel in editChannels {
            loadEdits(for: channel)
        }

        guard !touchedChannels.isEmpty else { return }
        for channel in touchedChannels {
            loadMessages(for: channel)
        }
        await store.pruneExpiredMessages()
    }

    // MARK: - The arena from the REST API

    private struct ChainArenaRow {
        let txId: String
        let sender: String
        let content: String
        let blockTime: Int64
    }

    private nonisolated static let chainPageSize = 100
    private nonisolated static let chainMaxPages = 20

    /// One room's messages from its known players, read by address from the Kaspa REST API, for
    /// while the indexer is down. A channel has no address of its own, so this can only fill in a
    /// room whose players this phone already knows; it can't find new rooms or new joiners, and
    /// the arena's history can't be rebuilt this way. Only rows the store doesn't hold go in, so
    /// a time the indexer gave is left alone. True when every player's address answered.
    func readArenaFromChain(tournamentId: String, players: [String], since: Int64) async -> Bool {
        var found: [ChainArenaRow] = []
        var complete = true
        for address in players {
            guard let rows = await Self.chainArenaRows(address: address, tournamentId: tournamentId, since: since) else {
                complete = false
                continue
            }
            found.append(contentsOf: rows)
        }
        await mergeChainArenaRows(found)
        return complete
    }

    private func mergeChainArenaRows(_ found: [ChainArenaRow]) async {
        guard !found.isEmpty else { return }
        let arena = ChessTournamentCodec.arenaChannel
        let hidden = store.hiddenSenderAddresses(forChannel: arena)
        let rows = found
            .filter { !hidden.contains($0.sender) }
            .map { (id: $0.txId, channel: arena, senderAddress: $0.sender, content: $0.content, blockTime: $0.blockTime) }
        var changed = !(await store.insertMessages(rows)).isEmpty
        // Our own rows still on this phone's clock, or given up on, take the chain's time.
        for row in rows where localStampSentAt[row.id] != nil || droppedServiceRows.contains(row.id) {
            confirmLocalStamp(row.id)
            droppedServiceRows.remove(row.id)
            if store.updateBlockTime(id: row.id, blockTime: row.blockTime) { changed = true }
        }
        if changed { await reloadMessagesNow(for: arena) }
    }

    /// `address`'s accepted posts to the room since `since`, newest pages first until they're
    /// older than that. The author rule is the block scan's (XP-012): input 0 spends from the
    /// address output 0 pays. Nil when the REST API didn't answer.
    private nonisolated static func chainArenaRows(address: String, tournamentId: String, since: Int64) async -> [ChainArenaRow]? {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let me = address.lowercased()
        var found: [ChainArenaRow] = []
        for page in 0..<chainMaxPages {
            guard let url = URL(string: "\(root)/addresses/\(me)/full-transactions?limit=\(chainPageSize)&offset=\(page * chainPageSize)&resolve_previous_outpoints=light&fields=transaction_id,is_accepted,payload,inputs,outputs,block_time") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            var reachedSince = false
            for row in rows {
                guard let blockTime = chainNumber(row["block_time"]) else { continue }
                if blockTime < since { reachedSince = true; continue }
                if let parsed = chainArenaRow(row, address: address, me: me, blockTime: blockTime),
                   ChessTournamentCodec.decode(parsed.content)?.t == tournamentId {
                    found.append(parsed)
                }
            }
            if rows.count < chainPageSize || reachedSince { break }
        }
        return found
    }

    private nonisolated static func chainNumber(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private nonisolated static func chainArenaRow(_ row: [String: Any], address: String, me: String, blockTime: Int64) -> ChainArenaRow? {
        func first(_ key: String) -> [String: Any]? {
            ((row[key] as? [[String: Any]]) ?? []).min { (chainNumber($0["index"]) ?? 0) < (chainNumber($1["index"]) ?? 0) }
        }
        guard (row["is_accepted"] as? Bool) == true, let txId = row["transaction_id"] as? String,
              (first("inputs")?["previous_outpoint_address"] as? String)?.lowercased() == me,
              (first("outputs")?["script_public_key_address"] as? String)?.lowercased() == me,
              let payloadHex = row["payload"] as? String,
              let payload = CryptoUtils.hexToData(payloadHex),
              let text = String(data: payload, encoding: .utf8),
              let parsed = KasiaTransactionBuilder.parsePublicChatPayload(text),
              PublicChatChannelName.normalize(parsed.channel) == ChessTournamentCodec.arenaChannel else { return nil }
        return ChainArenaRow(txId: txId, sender: address, content: parsed.content, blockTime: blockTime)
    }
}


// MARK: - Room summaries for the Chats list

/// What the Chats list shows of one public room: its newest message (sender, a one-line preview,
/// time) and its unread count. Equatable, so a row only redraws when one of these changes.
struct PublicChatRoomSummary: Equatable, Identifiable {
    let channel: PublicChatChannel
    let lastMessageId: String?
    let lastSender: String?
    /// The newest message's preview, link-safe and with bidi controls stripped.
    let lastPreview: String?
    let lastBlockTime: Int64?
    let unreadCount: Int

    var id: String { channel.channelName }
    var channelName: String { channel.channelName }
    /// The room name as a list shows it: bidi controls stripped (audit #22).
    var displayName: String { KaPostsMarkdown.strippingBidiControls(channel.channelName) }
    /// Where the room sits among the chats; a room nobody has written in goes to the bottom.
    var activity: Date {
        lastBlockTime.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .distantPast
    }
}

/// The public rooms as the Chats list draws them (audit #29): worked out again after the rooms
/// change, published only when a summary does. The list and its rows observe this, not
/// `PublicChatService`, which publishes for every room event, the chess arena's moves (every
/// 2 s in a game), reactions, edits and indexer bookkeeping included.
@MainActor
final class PublicChatRoomSummaries: ObservableObject {
    static let shared = PublicChatRoomSummaries()

    /// The rooms the Chats list shows (`PublicChatService.listedChannels`), in its order.
    @Published private(set) var rooms: [PublicChatRoomSummary] = []
    /// `PublicChatService.pendingPublicChatNavigation`, mirrored, so the Chats list can follow
    /// a tapped room notification without observing the whole service.
    @Published private(set) var pendingRoom: String?

    private var cancellables = Set<AnyCancellable>()
    /// Each room's last preview, by message id and content, so it's worked out once per message.
    private var previewMemo: [String: (id: String, content: String, preview: String)] = [:]

    private init() {
        let service = PublicChatService.shared
        // objectWillChange fires before the change lands: the debounce reads after it.
        service.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        service.$pendingPublicChatNavigation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, self.pendingRoom != value else { return }
                self.pendingRoom = value
            }
            .store(in: &cancellables)
        recompute()
    }

    /// Works the summaries out now. Also called straight after a change the user made (Mark as
    /// Read, Mute, Delete), so the row answers without waiting for the debounce.
    func recompute() {
        let service = PublicChatService.shared
        let next = service.listedChannels.map { channel -> PublicChatRoomSummary in
            let name = channel.channelName
            let last = service.messages(forChannel: name).last
            return PublicChatRoomSummary(
                channel: channel,
                lastMessageId: last?.id,
                lastSender: last?.senderAddress,
                lastPreview: last.map { preview(of: $0, in: name) },
                lastBlockTime: last?.blockTime,
                unreadCount: service.unreadCount(forChannel: name)
            )
        }
        let listed = Set(next.map(\.channelName))
        if previewMemo.keys.contains(where: { !listed.contains($0) }) {
            previewMemo = previewMemo.filter { listed.contains($0.key) }
        }
        if next != rooms { rooms = next }
    }

    private func preview(of message: PublicChatMessage, in channel: String) -> String {
        if let memo = previewMemo[channel], memo.id == message.id, memo.content == message.content {
            return memo.preview
        }
        let preview = KaPostsMarkdown.strippingBidiControls(
            LinkSafePreview.apply(to: MessageReplyCodec.previewText(for: message.content))
        )
        previewMemo[channel] = (message.id, message.content, preview)
        return preview
    }
}

// MARK: - Public Chat indexer client

/// Minimal read client for the KaChat-owned public chat indexer (see PUBLIC_CHATS_INDEXER.md - the
/// server tracks #kaspa and #kachat-bugs history so clients aren't limited to what they catch
/// live). The API contract this client expects is the source of truth for the server build.
enum PublicChatIndexerClient {
    struct IndexedPublicChat: Decodable {
        let txId: String
        let channel: String?
        let senderAddress: String
        let content: String
        let blockTime: Int64
    }

    private struct HistoryResponse: Decodable {
        let messages: [IndexedPublicChat]
        let hasMore: Bool?
    }

    enum ClientError: LocalizedError {
        case badURL
        case badResponse(Int)
        /// The answer was bigger than any real page (`maxResponseBytes`): not read.
        case oversizedResponse(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid public chats indexer URL"
            case .badResponse(let code): return "Public chats indexer returned HTTP \(code)"
            case .oversizedResponse(let bytes): return "Public chats indexer sent \(bytes) bytes, more than a page can hold"
            }
        }
    }

    /// The most a history page may weigh. A page is at most 200 rows and a room message's
    /// payload is under 100 KB (a transaction's mass limit), so a real page stays well under this.
    static let maxResponseBytes = 24 * 1024 * 1024
    /// More rows than any page is asked for: the rest of an answer is ignored.
    static let maxRowsPerPage = 500
    /// One row's content, in UTF-8 bytes: twice what a transaction's payload can carry.
    static let maxContentBytes = 200_000
    private static let hexDigits: Set<UInt8> = Set("0123456789abcdefABCDEF".utf8)

    /// An indexer row the app can believe the shape of (audit #19): a 64-hex txid, a valid
    /// address on this network, content within what a transaction can carry, a block time that
    /// isn't zero or far in the future, and, when the row names its room, the room asked for.
    /// The indexer's rows carry no signature or public key to check: who sent a row is the
    /// indexer's word (the block stream checks authors on chain, `verifiedAuthors`).
    static func isWellFormed(_ row: IndexedPublicChat, channel: String, addressPrefix: String, now: Int64) -> Bool {
        guard row.txId.utf8.count == 64, row.txId.utf8.allSatisfy({ hexDigits.contains($0) }) else { return false }
        guard row.senderAddress.hasPrefix(addressPrefix), Bech32.decode(row.senderAddress) != nil else { return false }
        let contentBytes = row.content.utf8.count
        guard contentBytes > 0, contentBytes <= maxContentBytes else { return false }
        // A day of clock skew either way is allowed; past that the time is nonsense.
        guard row.blockTime > 0, row.blockTime <= now + 24 * 3600 * 1000 else { return false }
        if let rowChannel = row.channel, !rowChannel.isEmpty,
           PublicChatChannelName.normalize(rowChannel) != channel { return false }
        return true
    }

    /// GET /get-public chats?channel=<name>&limit=<n>[&before=<blockTimeMs>]
    /// -> {"messages":[{txId, channel, senderAddress, content, blockTime}], "hasMore": Bool}
    /// blockTime is ms; results newest-first. Keeps the server's `hasMore` so callers can page
    /// older history with `before`.
    /// `isBackfill`: an older page paged in right after the newest page answered. Its failure
    /// says that page failed, not that the indexer is down (the next poll's newest page tells
    /// that), so it doesn't count toward an outage - a heavy page that kept timing out took the
    /// arena down and up again, re-paging it every time.
    static func fetchHistoryPage(
        baseURL: String,
        channel: String,
        limit: Int = 200,
        before: Int64? = nil,
        isBackfill: Bool = false
    ) async throws -> (messages: [IndexedPublicChat], hasMore: Bool) {
        guard PublicChatChannelName.normalize(channel) == ChessTournamentCodec.arenaChannel else {
            return try await requestHistoryPage(baseURL: baseURL, channel: channel, limit: limit, before: before)
        }
        do {
            let page = try await requestHistoryPage(baseURL: baseURL, channel: channel, limit: limit, before: before)
            await noteArenaResult(error: nil)
            return page
        } catch {
            if !isBackfill { await noteArenaResult(error: error) }
            throw error
        }
    }

    /// Whether the chess arena's indexer is answering. Every arena read reports here.
    static let arenaHealth = ArenaIndexerHealth()

    private enum Outcome { case answered, down, inconclusive }

    private static func outcome(of error: Error) -> Outcome {
        if error is CancellationError { return .inconclusive }
        if let urlError = error as? URLError {
            switch urlError.code {
            // the phone has no connection: that says nothing about the indexer
            case .cancelled, .notConnectedToInternet, .dataNotAllowed: return .inconclusive
            default: return .down
            }
        }
        // Any status that isn't a success, or a body that doesn't decode, gave no rows: to the
        // arena that's the same as no answer, and the REST API must take over.
        if error is ClientError || error is DecodingError { return .down }
        return .inconclusive
    }

    private static func noteArenaResult(error: Error?) async {
        switch error.map(outcome(of:)) ?? .answered {
        case .answered: _ = await arenaHealth.recordAnswer()
        case .down: _ = await arenaHealth.recordFailure()
        case .inconclusive: break
        }
        let down = await arenaHealth.isDown
        await MainActor.run { PublicChatService.shared.arenaHealthObserved(down: down) }
    }

    private static func requestHistoryPage(
        baseURL: String,
        channel: String,
        limit: Int,
        before: Int64?
    ) async throws -> (messages: [IndexedPublicChat], hasMore: Bool) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        var components = URLComponents(string: "\(trimmed)/get-broadcasts")
        var query = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let before {
            query.append(URLQueryItem(name: "before", value: String(before)))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw ClientError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.badResponse(http.statusCode)
        }
        // Too big to be a page (audit #19): not decoded at all.
        if response.expectedContentLength > Int64(maxResponseBytes) || data.count > maxResponseBytes {
            throw ClientError.oversizedResponse(max(data.count, Int(clamping: response.expectedContentLength)))
        }
        let decoded = try JSONDecoder().decode(HistoryResponse.self, from: data)
        // Rows with a field that can't be right are dropped, one by one.
        let wanted = PublicChatChannelName.normalize(channel)
        let addressPrefix = AppSettings.load().networkType == .mainnet ? "kaspa:" : "kaspatest:"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = decoded.messages.prefix(maxRowsPerPage).filter {
            isWellFormed($0, channel: wanted, addressPrefix: addressPrefix, now: now)
        }
        if rows.count < decoded.messages.count {
            AppLog.log("%@", "[PublicChat] Dropped \(decoded.messages.count - rows.count) malformed indexer row(s) for #\(wanted)")
        }
        // An indexer only stores the rooms it tracks: rows back mean it keeps this room's history.
        // Only the app-wide indexer's rows count: "tracked" also means the app-wide push service
        // sends the room's pushes (and its local banners and cellular stream are skipped), which
        // a room's own indexer says nothing about.
        if !rows.isEmpty, isAppWideIndexer(trimmed) {
            IndexerTrackedRooms.markServed(channel)
        }
        return (rows, decoded.hasMore ?? false)
    }

    /// Whether `base` is the app-wide public chat indexer (trailing slash and case aside).
    private static func isAppWideIndexer(_ base: String) -> Bool {
        func canonical(_ url: String) -> String {
            var value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        let appWide = canonical(AppSettings.load().publicChatIndexerURL)
        return !appWide.isEmpty && canonical(base) == appWide
    }

    private struct TrackedChannelsResponse: Decodable {
        let channels: [String]
    }

    /// GET /broadcast-channels -> {"channels": [...]}: the rooms this indexer tracks now (set on
    /// the indexer's dashboard). nil when the indexer predates the endpoint (404) or can't be reached.
    static func fetchTrackedChannels(baseURL: String) async -> [String]? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty, let url = URL(string: "\(trimmed)/broadcast-channels") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= 256 * 1024,
              let decoded = try? JSONDecoder().decode(TrackedChannelsResponse.self, from: data) else { return nil }
        // Only names a room could have, and no more of them than an indexer could track.
        return Array(decoded.channels
            .filter { PublicChatChannelName.isValid(PublicChatChannelName.normalize($0)) }
            .prefix(1_000))
    }
}

extension Notification.Name {
    /// The chess arena's indexer stopped answering or came back; `userInfo["down"]` says which.
    /// Its own name: `.indexerAvailabilityChanged` is the message indexer's, which chats and
    /// groups follow.
    static let arenaIndexerAvailabilityChanged = Notification.Name("arenaIndexerAvailabilityChanged")
}

/// Whether the chess arena's indexer is answering (like `KasiaAPIClient`'s message-indexer health). It only counts as down after several
/// failures in a row, so one timeout never moves the arena off it; failures under 5 s apart (the
/// fast poll, the room's poll and a repage failing together) count as one, as the .kachat
/// registry counts them. While it's down, one request a minute is let through to find out when
/// it's back, and it is back after two answers in a row (the second asked for right away) or one
/// answer after a long outage - so one lucky answer from a flaky indexer doesn't bring it back,
/// and page the arena in again, only to fail the next minute.
actor ArenaIndexerHealth {
    private var downSince: Date?
    private var failuresInARow = 0
    private var lastFailureAt = Date.distantPast
    private var lastCountedFailureAt = Date.distantPast
    private var retryAt = Date.distantPast
    private var answersInARow = 0
    private static let failuresToGoDown = 3
    /// Failures further apart than this aren't a run.
    private static let failureWindow: TimeInterval = 120
    /// Failures closer together than this are one.
    private static let failureMergeWindow: TimeInterval = 5
    private static let retryInterval: TimeInterval = 60
    private static let answersToComeBack = 2
    /// Down at least this long, one answer is enough.
    private static let longOutage: TimeInterval = 5 * 60

    var isDown: Bool { downSince != nil }

    /// The next read goes through, down or not (a chess screen just opened).
    func allowProbeNow() { retryAt = .distantPast }

    func reset() {
        downSince = nil
        failuresInARow = 0
        answersInARow = 0
        lastCountedFailureAt = .distantPast
        retryAt = .distantPast
    }

    func shouldSkipIndexer() -> Bool {
        guard downSince != nil else { return false }
        let now = Date()
        // moved here rather than a "probing" flag, which could stick if the caller never asks
        guard now >= retryAt else { return true }
        retryAt = now.addingTimeInterval(Self.retryInterval)
        return false
    }

    /// True when this is the moment it went down.
    func recordFailure() -> Bool {
        let now = Date()
        answersInARow = 0
        if now.timeIntervalSince(lastFailureAt) > Self.failureWindow { failuresInARow = 0 }
        lastFailureAt = now
        // Part of a failure counted under 5 s ago: the same one.
        guard now.timeIntervalSince(lastCountedFailureAt) >= Self.failureMergeWindow else { return false }
        lastCountedFailureAt = now
        failuresInARow += 1
        guard downSince == nil, failuresInARow >= Self.failuresToGoDown else { return false }
        downSince = now
        retryAt = now.addingTimeInterval(Self.retryInterval)
        return true
    }

    /// True when this is the moment it came back.
    func recordAnswer() -> Bool {
        failuresInARow = 0
        guard let since = downSince else {
            answersInARow = 0
            return false
        }
        answersInARow += 1
        guard answersInARow >= Self.answersToComeBack || Date().timeIntervalSince(since) >= Self.longOutage else {
            // One answer: the next read goes through at once to confirm it.
            retryAt = .distantPast
            return false
        }
        downSince = nil
        answersInARow = 0
        return true
    }
}

/// The room author check's REST lookups (`PublicChatService.inputAddress`), capped and deduped
/// (audit #23): every block could start one lookup per room message at once, so a spammer posting
/// many messages a block could get the phone rate-limited by the REST API. At most
/// `maxConcurrent` run at a time; an outpoint already being looked up is waited on, not asked
/// again; recent answers are kept; and past `maxPending` lookups the rest are refused (their
/// posts are dropped from the stream, as any post whose author can't be checked is; the
/// indexer still serves them).
private actor RoomAuthorLookups {
    static let shared = RoomAuthorLookups()

    private static let maxConcurrent = 4
    private static let maxPending = 64
    private static let resolvedCap = 512

    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var resolved: [String: String] = [:]

    func address(txId: String, index: UInt32, hrp: String) async -> String? {
        let key = "\(txId):\(index)"
        if let known = resolved[key] { return known }
        if let pending = inFlight[key] { return await pending.value }
        guard inFlight.count < Self.maxPending else {
            AppLog.log("[PublicChat] Author check backlog full: dropped a lookup")
            return nil
        }
        let task = Task<String?, Never> {
            await self.acquireSlot()
            let found = await PublicChatService.restInputAddress(txId: txId, index: index, hrp: hrp)
            await self.releaseSlot()
            return found
        }
        inFlight[key] = task
        let found = await task.value
        inFlight[key] = nil
        if let found {
            if resolved.count >= Self.resolvedCap { resolved.removeAll(keepingCapacity: true) }
            resolved[key] = found
        }
        return found
    }

    private func acquireSlot() async {
        if running < Self.maxConcurrent {
            running += 1
            return
        }
        // The slot is handed over by `releaseSlot`, so `running` stays as it is.
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The rooms an indexer tracks beyond the curated ones, so a room the operator adds on the
/// indexer gets everything a default room gets - its 30 days of history kept on the phone,
/// remote push, the cellular savings - with no app update. Learned two ways:
/// - **Reported**: the app-wide indexer's `GET /broadcast-channels` (replaced on every answer).
/// - **Served**: a room whose `/get-broadcasts` on the app-wide indexer returned rows - an indexer
///   stores only rooms it tracks. Counts for 30 days after the last rows came back (the indexer's
///   own window), so this also works with an indexer that predates the endpoint. A room's own
///   indexer doesn't count: the app-wide push service knows nothing of what it serves.
/// Per network, persisted. Thread-safe: the store's background prune reads it.
enum IndexerTrackedRooms {
    /// Posted (main queue) when the set changes, so push registration and scanning follow.
    static let didChange = Notification.Name("IndexerTrackedRoomsDidChange")
    private static let servedWindow: TimeInterval = 30 * 24 * 3600

    private static let lock = NSLock()
    private static var loadedSuffix: String?
    private static var reported: Set<String> = []
    private static var served: [String: TimeInterval] = [:]

    private static var suffix: String {
        AppSettings.load().networkType == .mainnet ? "" : ".testnet"
    }
    private static func reportedKey(_ suffix: String) -> String { "kachat_indexer_tracked_rooms.reported" + suffix }
    private static func servedKey(_ suffix: String) -> String { "kachat_indexer_tracked_rooms.served" + suffix }

    /// Call with `lock` held: loads this network's sets once (again after a network switch).
    private static func loadIfNeeded() {
        let current = suffix
        guard loadedSuffix != current else { return }
        loadedSuffix = current
        reported = Set(UserDefaults.standard.stringArray(forKey: reportedKey(current)) ?? [])
        served = (UserDefaults.standard.dictionary(forKey: servedKey(current)) as? [String: TimeInterval]) ?? [:]
    }

    static func contains(_ normalized: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if reported.contains(normalized) { return true }
        guard let at = served[normalized] else { return false }
        return Date().timeIntervalSince1970 - at < servedWindow
    }

    static func all() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let now = Date().timeIntervalSince1970
        return reported.union(served.filter { now - $0.value < servedWindow }.keys)
    }

    /// The app-wide indexer's list, as `/broadcast-channels` answered.
    static func setReported(_ channels: [String]) {
        let names = Set(channels.map(PublicChatChannelName.normalize).filter { !$0.isEmpty })
        lock.lock()
        loadIfNeeded()
        let changed = names != reported
        if changed {
            reported = names
            UserDefaults.standard.set(Array(names).sorted(), forKey: reportedKey(loadedSuffix ?? ""))
        }
        lock.unlock()
        if changed { postChange() }
    }

    /// `channel`'s indexer just returned rows for it.
    static func markServed(_ channel: String) {
        let name = PublicChatChannelName.normalize(channel)
        guard !name.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        lock.lock()
        loadIfNeeded()
        let previous = served[name]
        let wasTracked = reported.contains(name) || previous.map { now - $0 < servedWindow } ?? false
        // written at most once an hour per room: every 8 s poll lands here
        let stale = previous.map { now - $0 > 3600 } ?? true
        if stale {
            served[name] = now
            UserDefaults.standard.set(served, forKey: servedKey(loadedSuffix ?? ""))
        }
        lock.unlock()
        if !wasTracked { postChange() }
    }

    private static func postChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}
