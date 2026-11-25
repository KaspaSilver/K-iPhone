import Foundation
import UIKit
import UserNotifications

/// Own-address receive notifications: alerts the user when any of the wallet's NON-chatting
/// addresses - spending-chain addresses (Manage Addresses), and Cold Storage accounts' addresses
/// where that account's Receive Notifications are on - receives Kaspa from an external source. These are wallet events, never chat:
/// no conversation is created, no bubble appears - just a local notification, plus a
/// persisted per-address balance baseline update so the catch-up path and the open
/// Manage Addresses screen stay in sync.
///
/// Self-send filtering is the critical part - change from own payments, consolidations,
/// KNS inscription change and pool payments between own addresses
/// must NOT notify. Two layers:
///   1. Fast path: the same `utxosChanged` batch carries `removed` entries for every watched
///      address the tx spends FROM - any own address there means we funded the tx ourselves.
///      Because ALL own addresses (chatting + spending + cold + reserved pool) are in the
///      watched set, virtually every self-send is caught here without a network call.
///   2. REST resolve (the classifier's own endpoint, `resolve_previous_outpoints=light`):
///      fetch the tx and check whether ANY input address is one of ours.
/// Notifications are deduped per txId (persisted, capped) and multiple outputs of one tx to
/// our addresses notify once with the summed amount.
///
/// Catch-up (app foregrounded after being away) diffs live balances against the persisted
/// baseline; increases are attributed via each address's recent transactions with the same
/// inputs-not-ours filter, falling back to a neutral "Balance increased" notification when
/// resolution fails. First run just seeds the baseline silently so enabling the feature (or
/// importing a wallet) never blasts notifications for historical funds.
///
/// Gated by Settings > Notifications > "Address Activity" (default ON) plus the master
/// notification mode. The gates decide only what is announced: baselines, handled marks and the
/// chatting floor follow every own address whatever they say, so turning a switch back on never
/// announces what came while it was off (audit 2026-11-24 notifications).
///
/// Addresses currently reserved-and-offered as fresh payment-pool receive addresses are
/// excluded from notification (payments to those DO create chat bubbles via the
/// payment_notice envelope - notifying here too would double up), but still count as "ours"
/// for the self-send input check.
@MainActor
final class AddressActivityNotifier: ObservableObject {
    static let shared = AddressActivityNotifier()
    private init() {
        // A subscription restored after a failover: what arrived meanwhile is found by the
        // balance diff (debounced), never by replaying the UTXO set as new (IOS-070).
        NotificationCenter.default.addObserver(forName: .rpcSubscriptionsRestored, object: nil, queue: .main) { _ in
            Task { @MainActor in await AddressActivityNotifier.shared.runCatchUpIfNeeded() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AddressActivityNotifier.shared.activeSince = Date() }
        }
    }

    /// When the app last became active (or this notifier started, on a cold launch). A receive in
    /// a block before it came while K was away: for an address the push service watches, its
    /// `address_activity` push was the notice, and the catch-up only lists it in the bell
    /// ("In the background and when closed, pushes alone"). The push has no mutable-content, so
    /// the extension never records it, and once it's swiped away nothing on the phone remembers
    /// it (audit 2026-11-24 notifications).
    private var activeSince = Date()

    static let notificationThreadIdentifier = "address-activity"

    // MARK: - Cached own-address sets

    private var cachedWalletAddress: String?
    private var cachedNetworkKey: String = ""
    private var cachedSpendingMaxIndex: Int = -1
    private var spendingAddressSet: Set<String> = []

    /// Cold Storage (watch-only kpub accounts, `ColdStorageManager`). Every derived address of
    /// every account counts as ours for the self-send check; those of accounts with Receive
    /// Notifications on (`ColdStorageAccount.notifyOnReceive`) are watched and notify, whatever
    /// the spending switch says (audit 2026-11-21 #5). Derived off the main thread
    /// (`ColdStorageAddressCache`), so the sets fill in a moment after the accounts change.
    private var coldFingerprint = ""
    private var coldOwnSet: Set<String> = []
    private var coldNotifySet: Set<String> = []
    /// The account each cold address belongs to, for the notification's wording.
    private var coldAccountLabels: [String: String] = [:]
    private var coldDeriveTask: Task<Void, Never>?
    /// Each account's Receive Notifications as last seen, to tell a switch turned on from an
    /// account loading. Turned on, its addresses' baselines are taken as they stand: they aren't
    /// in the UTXO subscription while off, so a receive since the last catch-up would otherwise be
    /// announced late (audit 2026-11-24 notifications).
    private var coldNotifyFlags: [UUID: Bool] = [:]
    /// Accounts switched on whose addresses aren't absorbed yet (kept across a cancelled derive).
    private var coldAbsorbPending: Set<UUID> = []

