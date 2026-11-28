import SwiftUI
import UserNotifications

// Tokens on Kaspa L1 (KCC-20), starting with Trestly's kUSDT (owner's call, 2026-11-19): held,
// received and sent here (ported from KaPay 2026-11-19), and bought, swapped and sold on Trestly's
// site inside K (Swap Stablecoins).

/// A token KaChat can hold. Amounts are whole base units (`decimals` places: kUSDT has 6).
struct WalletToken: Identifiable, Hashable {
    let id: String
    let symbol: String
    /// What people read under the symbol ("Bridged USDT").
    let name: LocalizedStringKey
    let decimals: Int
    /// Worth one US dollar (a stablecoin): the screens show its dollar value without a price feed.
    let isDollarStable: Bool
    /// Who issues it on Kaspa.
    let issuer: String
    let issuerSite: URL
    /// Where its backing can be checked on chain.
    let backingURL: URL
    /// KAS every token coin holds (kUSDT's `tokenValue`, 1.5 KAS): a send carries it to the
    /// recipient's new coin.
    let kasPerCoinSompi: UInt64

    static func == (lhs: WalletToken, rhs: WalletToken) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// kUSDT: USDT from Ethereum and BNB Chain, held 1:1 in Trestly's vault and issued as a
    /// KCC-20 token on Kaspa L1 (kusdt-open, mainnet launched 2026-11-15).
    static let kusdt = WalletToken(
        id: "kusdt",
        symbol: "kUSDT",
        name: "Bridged USDT",
        decimals: 6,
        isDollarStable: true,
        issuer: "Trestly",
        issuerSite: URL(string: "https://trestly.io")!,
        backingURL: URL(string: "https://etherscan.io/address/0xfa9869982542FB20baD929789B252b7b06EeE10e")!,
        kasPerCoinSompi: 150_000_000
    )

    /// Every token the app knows, for reading a token id or symbol back (chat payment bubbles).
    static let all: [WalletToken] = [.kusdt]

    /// "12.5" → "12.50": the amount with a dot, no grouping, at least two decimals for a dollar
    /// token. What a chat payment bubble's text carries, so the bubble can read it back.
    func plainAmount(_ units: UInt64) -> String {
        var scale: UInt64 = 1
        for _ in 0..<decimals { scale *= 10 }
        let whole = units / scale
        var fraction = String(String(units % scale).reversed()).padding(toLength: decimals, withPad: "0", startingAt: 0)
        fraction = String(fraction.reversed())
        while fraction.count > (isDollarStable ? 2 : 0), fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)"
    }
}

extension KaspaUnit {
    /// "1,234.5 KAS": `amount`, with the thousands grouped the way this phone writes them.
    static func groupedAmount(_ sompi: UInt64) -> String {
        "\(KaspaAmountEntry.grouped(plain(sompi))) \(symbol)"
    }

    /// "1,234.50000000": all eight decimals, grouped (Manage Addresses' balances).
    static func groupedExact(_ sompi: UInt64) -> String {
        KaspaAmountEntry.grouped("\(sompi / 100_000_000).\(String(format: "%08llu", sompi % 100_000_000))")
    }
}

/// Turning token base units into text and back.
enum TokenAmount {
    /// "125.50", "0.25", "1,250", "0.000001": grouped, at least two decimals for a dollar token,
    /// trailing zeros past that dropped.
    static func plain(_ units: UInt64, token: WalletToken) -> String {
        // grouped and with the decimal point the way this phone writes them
        KaspaAmountEntry.grouped(typed(units, token: token, keepCents: token.isDollarStable))
    }

    /// "125.5" (or "125.50" with `keepCents`): no grouping, "." the decimal point - what the
    /// keypad types (Max).
    static func typed(_ units: UInt64, token: WalletToken, keepCents: Bool = false) -> String {
        let scale = pow10(token.decimals)
        let whole = units / scale
        var frac = String(format: "%0\(token.decimals)llu", units % scale)
        let keep = keepCents ? 2 : 0
        while frac.count > keep, frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? "\(whole)" : "\(whole).\(frac)"
    }

    /// "125.50 kUSDT".
    static func amount(_ units: UInt64, token: WalletToken) -> String {
        "\(plain(units, token: token)) \(token.symbol)"
    }

    /// "$125.50" for a dollar token (two decimals), nil for others.
    static func dollars(_ units: UInt64, token: WalletToken) -> String? {
        guard token.isDollarStable else { return nil }
        let value = Double(units) / Double(pow10(token.decimals))
        return dollarFormatter().string(from: NSNumber(value: value))
    }

    /// One formatter per language, not one per call (the Wallet card and Manage kUSDT redraw often).
    private static var cachedDollarFormatter: (locale: Locale, formatter: NumberFormatter)?
    private static func dollarFormatter() -> NumberFormatter {
        let locale = AppLocalization.locale
        if let cached = cachedDollarFormatter, cached.locale == locale { return cached.formatter }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = locale
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        cachedDollarFormatter = (locale, f)
        return f
    }

    /// Typed text ("12.5") to base units; nil for nothing, zero or more decimals than the token has.
    static func units(fromTyped text: String, token: WalletToken) -> UInt64? {
        let clean = text.replacingOccurrences(of: ",", with: "")
        guard !clean.isEmpty else { return nil }
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = UInt64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
        var fracText = parts.count == 2 ? String(parts[1]) : ""
        guard fracText.count <= token.decimals else { return nil }
        fracText += String(repeating: "0", count: token.decimals - fracText.count)
        guard let frac = UInt64(fracText.isEmpty ? "0" : fracText) else { return nil }
        let (scaled, o1) = whole.multipliedReportingOverflow(by: pow10(token.decimals))
        let (total, o2) = scaled.addingReportingOverflow(frac)
        guard !o1, !o2, total > 0 else { return nil }
        return total
    }

    static func pow10(_ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(1)) { value, _ in value * 10 }
    }
}

/// One line of a token's activity.
struct TokenActivity: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case received, sent, swapped, bridged, combined }
    /// "txid:holding:kind" for what this phone records, so a send noted twice (a lost answer,
    /// then Try Again) is one line.
    var id = UUID().uuidString
    let kind: Kind
    let units: UInt64
    /// The other side: an address or a name.
    let counterparty: String
    let date: Date
    var pending = false
    /// Which of your addresses it happened on (`TokenHolding.id`).
    var holdingID = "chatting"
    /// The network fee (sompi), when this phone paid it (a send or Combine Coins).
    var fee: UInt64? = nil
    /// A swap that sold kUSDT (it went out); nil or false for one that bought it.
    var outgoing: Bool? = nil

    /// The transaction id, for a line this phone recorded ("txid:holding:kind").
    var txid: String? {
        let first = id.split(separator: ":").first.map(String.init) ?? ""
        return first.count == 64 && first.allSatisfy(\.isHexDigit) ? first : nil
    }
}