    /// Receive notifications for the wallet's spending addresses (Manage Addresses), per
    /// wallet - Default on.
    @Published var spendingReceiveNotificationsEnabled: Bool = true {
        didSet {
            guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
            UserDefaults.standard.set(spendingReceiveNotificationsEnabled, forKey: Self.spendingNotifyKey(wallet: wallet))
            if oldValue != spendingReceiveNotificationsEnabled { Self.pushAddressesMayHaveChanged() }
        }
    }
    private var spendingNotifyLoadedForWallet: String?
    private static func spendingNotifyKey(wallet: String) -> String {
        "kachat_spending_receive_notify_\(wallet.replacingOccurrences(of: ":", with: "_"))"
    }

    /// Loads the spending switch for the current wallet - call when a screen that shows it appears.
    func reloadSpendingSwitchForCurrentWallet() {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
        guard spendingNotifyLoadedForWallet != wallet else { return }
        spendingNotifyLoadedForWallet = wallet
        let stored = UserDefaults.standard.object(forKey: Self.spendingNotifyKey(wallet: wallet)) as? Bool
        spendingReceiveNotificationsEnabled = stored ?? true
    }

    // MARK: - Per-tx dedupe / in-flight tracking

    /// TxIds already handled (notified OR deliberately suppressed as self-sends) - persisted
    /// per wallet so reopening the app can't re-notify what the live path already covered.
    private var handledTxIds: Set<String> = []
    private var handledTxIdOrder: [String] = []
    private var handledLoadedForWallet: String?
    private static let handledTxIdCap = 500

    private var inFlightTxIds: Set<String> = []
    private var lastCatchUpAt: Date?
    private var lastCatchUpWallet: String?

    // MARK: - Public surface

    /// Every address this feature wants in the UTXO subscription watched set: all revealed
    /// spending-chain addresses (0...max index). Derivation results are cached and only recomputed when the wallet,
    /// the spending max index or the network changes - the first
    /// spending derivation per wallet does one seed decrypt + PBKDF2, same cost Manage
    /// Addresses already pays on open.
    func watchedOwnAddresses() -> Set<String> {
        refreshCaches()
        return spendingAddressSet.union(coldNotifySet)
    }

    /// Cold Storage's accounts changed (added, removed, renamed, a switch flipped, more addresses,
    /// another wallet): the cold sets are worked out again, and the watched set follows.
    /// Only the cold part, and only once `refreshCaches` has run for this wallet: called while an
    /// account loads, a full refresh could cache its spending set before its keys are ready.
    func coldStorageAccountsChanged() {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress,
              cachedWalletAddress == wallet else { return }
        refreshColdCaches(wallet: wallet, network: AppSettings.load().networkType, walletChanged: false)
    }

    /// UserInfo key carrying the involved own addresses on a `.ownAddressUtxoActivity` post.
    static let utxoActivityAddressesKey = "addresses"

    /// Always-post internal event, deliberately separate from the user-notification decision:
    /// posts `.ownAddressUtxoActivity` (with the involved own addresses) whenever a UTXO batch
    /// touches any watched spending/cold address - including SELF-SEND change, which the
    /// notification paths suppress. `handleLiveUtxoAdditions`' fast path handles self-sends
    /// with no `.ownAddressActivity` post at all, and the whole notifier is gated by the
    /// Address Activity notification setting - so UI that must track its own change landing
    /// (the payment composer's Available pill, the address list screens) listens to THIS
    /// event instead. Not gated by `featureEnabled`.
    func postUtxoActivityEvent(
        parsed: ParsedUtxosChangedNotification,
        removedByTxId: [String: Set<String>]
    ) {
        let watched = watchedOwnAddresses()
        guard !watched.isEmpty else { return }
        var involved: Set<String> = []
        for entry in parsed.added {
            if let address = entry.address, watched.contains(address) {
                involved.insert(address)
            }
        }
        for removed in removedByTxId.values {
            involved.formUnion(removed.intersection(watched))
        }
        guard !involved.isEmpty else { return }
        NotificationCenter.default.post(
            name: .ownAddressUtxoActivity,
            object: nil,
            userInfo: [Self.utxoActivityAddressesKey: Array(involved)]
        )
    }

    /// Live path, called from the UTXO classifier with the whole parsed batch. Collects
    /// outputs landing on own non-chatting addresses, dedupes per txId, applies the
    /// removed-set fast path, and schedules REST input resolution for the rest.
    func handleLiveUtxoAdditions(
        parsed: ParsedUtxosChangedNotification,
        removedByTxId: [String: Set<String>]
    ) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        refreshCaches()
        ensureHandledTxIdsLoaded(wallet: wallet.publicAddress)

        // Every own address is followed whatever the switches say (master, Address Activity, the
        // spending switch, a Cold Storage account's): a receive while one is off is marked handled
        // and folded into the baseline, just not announced. Following only the notifying ones
        // left their baselines behind, and switching back on announced everything that came
        // meanwhile in one burst (audit 2026-11-24 notifications).
        let ownAll = ownInputAddressSet(walletAddress: wallet.publicAddress)
        let notifiable = featureEnabled ? notifiableAddressSet(walletAddress: wallet.publicAddress) : []