/// Where some of a token is held: the Chatting Address or one of the regular (legacy, key)
/// spending addresses. Never a quantum-safe address: sending a token from one reveals its key
/// (its KAS has to be spent with it), and Trestly's builder and pool don't take one.
struct TokenHolding: Identifiable, Equatable {
    /// nil: the Chatting Address; else the legacy spending index.
    let spendingIndex: Int?
    let address: String
    let units: UInt64
    /// Coins (UTXOs) holding it here: each holds the token's `kasPerCoinSompi` of KAS.
    let coins: Int

    var id: String { spendingIndex.map { "s\($0)" } ?? "chatting" }
    var isChatting: Bool { spendingIndex == nil }

    /// "Chatting Address", or the address's name as Manage Addresses shows it: the one you gave it
    /// (Rename Address, shared with Manage Addresses), else "Address #3".
    @MainActor var label: String {
        guard let spendingIndex else { return AppLocalization.string("Chatting Address") }
        return WalletManager.shared.ownAddressLabel(for: address) ?? "Address #\(WalletManager.addressNumber(forIndex: spendingIndex))"
    }
}

/// The account's tokens: balances by address, activity, and what can be done with them.
/// Tokens live on the Chatting Address and on the regular spending addresses (owner's call,
/// 2026-11-19: privacy from the start), so a payment can go to an address that isn't tied to
/// your name.
@MainActor
final class TokenWallet: ObservableObject {
    static let shared = TokenWallet()

    /// The tokens KaChat shows, in order.
    let tokens: [WalletToken] = [.kusdt]

    /// Where each token is held, by token id; nil until the first lookup answers.
    @Published private(set) var holdings: [String: [TokenHolding]] = [:]
    @Published private(set) var activity: [String: [TokenActivity]] = [:]
    /// Each address's verified coins, by holding id (what a send spends).
    private(set) var coins: [String: [KusdtBalances.Coin]] = [:]
    @Published private(set) var isRefreshing = false
    /// A Discover is looking (Send Dollars runs one as it opens, so a From step with no kUSDT
    /// says it's still checking rather than "none").
    @Published private(set) var isDiscovering = false
    /// Sends already noted (`noteSent`), so a resend of the same transaction isn't counted twice.
    private var notedSentTxids: Set<String> = []
    /// Why the last lookup failed; the screens keep the last good balances.
    @Published private(set) var lastError: String?
    private var lastRefreshed: Date?
    /// The account the balances belong to: another account's are dropped at once.
    private var loadedAccount: String?

    /// A coin of yours that a send from this phone just made (its change, or kUSDT sent to another
    /// of your addresses). Trestly's list can take a while to show it, and a balance built from
    /// that list alone dropped to 0 after a send. So it's checked on the node with the listed
    /// coins (`KusdtBalances.Expected`) until Trestly lists it, for up to 30 minutes.
    private struct PendingCoin {
        let holdingID: String
        let address: String
        let expected: KusdtBalances.Expected
        let since: Date
        var key: String { "\(expected.transactionId):\(expected.index)" }
    }
    private var pendingCoins: [PendingCoin] = []
    /// A refresh is due again shortly: a pending coin wasn't on the node yet.
    private var followUpScheduled = false
    /// The one lookup running (a refresh or a Discover). Every caller waits on it rather than
    /// starting its own, and it isn't a view's task, so leaving a screen doesn't cut it off.
    private var lookupTask: Task<Void, Never>?
    private var lastDiscovered: Date?
    /// Addresses the last tolerant lookup couldn't read.
    private var lastLookupFailures = 0
    /// Addresses a receive screen showed lately or a swap paid to (`noteReceiveAddressShown`), by
    /// account: the regular poll looks at them too, so kUSDT sent there is noticed without asking
    /// about every address. Kept on the phone (`token_receivewatch_kusdt_<account>`), so a Receive
    /// shown before a relaunch is still watched (audit 2026-11-25 B13).
    private var recentReceiveAddresses: [String: Date] = [:]
    private var recentReceiveAccount: String?

    private init() {}

    // MARK: Lookups

    /// Refreshes unless the balances are under `maxAge` seconds old (and for this account).
    /// `everyAddress`: every revealed address (Manage kUSDT); otherwise only the ones that matter
    /// (`pollTargets`).
    /// `background`: the regular poll, which doesn't publish `isRefreshing` (nothing on screen
    /// asked, and a dozen views observe it; audit 2026-11-25 B13).
    func refreshIfStale(maxAge: TimeInterval = 60, everyAddress: Bool = false, background: Bool = false) async {
        let account = WalletManager.shared.currentWallet?.publicAddress
        if account == loadedAccount, let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < maxAge { return }
        await refresh(everyAddress: everyAddress, background: background)
    }

    /// Looks the balances up again. One at a time: a call while another lookup runs waits for it,
    /// then runs only if that one was for another account (or a narrower look than asked for).
    func refresh(everyAddress: Bool = false, background: Bool = false) async {
        if let running = lookupTask {
            await running.value
            if loadedAccount == WalletManager.shared.currentWallet?.publicAddress, let lastRefreshed,
               Date().timeIntervalSince(lastRefreshed) < 5, !everyAddress { return }
        }
        await runLookup { await self.performRefresh(everyAddress: everyAddress, background: background) }
    }

    /// Runs `work` as the one lookup, after any other one finishes.
    private func runLookup<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        while let running = lookupTask {
            await running.value
            if lookupTask == running { lookupTask = nil }
        }
        let task = Task { @MainActor in await work() }
        let marker = Task { @MainActor in _ = await task.value }
        lookupTask = marker
        let value = await task.value
        if lookupTask == marker { lookupTask = nil }
        return value
    }

    private func performRefresh(everyAddress: Bool, background: Bool = false) async {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return }
        if account != loadedAccount {
            holdings = [:]
            coins = [:]
            pendingCoins = []
            loadedAccount = account
        }
        loadActivityIfNeeded(account: account)
        if !background { isRefreshing = true }
        defer { if isRefreshing { isRefreshing = false } }
        let targets = everyAddress || lastRefreshed == nil ? allRevealedTargets(account: account) : pollTargets(account: account)
        do {
            let results = try await lookUp(targets)
            // the account may have changed while the lookups ran
            guard WalletManager.shared.currentWallet?.publicAddress == account else { return }
            let previous = coins
            apply(results, for: .kusdt, merging: true)
            loadActivityIfNeeded(account: account)
            await announceNewCoins(previous: previous, account: account, token: .kusdt)
            // only a change publishes: every poll redrew Manage kUSDT (smoothness audit L11)
            if lastError != nil { lastError = nil }
            lastRefreshed = Date()
            scheduleFollowUpIfPending()
        } catch {
            if Self.isCancellation(error) { return }
            if lastError != error.localizedDescription { lastError = error.localizedDescription }
            AppLog.log("[kUSDT] lookup failed: %@", error.localizedDescription)
        }
    }

    /// A lookup cut short is no answer: never shown as an error.
    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// The Chatting Address and every revealed regular address.
    private func allRevealedTargets(account: String) -> [(spendingIndex: Int?, address: String)] {
        let manager = WalletManager.shared
        var targets: [(spendingIndex: Int?, address: String)] = [(nil, account)]
        let revealed = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
        for index in revealed.keys.sorted() {
            if let address = revealed[index] { targets.append((index, address)) }
        }
        return targets
    }

    /// What the regular refresh asks Trestly about: the Chatting Address, the addresses holding or
    /// listed for kUSDT, ones with kUSDT history here, ones a send is waiting on, and any a receive
    /// screen showed or a swap paid to lately. Not every address every time: Trestly would see them
    /// all together, from one IP, every 30 seconds, and could link them. No longer the newest few
    /// revealed: for an account with no kUSDT that was three lookups a beat for nothing (audit
    /// 2026-11-25 B13); the first lookup after a launch still asks about every revealed address.
    private func pollTargets(account: String) -> [(spendingIndex: Int?, address: String)] {
        let manager = WalletManager.shared
        let maxIndex = manager.maxSpendingAddressIndex
        var indices = Set((holdings[WalletToken.kusdt.id] ?? []).compactMap(\.spendingIndex))
        indices.formUnion(shownEmptyIndices(of: .kusdt))
        indices.formUnion((activity[WalletToken.kusdt.id] ?? []).compactMap { activity in
            activity.holdingID.hasPrefix("s") ? Int(activity.holdingID.dropFirst()) : nil
        })
        loadReceiveWatchIfNeeded(account: account)
        let watched = Set(pendingCoins.map { $0.address.lowercased() })
            .union(recentReceiveAddresses.filter { Date().timeIntervalSince($0.value) < Self.receiveWatchAge }.keys)
        let revealed = manager.spendingAddresses(inRange: 0..<(max(0, maxIndex) + 1))
        var targets: [(spendingIndex: Int?, address: String)] = [(nil, account)]
        for index in revealed.keys.sorted() {
            guard let address = revealed[index] else { continue }
            if indices.contains(index) || watched.contains(address.lowercased()) { targets.append((index, address)) }
        }
        return targets
    }

    /// A receive screen showed this address, or it was handed out another way (Manage Addresses'
    /// Copy and Generate Non-Quantum Address, a regular address picked for Request Payment): the
    /// regular refresh watches it for a week. Never called for quantum addresses, which can't hold
    /// tokens.
    func noteReceiveAddressShown(_ address: String) {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return }
        loadReceiveWatchIfNeeded(account: account)
        recentReceiveAddresses[address.lowercased()] = Date()
        recentReceiveAddresses = recentReceiveAddresses.filter { Date().timeIntervalSince($0.value) < Self.receiveWatchAge }
        UserDefaults.standard.set(recentReceiveAddresses.mapValues { $0.timeIntervalSince1970 },
                                  forKey: receiveWatchKey(account: account))
    }

    private static let receiveWatchAge: TimeInterval = 7 * 86_400

    private func receiveWatchKey(account: String) -> String { "token_receivewatch_\(WalletToken.kusdt.id)_\(account)" }

    /// The account's watched receive addresses, read once per account.
    private func loadReceiveWatchIfNeeded(account: String) {
        guard recentReceiveAccount != account else { return }
        recentReceiveAccount = account
        let saved = UserDefaults.standard.dictionary(forKey: receiveWatchKey(account: account)) as? [String: Double] ?? [:]
        recentReceiveAddresses = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private var tradeFollowTask: Task<Void, Never>?

    /// A swap from this phone went out (`TrestlyTrade.run`). The coins it made for you (the kUSDT
    /// bought, or a sell's kUSDT change) show only once Trestly lists them, which takes longer than
    /// the one look 4 s later that used to be all a swap got: with Address Activity notifications
    /// off nothing else looked again, so the balance stayed old until a pull to refresh. Looks
    /// again on a widening schedule (3 s to about 1.5 minutes) until a coin from the swap shows.
    func followTrade(txid: String, address: String) {
        // the regular look covers this address from now on, whatever it held before
        noteReceiveAddressShown(address)
        tradeFollowTask?.cancel()
        tradeFollowTask = Task { @MainActor [weak self] in
            for delay: UInt64 in [3, 4, 6, 8, 10, 15, 20, 30] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                if self.coins.values.contains(where: { list in list.contains { $0.transactionId == txid } }) {
                    return
                }
            }
        }
    }

    /// The lookups, four at a time. Any one failing fails the refresh, so a partial answer is never
    /// shown as the whole balance.
    /// `tolerant` (Discover): an address whose lookup fails is left out of the answer (it keeps what
    /// was known about it) instead of failing the whole sweep; `failed` counts them.
    private func lookUp(_ targets: [(spendingIndex: Int?, address: String)], tolerant: Bool = false,
                        progress: ((_ checkedThrough: Int?, _ found: Int) -> Void)? = nil) async throws -> [(spendingIndex: Int?, result: KusdtBalances.AddressResult)] {
        var out: [(spendingIndex: Int?, result: KusdtBalances.AddressResult)] = []
        let expectedByAddress = Dictionary(grouping: pendingCoins, by: \.address).mapValues { $0.map(\.expected) }
        var start = 0
        var failures = 0
        defer { lastLookupFailures = failures }
        while start < targets.count {
            let batch = targets[start..<min(start + 4, targets.count)]
            try await withThrowingTaskGroup(of: (Int?, KusdtBalances.AddressResult?).self) { group in
                for target in batch {
                    let expected = expectedByAddress[target.address] ?? []
                    group.addTask {
                        do {
                            return (target.spendingIndex, try await KusdtBalances.fetch(address: target.address, expected: expected))
                        } catch where tolerant && !Self.isCancellation(error) {
                            return (target.spendingIndex, nil)
                        }
                    }
                }
                for try await (index, result) in group {
                    if let result { out.append((index, result)) } else { failures += 1 }
                }
            }
            progress?(batch.last?.spendingIndex, out.filter { !$0.result.coins.isEmpty }.count)
            start += 4
        }
        return out
    }

    /// `merging`: the addresses not looked up this time keep what was known about them.
    private func apply(_ results: [(spendingIndex: Int?, result: KusdtBalances.AddressResult)], for token: WalletToken,
                       merging: Bool = false) {
        // pending coins: let go once Trestly lists them, or after 30 minutes
        let listed = results.reduce(into: Set<String>()) { $0.formUnion($1.result.listedByAPI) }
        pendingCoins.removeAll { listed.contains($0.key) || Date().timeIntervalSince($0.since) > 1800 }
        let verified = Set(results.flatMap { $0.result.coins }.map(Self.outpointKey))
        // one sent in the last 2 minutes that the node doesn't show yet still counts in the balance
        // (not in what a send can spend), so the balance doesn't dip while the network catches up
        let landing = pendingCoins.filter { !verified.contains($0.key) && Date().timeIntervalSince($0.since) < 120 }

        let lookedUp = Set(results.map { $0.result.address.lowercased() })
        // a coin a send from here is holding is spent, even while the node and Trestly still list it
        let held = ChatService.shared.heldOutpointKeys()
        var list: [TokenHolding] = merging
            ? (holdings[token.id] ?? []).filter { !lookedUp.contains($0.address.lowercased()) } : []
        var byHolding: [String: [KusdtBalances.Coin]] = merging
            ? coins.filter { id, _ in list.contains { $0.id == id } } : [:]
        for (index, result) in results {
            let live = result.coins.filter { !held.contains(Self.outpointKey($0)) }
            let extra = landing.filter { $0.address == result.address }
            guard !live.isEmpty || !extra.isEmpty else { continue }
            let units = live.reduce(UInt64(0)) { $0 + $1.state.amount } + extra.reduce(UInt64(0)) { $0 + $1.expected.state.amount }
            let holding = TokenHolding(spendingIndex: index, address: result.address, units: units,
                                       coins: live.count + extra.count)
            list.append(holding)
            byHolding[holding.id] = live
        }
        list.sort { ($0.spendingIndex ?? -1) < ($1.spendingIndex ?? -1) }
        // only a real change publishes (a dozen views observe it; audit 2026-11-25 B13)
        if holdings[token.id] != list { holdings[token.id] = list }
        coins = byHolding
    }

    /// Every address holding it, hidden ones included (the total, Send's From).
    func holdings(of token: WalletToken) -> [TokenHolding] {
        (allHoldings(of: token) ?? []).filter { $0.units > 0 }
    }

    /// The addresses Manage kUSDT lists, as Kaspa's Address Visibility decides for Manage
    /// Addresses: the Chatting Address always, then each regular address holding the token
    /// unless it's hidden, and any address without it that's checked on, in address order.
    func listedHoldings(of token: WalletToken) -> [TokenHolding] {
        let held = Dictionary(uniqueKeysWithValues: holdings(of: token).map { ($0.id, $0) })
        let hidden = hiddenHoldingIDs(of: token)
        let shown = shownEmptyIndices(of: token)
        var out: [TokenHolding] = []
        if let chatting = held["chatting"] {
            out.append(chatting)
        } else if let address = WalletManager.shared.currentWallet?.publicAddress {
            out.append(TokenHolding(spendingIndex: nil, address: address, units: 0, coins: 0))
        }
        var indices = Set(held.values.compactMap(\.spendingIndex).filter { !hidden.contains("s\($0)") })
        indices.formUnion(shown)
        for index in indices.sorted() {
            if let holding = held["s\(index)"] {
                out.append(holding)
            } else if let address = WalletManager.shared.spendingAddress(at: index) {
                out.append(TokenHolding(spendingIndex: index, address: address, units: 0, coins: 0))
            }
        }
        return out
    }

    /// The regular spending slots Manage kUSDT lists. Manage Addresses always shows these too
    /// (owner's call, 2026-11-20, as KaPay has it): an address on the kUSDT list is never hidden
    /// from the Kaspa one. One way only, never a two-way sync.
    func listedSpendingIndices(of token: WalletToken = .kusdt) -> Set<Int> {
        Set(listedHoldings(of: token).compactMap(\.spendingIndex))
    }

    /// Whether Address Visibility has this address on Manage kUSDT's list.
    func isListed(_ holding: TokenHolding, of token: WalletToken) -> Bool {
        guard let index = holding.spendingIndex else { return true }
        if holding.units > 0 { return !hiddenHoldingIDs(of: token).contains(holding.id) }
        return shownEmptyIndices(of: token).contains(index)
    }

    /// Address Visibility's checkmark, tapped: an address holding the token is hidden or shown,
    /// one without it is put on the list or taken off. The Chatting Address always stays.
    func toggleListed(_ holding: TokenHolding, of token: WalletToken) {
        guard let index = holding.spendingIndex else { return }
        if holding.units > 0 {
            var hidden = hiddenHoldingIDs(of: token)
            if hidden.remove(holding.id) == nil { hidden.insert(holding.id) }
            setHiddenHoldingIDs(hidden, of: token)
        } else {
            var shown = shownEmptyIndices(of: token)
            if shown.remove(index) == nil { shown.insert(index) }
            setShownEmptyIndices(shown, of: token)
        }
    }

    /// Hide All: the list starts over with only the Chatting Address. Nothing is lost: the
    /// hidden addresses still count in the total.
    func hideAllListed(of token: WalletToken) {
        setHiddenHoldingIDs(Set(holdings(of: token).filter { !$0.isChatting }.map(\.id)), of: token)
        setShownEmptyIndices([], of: token)
    }

    // MARK: Address Visibility

    /// Bumped when a visibility set changes, so the screens that read it redraw.
    @Published private(set) var visibilityRevision = 0

    /// The visibility sets read so far, by defaults key: Manage kUSDT reads them per holding on
    /// every redraw (smoothness audit L11). Written through with the setters below, and dropped
    /// with the account (`forgetLocalData`).
    private var hiddenIDsCache: [String: Set<String>] = [:]
    private var shownIndicesCache: [String: Set<Int>] = [:]

    /// Addresses holding the token that are hidden from Manage kUSDT, per account and token.
    func hiddenHoldingIDs(of token: WalletToken) -> Set<String> {
        guard let key = visibilityKey("hidden", token) else { return [] }
        if let cached = hiddenIDsCache[key] { return cached }
        let ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        hiddenIDsCache[key] = ids
        return ids
    }

    func setHiddenHoldingIDs(_ ids: Set<String>, of token: WalletToken) {
        guard let key = visibilityKey("hidden", token) else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
        hiddenIDsCache[key] = ids
        visibilityRevision += 1
    }

    /// Spending indices without the token that are checked on, so Manage kUSDT lists them.
    func shownEmptyIndices(of token: WalletToken) -> Set<Int> {
        guard let key = visibilityKey("shown", token) else { return [] }
        if let cached = shownIndicesCache[key] { return cached }
        let indices = Set((UserDefaults.standard.array(forKey: key) as? [Int]) ?? [])
        shownIndicesCache[key] = indices
        return indices
    }

    func setShownEmptyIndices(_ indices: Set<Int>, of token: WalletToken) {
        guard let key = visibilityKey("shown", token) else { return }
        UserDefaults.standard.set(Array(indices).sorted(), forKey: key)
        shownIndicesCache[key] = indices
        visibilityRevision += 1
    }

    private func visibilityKey(_ kind: String, _ token: WalletToken) -> String? {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return "token_\(kind)_\(token.id)_\(account)"
    }

    // MARK: Sends

    /// A kUSDT send went out (`KusdtTransfer.send`): its coins are gone from the balances at once,
    /// every output it made is known (so your own change is never announced as received), and the
    /// balances are looked up again shortly, once the node has it.
    /// A swap made on Trestly's site from KaChat (`TrestlyProvider`): the kUSDT side, on that
    /// address's history, then a refresh once the pool's new coins can be listed.
    func noteSwap(token: WalletToken, spendingIndex: Int?, txid: String, units: UInt64, sold: Bool, fee: UInt64?) {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return }
        let holdingID = spendingIndex.map { "s\($0)" } ?? "chatting"
        record(TokenActivity(id: "\(txid):\(holdingID):swapped", kind: .swapped, units: units, counterparty: "Trestly",
                             date: Date(), holdingID: holdingID, fee: fee, outgoing: sold),
               token: token, account: account)
    }

    func noteSent(_ prepared: KusdtTransfer.Prepared) {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return }
        // once per transaction: Try Again after an unknown outcome notes the same one again, which
        // counted its change coin twice
        guard notedSentTxids.insert(prepared.txid).inserted else { return }
        let spent = Set(prepared.spentCoins.map(Self.outpointKey))
        for (id, list) in coins { coins[id] = list.filter { !spent.contains(Self.outpointKey($0)) } }
        pendingCoins.removeAll { spent.contains($0.key) }

        // the coins this send made that are yours: checked on the node until Trestly lists them
        let spentUnits = prepared.spentCoins.reduce(UInt64(0)) { $0 + $1.state.amount }
        if let changeIndex = prepared.changeIndex, spentUnits > prepared.amount,
           let owner = Kusdt.schnorrOwner(of: prepared.holding.address) {
            pendingCoins.append(PendingCoin(
                holdingID: prepared.holding.id, address: prepared.holding.address,
                expected: .init(transactionId: prepared.txid, index: changeIndex,
                                state: .plain(owner: owner, amount: spentUnits - prepared.amount)),
                since: Date()))
        }
        let ownRecipient = ownTokenAddress(prepared.recipient)
        if let ownRecipient, let owner = Kusdt.schnorrOwner(of: ownRecipient.address) {
            pendingCoins.append(PendingCoin(
                holdingID: ownRecipient.id, address: ownRecipient.address,
                expected: .init(transactionId: prepared.txid, index: 0, state: .plain(owner: owner, amount: prepared.amount)),
                since: Date()))
        }

        // the history: a combine, or a send (and its arrival, when it went to another of yours)
        let token = WalletToken.kusdt
        if prepared.recipient.lowercased() == prepared.holding.address.lowercased() {
            record(TokenActivity(id: "\(prepared.txid):\(prepared.holding.id):combined", kind: .combined, units: prepared.amount,
                                 counterparty: String(prepared.spentCoins.count), date: Date(), holdingID: prepared.holding.id,
                                 fee: prepared.fee),
                   token: token, account: account)
        } else {
            let to = ownRecipient.map { own in
                TokenHolding(spendingIndex: own.spendingIndex, address: own.address, units: 0, coins: 0).label
            } ?? prepared.recipientLabel ?? prepared.recipient
            record(TokenActivity(id: "\(prepared.txid):\(prepared.holding.id):sent", kind: .sent, units: prepared.amount,
                                 counterparty: to, date: Date(), holdingID: prepared.holding.id, fee: prepared.fee),
                   token: token, account: account)
            if let ownRecipient {
                record(TokenActivity(id: "\(prepared.txid):\(ownRecipient.id):received", kind: .received, units: prepared.amount,
                                     counterparty: prepared.holding.label, date: Date(), holdingID: ownRecipient.id),
                       token: token, account: account)
            }
        }

        var list = holdings[WalletToken.kusdt.id] ?? []
        if let i = list.firstIndex(where: { $0.id == prepared.holding.id }) {
            let old = list[i]
            let units = old.units > prepared.amount ? old.units - prepared.amount : 0
            list[i] = TokenHolding(spendingIndex: old.spendingIndex, address: old.address, units: units,
                                   coins: max(0, old.coins - prepared.spentCoins.count + (prepared.changeIndex == nil ? 0 : 1)))
        }
        if let ownRecipient {
            if let i = list.firstIndex(where: { $0.id == ownRecipient.id }) {
                let old = list[i]
                list[i] = TokenHolding(spendingIndex: old.spendingIndex, address: old.address,
                                       units: old.units + prepared.amount, coins: old.coins + 1)
            } else {
                list.append(TokenHolding(spendingIndex: ownRecipient.spendingIndex, address: ownRecipient.address,
                                         units: prepared.amount, coins: 1))
                list.sort { ($0.spendingIndex ?? -1) < ($1.spendingIndex ?? -1) }
            }
        }
        holdings[WalletToken.kusdt.id] = list.filter { $0.units > 0 || $0.coins > 0 }
        let key = seenKey(account: account, token: .kusdt)
        var seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        // every output of the send: it can only be yours if it's change, or a send to yourself
        for index in 0..<UInt32(prepared.rpc.outputs.count) { seen.insert("\(prepared.txid):\(index)") }
        UserDefaults.standard.set(Array(seen), forKey: key)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self.refresh()
        }
    }

    /// The address a send went to, if it's one of yours that can hold tokens: the Chatting Address
    /// or a revealed regular spending address.
    private func ownTokenAddress(_ address: String) -> (id: String, spendingIndex: Int?, address: String)? {
        let manager = WalletManager.shared
        let target = address.lowercased()
        if manager.currentWallet?.publicAddress.lowercased() == target {
            return ("chatting", nil, manager.currentWallet?.publicAddress ?? address)
        }
        let revealed = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
        guard let match = revealed.first(where: { $0.value.lowercased() == target }) else { return nil }
        return ("s\(match.key)", match.key, match.value)
    }

    /// A pending coin the node didn't show yet: look again in 5 seconds (the 2-minute window
    /// ends it).
    private func scheduleFollowUpIfPending() {
        let verified = Set(coins.values.flatMap { $0 }.map(Self.outpointKey))
        let waiting = pendingCoins.contains { !verified.contains($0.key) && Date().timeIntervalSince($0.since) < 120 }
        guard waiting, !followUpScheduled else { return }
        followUpScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.followUpScheduled = false
            await self.refresh()
        }
    }

    /// The verified coins of one address (what a send from it can spend).
    func coins(of holding: TokenHolding) -> [KusdtBalances.Coin] {
        guard loadedAccount == WalletManager.shared.currentWallet?.publicAddress else { return [] }
        return coins[holding.id] ?? []
    }

    // MARK: Received notifications

    /// A token coin doesn't land on your address (it sits at its own contract address), so the
    /// Kaspa watch never sees it arrive. Instead each refresh compares the coins it found with the
    /// ones known before (kept per account on this phone) and announces the new ones as Received,
    /// like Kaspa: the Notifications list always, and a local notification behind Settings >
    /// Notifications > Address Activity. Never announced: the first look on this phone (it only
    /// learns what's there), what Discover finds, and coins from your own transfers (the
    /// transaction spent a coin of yours, or paid from one of your addresses).
    private func announceNewCoins(previous: [String: [KusdtBalances.Coin]], account: String, token: WalletToken) async {
        let current = coins.values.flatMap { $0 }
        let known = seenOutpoints(account: account, token: token)
        // coins waiting for their chat notice stay "new", so a later refresh looks at them again
        var held = Set<String>()
        defer { rememberSeen(current.filter { !held.contains(Self.outpointKey($0)) }, account: account, token: token) }
        guard let known else { return } // first look: learn, don't announce
        let fresh = current.filter { !known.contains(Self.outpointKey($0)) }
        guard !fresh.isEmpty else { return }

        // a coin we knew that's gone now: something of ours was spent in this window
        let previousKeys = Set(previous.values.flatMap { $0 }.map(Self.outpointKey))
        let currentKeys = Set(current.map(Self.outpointKey))
        let ownCoinSpent = !previousKeys.subtracting(currentKeys).isEmpty
        let ownAddresses = Set(WalletManager.shared.allSpendingAddresses().map { $0.lowercased() } + [account.lowercased()])

        var received: [(holdingID: String, units: UInt64)] = []
        var checked: [String: (own: Bool, at: Date?)] = [:]
        // Whether any coin announced now came in the last few minutes: only those ring. Coins
        // that came while K was closed or this account was signed out go to the bell quietly,
        // dated when they came (owner, 2026-11-25: switching accounts pinged old receives).
        var anyCurrent = false
        var newest: Date?
        for (holdingID, list) in coins {
            for coin in list where fresh.contains(coin) {
                let own: Bool
                let at: Date?
                if let cached = checked[coin.transactionId] {
                    (own, at) = cached
                } else {
                    (own, at) = await Self.isOwnTransfer(coin.transactionId, known: known, ownAddresses: ownAddresses, fallback: ownCoinSpent)
                    checked[coin.transactionId] = (own, at)
                }
                if !own, coin.state.amount > 0 {
                    let key = Self.outpointKey(coin)
                    let filedByChat = ChatService.shared.isNoticeBubble(coin.transactionId)
                    // On the Chatting Address it may be a contact's Send Dollars whose chat notice
                    // comes a little after the coin: wait for it (up to `noticeWait`), so the
                    // chat's "Sent you 1.00 kUSDT" is the only ping (owner, 2026-11-22).
                    if !filedByChat, holdingID == "chatting" {
                        let firstSeen = awaitingNotice[key] ?? Date()
                        awaitingNotice[key] = firstSeen
                        if Date().timeIntervalSince(firstSeen) < Self.noticeWait {
                            held.insert(key)
                            continue
                        }
                    }
                    awaitingNotice.removeValue(forKey: key)
                    // a contact's Send Dollars the chat already showed and announced: no second banner
                    if !filedByChat {
                        received.append((holdingID, coin.state.amount))
                        // an unknown time counts as now, as the chats' `InAppBanner.isRecent` has
                        // it (audit 2026-11-25 C10)
                        if at.map({ Date().timeIntervalSince($0) <= Self.ringWindow }) ?? true { anyCurrent = true }
                        if let at { newest = max(newest ?? at, at) }
                    }
                    record(TokenActivity(id: "\(coin.transactionId):\(holdingID):received", kind: .received,
                                         units: coin.state.amount, counterparty: "", date: at ?? Date(), holdingID: holdingID),
                           token: token, account: account)
                }
            }
        }
        // The bell always gets it; only the ping follows the switches (owner, 2026-11-27).
        guard !received.isEmpty else { return }
        postReceived(received, token: token, ring: anyCurrent && Self.notificationsEnabled, happenedAt: newest)
    }

    /// How old a received coin may be and still ring: Trestly lists new coins late, and a coin
    /// on the Chatting Address waits up to `noticeWait` for its chat notice, so wider than the
    /// chats' 3 minutes.
    private static let ringWindow: TimeInterval = 6 * 60

    /// Coins on the Chatting Address waiting for a chat notice, by outpoint, with when first seen.
    private var awaitingNotice: [String: Date] = [:]
    /// How long a coin on the Chatting Address waits for its chat notice before the wallet
    /// announces it itself.
    private static let noticeWait: TimeInterval = 120

    /// Whether the transaction that made a coin was your own: it spent a coin of yours, or
    /// an input came from one of your addresses. When the REST API can't say, `fallback`.
    /// Also when it happened (its block time), nil when unknown.
    private static func isOwnTransfer(_ txid: String, known: Set<String>, ownAddresses: Set<String>, fallback: Bool) async -> (own: Bool, at: Date?) {
        guard let tx = await ChatService.shared.fetchFullTransaction(txId: txid, resolvePrevious: true) else { return (fallback, nil) }
        let at = tx.blockTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil }
        guard let inputs = tx.inputs, !inputs.isEmpty else { return (fallback, at) }
        for input in inputs {
            if let hash = input.previousOutpointHash?.lowercased(), let index = input.previousOutpointIndex,
               known.contains("\(hash):\(index)") { return (true, at) }
            if let address = input.previousOutpointAddress?.lowercased(), ownAddresses.contains(address) { return (true, at) }
        }
        return (false, at)
    }

    /// `ring` false: the bell only, no banner (none of the coins is from the last few minutes).
    private func postReceived(_ received: [(holdingID: String, units: UInt64)], token: WalletToken, ring: Bool, happenedAt: Date?) {
        let total = received.reduce(UInt64(0)) { $0 + $1.units }
        let content = UNMutableNotificationContent()
        // Just "Received 1.00 kUSDT" (owner, 2026-11-22): no "On your Chatting Address" line.
        content.title = String(format: AppLocalization.string("Received %@"), TokenAmount.amount(total, token: token))
        content.threadIdentifier = Self.notificationThread
        content.userInfo = ["token": token.id]
        let settings = AppSettings.load()
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil
        let id = "token-received-\(token.id)-\(UUID().uuidString)"
        if ring {
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        GlobalNotificationCenter.shared.record(id: id, source: .token, title: content.title, body: content.body,
                                               timestamp: Int64((happenedAt ?? Date()).timeIntervalSince1970 * 1000), targetId: token.id)
    }

    /// A tapped token notification opens that token's Manage screen (`KaChatApp`).
    nonisolated static let notificationThread = "token-received"

    /// Settings > Notifications > Address Activity, and notifications on at all (as for Kaspa).
    static var notificationsEnabled: Bool {
        let settings = AppSettings.load()
        return settings.addressActivityNotificationsEnabled && settings.notificationMode != .disabled
    }

    private static func outpointKey(_ coin: KusdtBalances.Coin) -> String { "\(coin.transactionId):\(coin.index)" }

    private func seenKey(account: String, token: WalletToken) -> String { "token_seen_\(token.id)_\(account)" }

    /// The coins known on this phone for the account; nil before its first look.
    private func seenOutpoints(account: String, token: WalletToken) -> Set<String>? {
        (UserDefaults.standard.stringArray(forKey: seenKey(account: account, token: token))).map(Set.init)
    }

    private func rememberSeen(_ list: [KusdtBalances.Coin], account: String, token: WalletToken) {
        let key = seenKey(account: account, token: token)
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        // the coins there now (and what Discover found), so the list never outgrows the wallet
        set = set.intersection(Set(coins.values.flatMap { $0 }.map(Self.outpointKey))).union(list.map(Self.outpointKey))
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    // MARK: Checking while the app is open

    private var pollTask: Task<Void, Never>?

    /// While the app is open and signed in, the balances are checked on every foreground beat
    /// (`ForegroundBeat`: 30 s on Wi-Fi, 60 s on cellular, 1.5 s after the room sweep, so the
    /// radio wakes once per beat; audit 2026-11-25 B4), so a token that arrives is announced. With
    /// Address Activity notifications off, every 5 minutes, so the bell still gets Received kUSDT
    /// (owner, 2026-11-27); the screens refresh themselves either way.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await ForegroundBeat.sleepUntilNextBeat(offset: 1.5)
                guard let self, !Task.isCancelled else { return }
                // Signed out: the loop ends rather than waking every beat for nothing; the next
                // sign-in's MainTabView starts it again (audit 2026-11-25 B19).
                guard WalletManager.shared.currentWallet != nil else {
                    self.pollTask = nil
                    return
                }
                guard UIApplication.shared.applicationState == .active else { continue }
                await self.refreshIfStale(maxAge: Self.notificationsEnabled ? 25 : 290, background: true)
            }
        }
    }

    // MARK: Discover

    /// Finds the addresses holding the token: the Chatting Address and the regular spending
    /// addresses from the first through 20 past the last one revealed, each looked up (and checked
    /// on the node). Any it finds past the revealed ones are revealed, so they stay on the list.
    /// Reports each address as it goes; returns how many hold some.
    func discoverHoldings(of token: WalletToken, progress: @escaping (_ checking: Int, _ found: Int) -> Void) async -> Int {
        await runLookup { await self.performDiscover(of: token, progress: progress) }
    }

    /// Discover, unless one ran in the last `maxAge` seconds for this account (Send Dollars opens
    /// it every time; once in a while is enough).
    func discoverIfStale(of token: WalletToken, maxAge: TimeInterval = 300) async {
        if loadedAccount == WalletManager.shared.currentWallet?.publicAddress, let lastDiscovered,
           Date().timeIntervalSince(lastDiscovered) < maxAge { return }
        _ = await discoverHoldings(of: token) { _, _ in }
    }

    private func performDiscover(of token: WalletToken, progress: @escaping (_ checking: Int, _ found: Int) -> Void) async -> Int {
        let manager = WalletManager.shared
        guard let account = manager.currentWallet?.publicAddress else { return 0 }
        if account != loadedAccount {
            holdings = [:]
            coins = [:]
            pendingCoins = []
            loadedAccount = account
        }
        isDiscovering = true
        defer { isDiscovering = false }
        let last = manager.maxSpendingAddressIndex + 20
        let derived = manager.spendingAddresses(inRange: 0..<(max(last, 0) + 1))
        var targets: [(spendingIndex: Int?, address: String)] = [(nil, account)]
        for index in derived.keys.sorted() {
            if let address = derived[index] { targets.append((index, address)) }
        }
        let results: [(spendingIndex: Int?, result: KusdtBalances.AddressResult)]
        do {
            // four at a time, like a refresh, reporting as each batch answers; an address that
            // doesn't answer is skipped, not the whole sweep
            results = try await lookUp(targets, tolerant: true) { checkedThrough, soFar in
                progress(checkedThrough.map(WalletManager.addressNumber(forIndex:)) ?? 0, soFar)
            }
        } catch {
            if !Self.isCancellation(error), lastError != error.localizedDescription { lastError = error.localizedDescription }
            return 0
        }
        if lastLookupFailures > 0 {
            AppLog.log("[kUSDT] Discover: %d addresses didn't answer, kept as they were", lastLookupFailures)
        }
        let found = results.filter { !$0.result.coins.isEmpty }.count
        guard manager.currentWallet?.publicAddress == account else { return found }
        // what Discover finds was there already: known from now on, never announced as received
        rememberSeen(results.flatMap { $0.result.coins }, account: account, token: token)
        // the furthest address holding some goes on the list, and every slot before it
        if let furthest = results.filter({ !$0.result.coins.isEmpty }).compactMap(\.spendingIndex).max(),
           furthest > manager.maxSpendingAddressIndex {
            // exactly that slot, for the account the sweep was for (the ones between stay hidden)
            await manager.revealSpendingAddress(at: furthest, owner: account)
        }
        // the reveal awaited: still the same account?
        guard manager.currentWallet?.publicAddress == account else { return found }
        apply(results, for: token, merging: true)
        if lastError != nil { lastError = nil }
        lastRefreshed = Date()
        lastDiscovered = Date()
        return found
    }

    /// An account removed from this phone (`WalletManager.removeLocalData`: Delete Account and
    /// the other removals): its token history, known coins and Address Visibility choices go, and
    /// so do the balances in memory if they're that account's.
    func forgetLocalData(account: String) {
        let defaults = UserDefaults.standard
        for token in tokens {
            for kind in ["activity", "seen", "hidden", "shown", "receivewatch"] {
                defaults.removeObject(forKey: "token_\(kind)_\(token.id)_\(account)")
            }
            hiddenIDsCache["token_hidden_\(token.id)_\(account)"] = nil
            shownIndicesCache["token_shown_\(token.id)_\(account)"] = nil
        }
        if loadedAccount == account {
            holdings = [:]
            coins = [:]
            pendingCoins = []
            loadedAccount = nil
            lastRefreshed = nil
        }
        if activityAccount == account {
            activity = [:]
            activityAccount = nil
        }
        if recentReceiveAccount == account {
            recentReceiveAddresses = [:]
            recentReceiveAccount = nil
        }
    }

    /// Every address together.
    func balance(of token: WalletToken) -> UInt64? {
        allHoldings(of: token).map { $0.reduce(0) { $0 + $1.units } }
    }

    // MARK: History (kept on this phone)

    /// Trestly's API keeps no history and a token coin never sits at your own address, so the
    /// history is what this phone saw: its sends and Combine Coins (`noteSent`), and kUSDT received
    /// from others (`announceNewCoins`), newest first, per account and token, 300 at most. What
    /// happened before, or in another app on the same words, isn't in it.
    private static let activityCap = 300
    private var activityAccount: String?

    private func activityKey(account: String, token: WalletToken) -> String { "token_activity_\(token.id)_\(account)" }

    /// The account's saved history, read once per account (never from a view's body).
    private func loadActivityIfNeeded(account: String) {
        guard activityAccount != account else { return }
        activityAccount = account
        var loaded: [String: [TokenActivity]] = [:]
        for token in tokens {
            if let data = UserDefaults.standard.data(forKey: activityKey(account: account, token: token)),
               let rows = try? JSONDecoder().decode([TokenActivity].self, from: data) {
                loaded[token.id] = rows
            }
        }
        activity = loaded
    }

    private func record(_ row: TokenActivity, token: WalletToken, account: String) {
        loadActivityIfNeeded(account: account)
        var rows = activity[token.id] ?? []
        rows.removeAll { $0.id == row.id }
        rows.insert(row, at: 0)
        rows.sort { $0.date > $1.date }
        if rows.count > Self.activityCap { rows.removeLast(rows.count - Self.activityCap) }
        activity[token.id] = rows
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: activityKey(account: account, token: token))
        }
    }

    func activity(of token: WalletToken) -> [TokenActivity] {
        activity[token.id] ?? []
    }

    /// One address's activity: its page's history.
    func activity(of token: WalletToken, at holding: TokenHolding) -> [TokenActivity] {
        activity(of: token).filter { $0.holdingID == holding.id }
    }

    private func allHoldings(of token: WalletToken) -> [TokenHolding]? {
        // another account's balances are never shown, even for the moment before they're replaced
        guard loadedAccount == WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return holdings[token.id]
    }

    /// KAS held with the token's coins (1.5 KAS each for kUSDT), returned to you as they're merged
    /// or sent.
    func kasHeld(by token: WalletToken) -> UInt64 {
        UInt64(holdings(of: token).reduce(0) { $0 + $1.coins }) * token.kasPerCoinSompi
    }

    /// "Chatting Address", "Address #3", or "2 Addresses".
    func heldOnText(_ token: WalletToken) -> String {
        let list = holdings(of: token)
        if list.count == 1 { return list[0].label }
        return String(format: AppLocalization.string("%d Addresses"), list.count)
    }

    /// A brand-new regular address to receive on: the next legacy slot, never revealed, funded or
    /// handed out. Derived only; `revealFreshReceiveAddress` puts it on the list once it's copied
    /// or shared.
    func freshReceiveAddress() -> (index: Int, address: String)? {
        let manager = WalletManager.shared
        // past every revealed slot, and never one already holding a token (it isn't fresh)
        let taken = Set(tokens.flatMap { holdings(of: $0) }.compactMap(\.spendingIndex))
        var index = manager.maxSpendingAddressIndex + 1
        while taken.contains(index) { index += 1 }
        guard let address = manager.spendingAddress(at: index) else { return nil }
        return (index, address)
    }

    /// Generate New Address (kUSDT Actions): the next unused regular address, revealed (so it's on
    /// Manage Addresses' list and watched) and checked on in Manage kUSDT's list, though it holds
    /// nothing yet. Answers its number ("#5"), or nil if no address could be derived.
    func generateFreshAddress(for token: WalletToken) async -> Int? {
        guard let fresh = freshReceiveAddress() else { return nil }
        await revealFreshReceiveAddress(fresh.index)
        var shown = shownEmptyIndices(of: token)
        shown.insert(fresh.index)
        setShownEmptyIndices(shown, of: token)
        return WalletManager.addressNumber(forIndex: fresh.index)
    }

    /// The fresh receive address goes on Manage Addresses' list (and is watched) once it's handed out.
    func revealFreshReceiveAddress(_ index: Int) async {
        let manager = WalletManager.shared
        // up to that slot (a fresh address can skip one already holding a token)
        while index > manager.maxSpendingAddressIndex {
            let before = manager.maxSpendingAddressIndex
            await manager.generateNextSpendingAddress()
            if manager.maxSpendingAddressIndex <= before { break }
        }
    }
}