        // Group outputs to our own addresses per tx so one tx paying several of our
        // addresses notifies once with the summed amount. Coinbase entries are skipped to
        // mirror the classifier (a miner pointed at a spending address would otherwise get
        // a notification per block; catch-up still reflects the balance growth).
        var hitsByTx: [String: [(address: String, amount: UInt64)]] = [:]
        for entry in parsed.added {
            guard !entry.isCoinbase, let address = entry.address else { continue }
            guard ownAll.contains(address) else { continue }
            hitsByTx[entry.transactionId, default: []].append((address, entry.amount))
        }
        guard !hitsByTx.isEmpty else { return }

        for (txId, hits) in hitsByTx {
            guard !handledTxIds.contains(txId), !inFlightTxIds.contains(txId) else { continue }
            let hitAddresses = Set(hits.map { $0.address })

            // Fast path: the tx spends FROM one of our watched addresses in this same
            // batch - self-send (change, consolidation, withdrawal...), suppress silently.
            if let removed = removedByTxId[txId], !removed.isDisjoint(with: ownAll) {
                markHandled(txId: txId, wallet: wallet.publicAddress)
                Task { await self.refreshBaselines(for: hitAddresses, wallet: wallet.publicAddress) }
                continue
            }

            // Only quiet addresses (or notifications off): seen, nothing to say.
            let loud = hits.filter { notifiable.contains($0.address) }
            guard !loud.isEmpty else {
                markHandled(txId: txId, wallet: wallet.publicAddress)
                Task { await self.refreshBaselines(for: hitAddresses, wallet: wallet.publicAddress) }
                continue
            }

            inFlightTxIds.insert(txId)
            Task { [weak self] in
                await self?.resolveAndNotifyLive(
                    txId: txId,
                    hits: loud,
                    tracked: hitAddresses,
                    ownAddresses: ownAll,
                    walletAddress: wallet.publicAddress
                )
            }
        }
    }

    /// Catch-up path, run on app foreground: diff live balances of every watched address
    /// against the persisted baseline and notify for increases not attributable to our own
    /// activity. Debounced; the first run for a wallet only seeds the baseline.
    func runCatchUpIfNeeded() async {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        if let last = lastCatchUpAt,
           lastCatchUpWallet == wallet.publicAddress,
           Date().timeIntervalSince(last) < 60 {
            return
        }
        lastCatchUpAt = Date()
        lastCatchUpWallet = wallet.publicAddress

        refreshCaches()
        ensureHandledTxIdsLoaded(wallet: wallet.publicAddress)
        // Every own address's baseline moves, the quiet ones' too, so switching a notice back on
        // never announces what came while it was off (audit 2026-11-24 notifications).
        let watched = ownInputAddressSet(walletAddress: wallet.publicAddress)
        let notifiable = featureEnabled ? notifiableAddressSet(walletAddress: wallet.publicAddress) : []

        // One batched balance fetch for the whole set. A network failure leaves baselines untouched so
        // nothing is silently marked as seen.
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(Array(watched)) else {
            return
        }
        // Signed out or switched while fetching: these balances aren't the current account's.
        guard WalletManager.shared.currentWallet?.publicAddress == wallet.publicAddress else { return }
        var currentBalances: [String: UInt64] = [:]
        for address in watched { currentBalances[address] = 0 }
        for utxo in utxos where currentBalances[utxo.address] != nil {
            currentBalances[utxo.address, default: 0] += utxo.amount
        }

        var baselines = loadBaselines(wallet: wallet.publicAddress)
        let isFirstRun = baselines.isEmpty
        var changed = false

        for (address, balance) in currentBalances {
            guard let previous = baselines[address] else {
                // Never-tracked address (feature install, newly revealed slot, fresh cold
                // import): seed silently - its history predates our tracking.
                baselines[address] = balance
                if address == wallet.publicAddress {
                    // the chatting address's receives count from now on
                    UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: chattingCatchUpFloorKey(address))
                }
                changed = true
                continue
            }
            if balance != previous { changed = true }
            if balance > previous, !isFirstRun, notifiable.contains(address) {
                await attributeAndNotifyIncrease(
                    address: address,
                    delta: balance - previous,
                    walletAddress: wallet.publicAddress
                )
                // Switched account meanwhile: stop, and save nothing more for this one now;
                // the next catch-up for it starts from the saved baseline.
                guard WalletManager.shared.currentWallet?.publicAddress == wallet.publicAddress else { return }
            }
            baselines[address] = balance
        }

        // Notifications off: the chatting address's floor moves to now as well, or its plain
        // transfers from meanwhile would be announced by the first catch-up after they're back on.
        if !notifiable.contains(wallet.publicAddress) {
            let floorKey = chattingCatchUpFloorKey(wallet.publicAddress)
            let nowMs = Date().timeIntervalSince1970 * 1000
            UserDefaults.standard.set(max(nowMs, UserDefaults.standard.double(forKey: floorKey)), forKey: floorKey)
        }

        if changed {
            saveBaselines(baselines, wallet: wallet.publicAddress)
            NotificationCenter.default.post(name: .ownAddressActivity, object: nil)
        }
    }

    // MARK: - Live resolution

    /// `hits` are the outputs to addresses that notify; `tracked` every own address the tx paid,
    /// quiet ones included, whose baselines move with it.
    private func resolveAndNotifyLive(
        txId: String,
        hits: [(address: String, amount: UInt64)],
        tracked: Set<String>,
        ownAddresses: Set<String>,
        walletAddress: String
    ) async {
        defer { inFlightTxIds.remove(txId) }

        var isSelfSend = false
        var hits = hits
        let fullTx = await ChatService.shared.fetchKaspaFullTransaction(
            txId: txId,
            retries: 4,
            delayNs: 1_500_000_000
        )
        // Those retries can run ~12s: if the account changed meanwhile, this receive isn't the
        // current account's news. Left unmarked, so the catch-up finds it on the way back.
        guard WalletManager.shared.currentWallet?.publicAddress == walletAddress else { return }
        // A transaction REST can't read stays quiet: the amounts in the node's batch are the
        // node's word alone. Left unmarked and its baseline untouched, so the catch-up still
        // finds the funds (attributed, or "Balance increased") from the chain.
        guard let fullTx else {
            AppLog.log("[AddressActivity] Couldn't read %@, leaving it to the catch-up", String(txId.prefix(12)))
            return
        }
        let inputAddresses = (fullTx.inputs ?? [])
            .compactMap { $0.previousOutpointAddress }
            .filter { !$0.isEmpty }
        if !inputAddresses.isEmpty {
            isSelfSend = inputAddresses.contains { ownAddresses.contains($0) }
        }
        // The amounts come from the transaction itself: its outputs to each of our addresses
        // the batch named.
        let hitAddresses = Set(hits.map(\.address))
        hits = hitAddresses.compactMap { address -> (address: String, amount: UInt64)? in
            let amount = fullTx.outputs
                .filter { $0.scriptPublicKeyAddress == address }
                .reduce(UInt64(0)) { $0 &+ $1.amount }
            return amount > 0 ? (address: address, amount: amount) : nil
        }
        // The chatting address notifies only for a plain transfer: a chat payment or a
        // handshake (a payload) is the chat's news.
        if !Self.isPlainTransfer(fullTx) {
            hits.removeAll { $0.address == walletAddress }
        }
        guard !hits.isEmpty else {
            markHandled(txId: txId, wallet: walletAddress)
            await refreshBaselines(for: tracked.union([walletAddress]), wallet: walletAddress)
            return
        }
        // A readable tx whose inputs REST couldn't name still notifies: the removed-set fast
        // path already suppressed every self-send whose inputs we watch (all of them), so it is
        // overwhelmingly external.

        guard !handledTxIds.contains(txId) else { return }
        markHandled(txId: txId, wallet: walletAddress)

        if !isSelfSend {
            postReceiveNotification(hits: hits, dedupeKey: txId)
            AppLog.log("[AddressActivity] Notified external receive %@ (%d output(s) to own addresses)",
                  String(txId.prefix(12)), hits.count)
        } else {
            AppLog.log("[AddressActivity] Suppressed self-send %@ after input resolve", String(txId.prefix(12)))
        }

        await refreshBaselines(for: tracked.union(hits.map { $0.address }), wallet: walletAddress)
        NotificationCenter.default.post(name: .ownAddressActivity, object: nil)
    }

    // MARK: - Catch-up attribution

    private func attributeAndNotifyIncrease(
        address: String,
        delta: UInt64,
        walletAddress: String
    ) async {
        let ownAll = ownInputAddressSet(walletAddress: walletAddress)
        let isChatting = address == walletAddress
        let recentTxs = await ChatService.shared.fetchFullTransactionsPaginated(
            for: address,
            pageSize: 10,
            maxTransactions: 10
        )
        guard WalletManager.shared.currentWallet?.publicAddress == walletAddress else { return }
        // the chatting address: only plain transfers newer than what was already looked at
        let floorKey = chattingCatchUpFloorKey(walletAddress)
        let floor = UInt64(max(0, UserDefaults.standard.double(forKey: floorKey)))
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if isChatting {
            // The floor never moves past a transaction this look skipped (audit 2026-11-25 C1):
            // a block reward not accepted yet, from the last 10 minutes, may still be, so the
            // next look sees it again. An empty answer (the read failed) moves it only on the
            // first look.
            let skippedTimes = recentTxs
                .filter { !$0.belongsInHistory }
                .compactMap(\.blockTime)
                .filter { $0 > floor && nowMs - min(nowMs, $0) < 10 * 60 * 1000 }
            var newest = recentTxs.compactMap(\.blockTime).max() ?? (floor == 0 ? nowMs : floor)
            if let held = skippedTimes.min() { newest = min(newest, held - 1) }
            UserDefaults.standard.set(Double(max(newest, floor)), forKey: floorKey)
            // the first look only sets where it starts
            if floor == 0 { return }
        }

        guard !recentTxs.isEmpty else {
            // Resolution failed entirely - still surface the funds, neutral wording (not for the
            // chatting address, whose balance moves with every chat payment too).
            if !isChatting { postBalanceIncreasedNotification(address: address, delta: delta) }
            return
        }

        // Receives the push service announced while K was away (see `activeSince`).
        let pushWatched = PushNotificationManager.shared.isRegistered
            && pushWatchOnlyAddresses().contains(address)
        let awayBeforeMs = UInt64(max(0, activeSince.timeIntervalSince1970 * 1000))

        var attributedAny = false
        for tx in recentTxs {
            // No block reward the network didn't accept. A block a miner finds is merged by many
            // later blocks, and each carries a coinbase paying them; only the chain block's is
            // accepted, so announcing them all pinged once per merging block for one block found
            // (owner, 2026-11-25). Any other transaction counts: a payment just sent is briefly
            // unaccepted too, and skipping it lost it for good (audit 2026-11-25 C1).
            guard tx.belongsInHistory else { continue }
            if isChatting {
                // An unknown block time is now (it's that new).
                guard Self.isPlainTransfer(tx), (tx.blockTime ?? nowMs) > floor else { continue }
            }
            let toAddress = tx.outputs
                .filter { $0.scriptPublicKeyAddress == address }
                .reduce(UInt64(0)) { $0 + $1.amount }
            guard toAddress > 0 else { continue }
            if handledTxIds.contains(tx.transactionId) {
                attributedAny = true
                continue
            }
            attributedAny = true
            let inputAddresses = (tx.inputs ?? [])
                .compactMap { $0.previousOutpointAddress }
                .filter { !$0.isEmpty }
            let isSelfSend = !inputAddresses.isEmpty && inputAddresses.contains { ownAll.contains($0) }
            markHandled(txId: tx.transactionId, wallet: walletAddress)
            if !isSelfSend {
                let blockTime = tx.blockTime ?? 0
                let pushWasTheNotice = pushWatched && blockTime > 0 && blockTime < awayBeforeMs
                // Only a receive from the last few minutes rings. The catch-up finds what came
                // while K was closed or this account was signed out (switching accounts announced
                // a week of receives as if they had just come): those go to the bell, quietly,
                // dated when they happened (owner, 2026-11-25).
                // An unknown block time counts as now, as `InAppBanner.isRecent` has it: it's
                // that new (audit 2026-11-25 C10).
                let isCurrent = InAppBanner.isRecent(blockTimeMs: Int64(blockTime))
                postReceiveNotification(
                    hits: [(address, toAddress)],
                    dedupeKey: tx.transactionId,
                    banner: isCurrent && !pushWasTheNotice,
                    happenedAtMs: blockTime > 0 ? Int64(blockTime) : nil
                )
            }
        }

        if !attributedAny, !isChatting {
            // Balance grew but none of the fetched recent txs pays this address (deep
            // history page or indexer lag) - neutral fallback rather than staying silent.
            postBalanceIncreasedNotification(address: address, delta: delta)
        }
    }

    // MARK: - Notification posting

    /// `banner` false: the bell only (the push already told them, `activeSince`, or it isn't
    /// from the last few minutes). `happenedAtMs` dates the bell's row (the block's time).
    private func postReceiveNotification(
        hits: [(address: String, amount: UInt64)],
        dedupeKey: String,
        banner: Bool = true,
        happenedAtMs: Int64? = nil
    ) {
        guard featureEnabled else { return }
        let total = hits.reduce(UInt64(0)) { $0 + $1.amount }
        guard total > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Received \(Self.formatKas(total)) \(KaspaUnit.symbol)"
        content.body = bodyDescribing(addresses: hits.map { $0.address })
        content.threadIdentifier = Self.notificationThreadIdentifier
        // The tap opens the history of the address that got the Kaspa - with several, the one
        // that got the most (the body names them all).
        var byAddress: [String: UInt64] = [:]
        for hit in hits { byAddress[hit.address, default: 0] += hit.amount }
        let opened = byAddress.max { $0.value < $1.value }?.key ?? hits.first?.address ?? ""
        var info: [String: Any] = ["kind": kindKey(for: opened)]
        // A Cold Storage address has no history sheet of its own here: the tap opens Wallet.
        let opensAddress = !opened.isEmpty && !isColdOnly(opened)
        if opensAddress { info["address"] = opened }
        content.userInfo = info
        applySoundPreference(to: content)

        // One notice per transaction: none when its Received push (`address_activity`, same
        // `tx_id`) already showed, and a push that comes later is only listed (`InAppBanner`).
        // `pushArrived` knows the pushes the app saw (`willPresent`, a tap: `notePushArrived`);
        // the extension doesn't run for them (no mutable-content).
        if banner, !InAppBanner.pushArrived(dedupeKey), InAppBanner.claim(dedupeKey) {
            let center = UNUserNotificationCenter.current()
            let request = UNNotificationRequest(identifier: "addr-activity-\(dedupeKey)", content: content, trigger: nil)
            let txId = dedupeKey.lowercased()
            center.getDeliveredNotifications { delivered in
                let pushShown = delivered.contains { ($0.request.content.userInfo["tx_id"] as? String)?.lowercased() == txId }
                if !pushShown { center.add(request) }
            }
        }
        // Also list it in the Profile notifications bell.
        Task { @MainActor in
            // the bell's entry opens the same address's history
            GlobalNotificationCenter.shared.record(id: "wallet-\(dedupeKey)", source: .wallet, title: content.title, body: content.body, timestamp: happenedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000), targetId: opensAddress ? opened : nil)
        }
    }

    private func postBalanceIncreasedNotification(address: String, delta: UInt64) {
        guard featureEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Balance increased by \(Self.formatKas(delta)) \(KaspaUnit.symbol)"
        content.body = describe(address: address)
        content.threadIdentifier = Self.notificationThreadIdentifier
        let opensAddress = !isColdOnly(address)
        var info: [String: Any] = ["kind": kindKey(for: address)]
        if opensAddress { info["address"] = address }
        content.userInfo = info
        applySoundPreference(to: content)

        // Bell only: this is the catch-up's fallback when it can't find the transaction, so
        // when the Kaspa came is unknown and it may be long ago (owner, 2026-11-25: no ping for
        // the past).
        let balId = "addr-activity-bal-\(address.suffix(12))-\(UUID().uuidString)"
        Task { @MainActor in
            GlobalNotificationCenter.shared.record(id: "wallet-\(balId)", source: .wallet, title: content.title, body: content.body, timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: opensAddress ? address : nil)
        }
    }

    private func applySoundPreference(to content: UNMutableNotificationContent) {
        let settings = AppSettings.load()
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil
        if !settings.incomingNotificationSoundEnabled,
           settings.incomingNotificationVibrationEnabled,
           UIApplication.shared.applicationState == .active {
            Haptics.impact(.light)
        }
    }

    private func bodyDescribing(addresses: [String]) -> String {
        let unique = Array(Set(addresses))
        if unique.count == 1, let only = unique.first {
            return describe(address: only)
        }
        return "\(unique.count) of your addresses"
    }

    private func describe(address: String) -> String {
        if address == WalletManager.shared.currentWallet?.publicAddress {
            return "Chatting address \(Self.shortAddress(address))"
        }
        if let label = coldAccountLabels[address], !spendingAddressSet.contains(address) {
            // e.g. "Cold storage address kaspa:qq... (Savings)"
            return String(format: AppLocalization.string("Cold storage address %@ (%@)"), Self.shortAddress(address), label)
        }
        return "Spending address \(Self.shortAddress(address))"
    }

    private func kindKey(for address: String) -> String {
        if address == WalletManager.shared.currentWallet?.publicAddress { return "chatting" }
        if isColdOnly(address) { return "cold" }
        return "spending"
    }

    /// A Cold Storage address that isn't also one of the wallet's own.
    /// Whether a tapped Received notice for this address opens its history (a Cold Storage
    /// address has none here: the tap opens Wallet).
    func opensHistory(for address: String) -> Bool {
        refreshCaches()
        return !address.isEmpty && !isColdOnly(address)
    }

    private func isColdOnly(_ address: String) -> Bool {
        coldOwnSet.contains(address) && !spendingAddressSet.contains(address)
            && address != WalletManager.shared.currentWallet?.publicAddress
    }

    static func shortAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return address.prefix(14) + "..." + address.suffix(6)
    }

    static func formatKas(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        var formatted = String(format: "%.8f", kas)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    // MARK: - Gating

    /// Settings > Notifications > "Address Activity" plus the master notification mode.
    private var featureEnabled: Bool {
        let settings = AppSettings.load()
        return settings.addressActivityNotificationsEnabled && settings.notificationMode != .disabled
    }

    // MARK: - Address set caching

    private func refreshCaches() {
        guard let wallet = WalletManager.shared.currentWallet else {
            cachedWalletAddress = nil
            cachedSpendingMaxIndex = -1
            spendingAddressSet = []
            coldDeriveTask?.cancel()
            coldDeriveTask = nil
            coldFingerprint = ""
            coldOwnSet = []
            coldNotifySet = []
            coldAccountLabels = [:]
            return
        }
        let network = AppSettings.load().networkType
        let networkKey = String(describing: network)
        let walletChanged = cachedWalletAddress != wallet.publicAddress || cachedNetworkKey != networkKey

        // both chains: allSpendingAddresses covers quantum slots, and the fingerprint must move
        // when either chain grows or a new quantum address would go unwatched
        let maxIndex = WalletManager.shared.maxSpendingAddressIndex
            + (WalletManager.shared.maxQuantumAddressIndex + 1) * 100_000
        if walletChanged || cachedSpendingMaxIndex != maxIndex {
            let before = spendingAddressSet
            spendingAddressSet = Set(WalletManager.shared.allSpendingAddresses())
            cachedSpendingMaxIndex = maxIndex
            if spendingAddressSet != before { Self.pushAddressesMayHaveChanged() }
        }

        if walletChanged { spendingNotifyLoadedForWallet = nil }
        reloadSpendingSwitchForCurrentWallet()

        cachedWalletAddress = wallet.publicAddress
        cachedNetworkKey = networkKey

        refreshColdCaches(wallet: wallet.publicAddress, network: network, walletChanged: walletChanged)
    }

    /// Works the cold sets out again when the wallet, the network or the accounts (their kpubs,
    /// address counts and switches) changed; then the UTXO subscription picks the watched ones up.
    private func refreshColdCaches(wallet: String, network: NetworkType, walletChanged: Bool) {
        let cold = ColdStorageManager.shared
        let accounts = cold.accounts
        let fingerprint = ([wallet, network.rawValue, String(cold.hiddenRevision)] + accounts.map {
            "\($0.kpubString)|\($0.maxAddressIndex)|\($0.notifyOnReceive)|\($0.label)|\($0.quantumAddresses.map(\.address).joined(separator: "+"))"
        }).joined(separator: ",")
        guard fingerprint != coldFingerprint else { return }
        coldFingerprint = fingerprint
        if walletChanged {
            // never the last wallet's addresses meanwhile
            coldOwnSet = []
            coldNotifySet = []
            coldAccountLabels = [:]
            coldNotifyFlags = [:]
            coldAbsorbPending = []
        }
        coldAbsorbPending.formUnion(accounts.filter { $0.notifyOnReceive && coldNotifyFlags[$0.id] == false }.map(\.id))
        let switchedOn = coldAbsorbPending
        coldNotifyFlags = Dictionary(accounts.map { ($0.id, $0.notifyOnReceive) }, uniquingKeysWith: { _, b in b })
        coldDeriveTask?.cancel()
        guard !accounts.isEmpty else {
            let watchedBefore = coldNotifySet
            coldOwnSet = []
            coldNotifySet = []
            coldAccountLabels = [:]
            coldDeriveTask = nil
            if !watchedBefore.isEmpty { ChatService.shared.checkAndResubscribeIfNeeded() }
            return
        }
        // Watched (and notifying) are the addresses each account shows; hidden ones are empty
        // slots the person put away, still ours for the self-send check.
        let hiddenByAccount = accounts.reduce(into: [UUID: Set<Int>]()) { result, account in
            result[account.id] = cold.hiddenIndexSet(accountId: account.id)
        }
        coldDeriveTask = Task { [weak self] in
            var own = Set<String>()
            var notify = Set<String>()
            var absorb = Set<String>()
            var labels: [String: String] = [:]
            for account in accounts {
                let derived = await ColdStorageAddressCache.shared.addressesInBackground(
                    kpub: account.kpubString, network: network,
                    indices: 0..<(UInt32(max(account.maxAddressIndex, 0)) + 1), stopOnFailure: false
                )
                guard !Task.isCancelled else { return }
                let hidden = hiddenByAccount[account.id] ?? []
                // the KasSigner quantum addresses added by scan, after the derived ones
                let quantum = account.quantumAddresses.enumerated().map {
                    (UInt32(ColdStorageManager.quantumIndexBase + $0.offset), $0.element.address)
                }
                for (index, address) in derived + quantum {
                    own.insert(address)
                    labels[address] = account.label
                    if account.notifyOnReceive, !hidden.contains(Int(index)) {
                        notify.insert(address)
                        if switchedOn.contains(account.id) { absorb.insert(address) }
                    }
                }
            }
            guard let self, !Task.isCancelled, self.coldFingerprint == fingerprint else { return }
            let watchedChanged = self.coldNotifySet != notify
            self.coldOwnSet = own
            self.coldNotifySet = notify
            self.coldAccountLabels = labels
            self.coldDeriveTask = nil
            self.coldAbsorbPending.subtract(switchedOn)
            if !absorb.isEmpty { Task { await self.refreshBaselines(for: absorb, wallet: wallet) } }
            // the UTXO subscription takes the new watched set (a no-op before it's set up)
            if watchedChanged {
                ChatService.shared.checkAndResubscribeIfNeeded()
                Self.pushAddressesMayHaveChanged()
            }
        }
    }

    /// The addresses the push service watches for Received KAS while the app is closed
    /// (`watch_only_addresses`): the spending ones while their switch is on and the Cold Storage
    /// ones whose account notifies; none with Address Activity off. Not the chatting address:
    /// its receives come as chat pushes, and a plain transfer to it only notifies while open.
    func pushWatchOnlyAddresses() -> Set<String> {
        guard featureEnabled else { return [] }
        refreshCaches()
        var set = Set<String>()
        if spendingReceiveNotificationsEnabled { set.formUnion(spendingAddressSet) }
        set.formUnion(coldNotifySet)
        return set
    }

    /// The push registration follows the Received KAS addresses (it skips an unchanged set).
    static func pushAddressesMayHaveChanged() {
        Task { @MainActor in await PushNotificationManager.shared.updateWatchedAddresses() }
    }

    /// Addresses whose receives should NOTIFY: the watched own addresses and the chatting
    /// address. For the chatting address only a plain transfer counts (no payload): a chat
    /// payment or a handshake is the chat's own news (`isPlainTransfer`).
    private func notifiableAddressSet(walletAddress: String) -> Set<String> {
        // The spending chain has its own switch: switched off, it is still ours (self-send check),
        // just quiet.
        var set = Set<String>()
        if spendingReceiveNotificationsEnabled { set.formUnion(spendingAddressSet) }
        // Cold Storage: each account's own switch, already applied to this set.
        set.formUnion(coldNotifySet)
        set.insert(walletAddress)
        return set
    }

    /// A transaction with no payload: plain KAS, not a KaChat chat payment, message or handshake.
    private static func isPlainTransfer(_ tx: KaspaFullTransactionResponse) -> Bool {
        (tx.payload ?? "").isEmpty
    }

    /// The newest block time (ms) the chatting address's catch-up has already looked at, per
    /// wallet: older receives were before it was watched, or already notified - never a burst
    /// of old payments.
    private func chattingCatchUpFloorKey(_ wallet: String) -> String { "addr_activity_chat_floor_\(wallet.lowercased())" }

    /// Addresses that count as "ours" when they appear among a tx's INPUTS - superset of the
    /// notifiable set: chatting address + all spending (reserved pool addresses are
    /// spending-chain indices, so they're covered).
    private func ownInputAddressSet(walletAddress: String) -> Set<String> {
        // Cold Storage addresses too: a KasSigner-signed send's change is never "Received".
        var set = spendingAddressSet.union(coldOwnSet)
        set.insert(walletAddress)
        return set
    }

    // MARK: - Baseline persistence (UserDefaults, per wallet)

    private func baselinesKey(wallet: String) -> String {
        "kachat_addr_activity_baselines_\(wallet)"
    }

    private func handledTxIdsKey(wallet: String) -> String {
        "kachat_addr_activity_handled_txids_\(wallet)"
    }

    /// Delete Account: the wallet's catch-up floor, baselines and handled transactions.
    func removeAllData(forWallet wallet: String) {
        UserDefaults.standard.removeObject(forKey: chattingCatchUpFloorKey(wallet))
        UserDefaults.standard.removeObject(forKey: baselinesKey(wallet: wallet))
        UserDefaults.standard.removeObject(forKey: handledTxIdsKey(wallet: wallet))
        if handledLoadedForWallet == wallet {
            handledLoadedForWallet = nil
            handledTxIdOrder = []
            handledTxIds = []
        }
    }

    private func loadBaselines(wallet: String) -> [String: UInt64] {
        guard let data = UserDefaults.standard.data(forKey: baselinesKey(wallet: wallet)),
              let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveBaselines(_ baselines: [String: UInt64], wallet: String) {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        UserDefaults.standard.set(data, forKey: baselinesKey(wallet: wallet))
    }

    /// Re-fetches live balances for just-changed addresses and folds them into the persisted
    /// baseline, so the next catch-up doesn't re-detect (and re-notify) what the live path
    /// already handled.
    private func refreshBaselines(for addresses: Set<String>, wallet: String) async {
        guard !addresses.isEmpty else { return }
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(Array(addresses)) else { return }
        var balances: [String: UInt64] = [:]
        for address in addresses { balances[address] = 0 }
        for utxo in utxos where balances[utxo.address] != nil {
            balances[utxo.address, default: 0] += utxo.amount
        }
        var baselines = loadBaselines(wallet: wallet)
        for (address, balance) in balances {
            baselines[address] = balance
        }
        saveBaselines(baselines, wallet: wallet)
    }

    /// A transaction this phone sends whose KAS change lands on one of your addresses with no input
    /// from one of them (a kUSDT send or Combine Coins: its inputs are token coins at their own
    /// contract addresses), so the own-funds check can't tell it's yours: never "Received".
    func markOwnTransaction(_ txId: String) {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
        markHandled(txId: txId.lowercased(), wallet: wallet)
    }

    // MARK: - Handled-tx persistence

    private func ensureHandledTxIdsLoaded(wallet: String) {
        guard handledLoadedForWallet != wallet else { return }
        handledLoadedForWallet = wallet
        let stored = UserDefaults.standard.stringArray(forKey: handledTxIdsKey(wallet: wallet)) ?? []
        handledTxIdOrder = stored
        handledTxIds = Set(stored)
    }

    private func markHandled(txId: String, wallet: String) {
        ensureHandledTxIdsLoaded(wallet: wallet)
        guard handledTxIds.insert(txId).inserted else { return }
        handledTxIdOrder.append(txId)
        if handledTxIdOrder.count > Self.handledTxIdCap {
            let overflow = handledTxIdOrder.count - Self.handledTxIdCap
            for dropped in handledTxIdOrder.prefix(overflow) {
                handledTxIds.remove(dropped)
            }
            handledTxIdOrder.removeFirst(overflow)
        }
        UserDefaults.standard.set(handledTxIdOrder, forKey: handledTxIdsKey(wallet: wallet))
    }
}

extension Notification.Name {
    /// Posted after own-address (spending) balances changed due to detected
    /// receive activity - an open Manage Addresses screen reloads on it.
    static let ownAddressActivity = Notification.Name("ownAddressActivity")
    /// Always-posted internal event for ANY UTXO activity on watched own addresses - including
    /// self-send change that never produces an `.ownAddressActivity` post (fast-path suppression)
    /// and regardless of the Address Activity notification setting. UserInfo carries the
    /// involved addresses under `AddressActivityNotifier.utxoActivityAddressesKey`.
    static let ownAddressUtxoActivity = Notification.Name("ownAddressUtxoActivity")
}