// MARK: - Shared pieces

/// A token's round icon. A dollar token bridged from USDT shows the USDT mark (the white "T" with
/// its ring, on USDT green), drawn here rather than shipped as an image, with the small Kaspa logo
/// (`KaspaLogo`) at the corner: it's the bridged token on Kaspa, not USDT itself.
struct TokenIcon: View {
    let token: WalletToken
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Self.green)
            if token.isDollarStable {
                USDTMark()
                    .fill(Color.white, style: FillStyle(eoFill: false))
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            // the small Kaspa logo: it lives on Kaspa L1
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.38, height: size * 0.38)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                .offset(x: size * 0.06, y: size * 0.06)
        }
        .accessibilityHidden(true)
    }

    /// USDT green.
    static let green = Color(red: 0x26 / 255, green: 0xA1 / 255, blue: 0x7B / 255)
}

/// The USDT mark in a square: the T's bar, its stem, and the flat ring across the stem, in the
/// proportions of the published logo.
private struct USDTMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        // the bar
        p.addRect(CGRect(x: rect.minX + w * 0.23, y: rect.minY + h * 0.24, width: w * 0.54, height: h * 0.13))
        // the stem, through the ring and below it
        p.addRect(CGRect(x: rect.minX + w * 0.425, y: rect.minY + h * 0.37, width: w * 0.15, height: h * 0.42))
        // the ring: a flat ellipse round the stem, drawn as a band
        let outer = CGRect(x: rect.minX + w * 0.17, y: rect.minY + h * 0.415, width: w * 0.66, height: h * 0.17)
        let band = w * 0.05
        p.addPath(Path(ellipseIn: outer).strokedPath(StrokeStyle(lineWidth: band)))
        return p
    }
}

