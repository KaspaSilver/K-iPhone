import UIKit
import Foundation
import SwiftUI

// K's own block explorer (owner, 2026-11-25): blocks, transactions and addresses inside the app,
// so nothing opens a website. DESIGN STAGE: every screen reads `ExplorerDemo`, made-up data shaped
// like the real thing. Once the design is settled the same models are filled from the node pool
// (live blocks, mempool, coins) and 30 days of history; nothing in the views should need to change.

// MARK: - Models

/// What a transaction is, as K reads it: Kaspa's plain kinds and K's own protocols.
enum ExplorerTxKind: String, CaseIterable, Sendable {
    case payment
    case kachatMessage
    case handshake
    case paymentNotice
    case kapost
    /// A message in a public chat room (`kchat:1:bcast:`), readable by anyone.
    case publicChat
    case kachatName
    case kusdtTransfer
    case kusdtSwap
    case chessMove
    case arcadeStamp
    case coinbase
    case other

    var title: LocalizedStringKey {
        switch self {
        case .payment: return "Payment"
        case .kachatMessage: return "KaChat Message"
        case .handshake: return "Handshake"
        case .paymentNotice: return "Payment Notice"
        case .kapost: return "KaPost"
        case .publicChat: return "Public Chat"
        case .kachatName: return "Username"
        case .kusdtTransfer: return "kUSDT Transfer"
        case .kusdtSwap: return "Swap"
        case .chessMove: return "Chess Move"
        case .arcadeStamp: return "Arcade Score"
        case .coinbase: return "Mining Reward"
        case .other: return "Transaction"
        }
    }

    /// The kind counted ("KaChat Messages"), for K's 24-hour card.
    var plural: LocalizedStringKey {
        switch self {
        case .payment: return "Payments"
        case .kachatMessage: return "KaChat Messages"
        case .handshake: return "Handshakes"
        case .paymentNotice: return "Payment Notices"
        case .kapost: return "KaPosts"
        case .publicChat: return "Public Chat Messages"
        case .kachatName: return "Username Actions"
        case .kusdtTransfer: return "kUSDT Transfers"
        case .kusdtSwap: return "Swaps"
        case .chessMove: return "Chess Moves"
        case .arcadeStamp: return "Arcade Scores"
        case .coinbase: return "Mining Rewards"
        case .other: return "Transactions"
        }
    }

    var icon: String {
        switch self {
        case .payment: return "arrow.left.arrow.right"
        case .kachatMessage: return "lock.fill"
        case .handshake: return "hand.wave.fill"
        case .paymentNotice: return "bell.fill"
        case .kapost: return "square.text.square.fill"
        case .publicChat: return "number"
        case .kachatName: return "at"
        case .kusdtTransfer: return "dollarsign"
        case .kusdtSwap: return "arrow.triangle.2.circlepath"
        case .chessMove: return "checkerboard.rectangle"
        case .arcadeStamp: return "gamecontroller.fill"
        case .coinbase: return "hammer.fill"
        case .other: return "cube.fill"
        }
    }

    /// Every kind is drawn in the app's teal (owner, 2026-11-25): the icon tells them apart.
    var color: Color { .accentColor }

    /// One of K's own protocols (the K Activity page lists only these).
    var isK: Bool {
        switch self {
        case .payment, .coinbase, .other: return false
        default: return true
        }
    }

    /// What the explorer can say about it without anyone's keys.
    var explanation: LocalizedStringKey {
        switch self {
        case .payment: return "Kaspa sent from one address to another."
        case .kachatMessage: return "An end-to-end encrypted KaChat message. Only the two people in the chat can read it."
        case .handshake: return "Opens an encrypted KaChat chat between two addresses."
        case .paymentNotice: return "Tells a chat about a payment made from another address."
        case .kapost: return "A public post on KaPost, signed by its author."
        case .publicChat: return "A message in a public chat room, readable by anyone."
        case .kachatName: return "A .kachat username registered, renewed or traded on the registry."
        case .kusdtTransfer: return "kUSDT, a dollar token on Kaspa, moved between addresses."
        case .kusdtSwap: return "KAS and kUSDT swapped through Trestly's pool."
        case .chessMove: return "A move in an online chess game, played in Arcade."
        case .arcadeStamp: return "An Arcade score, stamped on chain so anyone can replay it."
        case .coinbase: return "New KAS paid to miners for the blocks they found."
        case .other: return "A Kaspa transaction."
        }
    }
}

struct ExplorerIO: Identifiable, Hashable, Sendable {
    let index: Int
    let address: String
    let amount: UInt64
    var id: Int { index }
}

struct ExplorerTransaction: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ExplorerTxKind
    let time: Date
    /// nil while it's in the mempool.
    let blockHash: String?
    let confirmations: Int
    /// nil when the inputs' amounts aren't known (a transaction read from a block).
    let fee: UInt64?
    let mass: UInt64
    let inputs: [ExplorerIO]
    let outputs: [ExplorerIO]
    let payloadHex: String
    /// The kUSDT it moved, in base units (6 decimals).
    let tokenUnits: UInt64?
    /// A public post's text, a username, a chess move: what K can show of the payload.
    let decoded: String?

    /// Whether the network accepted it; nil when not known (a block seconds old, read off the node).
    /// A block a miner finds is merged by many later blocks, each carrying a coinbase paying for it:
    /// only the chain block's is accepted, the rest moved nothing.
    var isAccepted: Bool? = nil
    var isNotAccepted: Bool { isAccepted == false }

    var isInMempool: Bool { blockHash == nil }
    /// What it moved, change excluded: the outputs that don't go back to the first input's address.
    /// Nil when that can't be told (audit 2026-11-25 C4): a transaction read off the node has no
    /// input addresses, so its change can't be picked out and its total would count it (a 1 KAS
    /// payment from a 10,000 KAS coin would read about 10,000). One output has no change.
    var movedAmount: UInt64? {
        let addressesKnown = inputs.isEmpty || inputs.contains { !$0.address.isEmpty }
        if !addressesKnown { return outputs.count == 1 ? outputs[0].amount : nil }
        let from = inputs.first?.address
        let away = outputs.filter { $0.address != from }
        // a self-send (a message, a post) moves its first output's amount
        if away.isEmpty { return outputs.first?.amount ?? 0 }
        return away.reduce(UInt64(0)) { $0.addingSaturated($1.amount) }
    }

    /// What it did to `address`: what came to it less what it spent, as a direction and an
    /// amount (an address page's rows and its Received / Sent).
    func net(for address: String) -> (isIncoming: Bool, amount: UInt64) {
        let into = outputs.filter { $0.address == address }.reduce(0) { $0 &+ $1.amount }
        let out = inputs.filter { $0.address == address }.reduce(0) { $0 &+ $1.amount }
        return into >= out ? (true, into - out) : (false, out - into)
    }

    /// The same transaction with its payload's text read (its own page).
    func with(decoded: String?) -> ExplorerTransaction {
        ExplorerTransaction(
            id: id, kind: kind, time: time, blockHash: blockHash, confirmations: confirmations, fee: fee,
            mass: mass, inputs: inputs, outputs: outputs, payloadHex: payloadHex, tokenUnits: tokenUnits,
            decoded: decoded, isAccepted: isAccepted
        )
    }
}

struct ExplorerBlock: Identifiable, Hashable, Sendable {
    let id: String
    let blueScore: UInt64
    let daaScore: UInt64
    let time: Date
    let isChainBlock: Bool
    let difficulty: Double
    let parents: [String]
    let children: [String]
    let mergeSetBlues: Int
    let mergeSetReds: Int
    let transactionIds: [String]
    /// The block's transactions, when they came with it.
    var transactions: [ExplorerTransaction] = []
}

struct ExplorerCoin: Identifiable, Hashable {
    let transactionId: String
    let index: Int
    let amount: UInt64
    let daaScore: UInt64
    var id: String { "\(transactionId):\(index)" }
}

struct ExplorerAddress: Hashable {
    let address: String
    let username: String?
    let balance: UInt64
    let kusdtUnits: UInt64?
    let received30d: UInt64
    let sent30d: UInt64
    /// Whether the history loaded reaches back 30 days, so received / sent are complete.
    var summaryCoversMonth = true
    /// Every transaction the address was in.
    var transactionCount: Int? = nil
    let transactions: [ExplorerTransaction]
    /// Where the next page of history starts; nil when there is none.
    var nextPageBefore: Int64? = nil
    let coins: [ExplorerCoin]
}

struct ExplorerNetworkStats: Hashable {
    let daaScore: UInt64
    let blueScore: UInt64
    let blocksPerSecond: Double
    /// Hashes per second.
    let hashrate: Double
    let mempoolSize: Int
    /// Sompi per gram of mass.
    let normalFeerate: Double
    let priorityFeerate: Double
    /// The average fee a transaction paid over the last 24 hours, in sompi.
    let averageFee24h: UInt64
    let circulatingSupply: UInt64
    let maxSupply: UInt64
    let priceUSD: Double
    let nodeVersion: String
    /// New KAS a block pays its miner, in sompi. It steps down every month (halving yearly).
    let blockReward: UInt64
    /// When the reward takes its next monthly step down.
    let nextRewardDrop: Date
}

/// The windows K's activity card cycles through (owner, 2026-11-25).
enum ExplorerKPeriod: String, CaseIterable, Hashable {
    case day, week, month, allTime

    /// The cycle button's label (a localization key).
    var title: String {
        switch self {
        case .day: return "24 Hours"
        case .week: return "7 Days"
        case .month: return "30 Days"
        case .allTime: return "All Time"
        }
    }

    /// What the change compares with; all time has nothing before it.
    var comparison: LocalizedStringKey? {
        switch self {
        case .day: return "vs the day before"
        case .week: return "vs the week before"
        case .month: return "vs the 30 days before"
        case .allTime: return nil
        }
    }

    /// The bar chart's two ends.
    var chartStart: LocalizedStringKey {
        switch self {
        case .day: return "24h ago"
        case .week: return "7 days ago"
        case .month: return "30 days ago"
        case .allTime: return "Launch"
        }
    }

    var chartEnd: LocalizedStringKey { self == .day ? "now" : "today" }

    /// What one bar is, for VoiceOver.
    var barMeaning: LocalizedStringKey {
        switch self {
        case .day: return "Transactions per hour"
        case .week, .month: return "Transactions per day"
        case .allTime: return "Transactions per month"
        }
    }
}

/// Everything K put on chain in a window: each of its protocols' transactions.
struct ExplorerKActivity: Hashable {
    let period: ExplorerKPeriod
    /// Transactions per kind, K's own kinds only.
    let counts: [ExplorerTxKind: Int]
    /// Transactions per bar (hour, day or month), oldest first, the last one still going. Nil
    /// until K's indexer serves the series (`/stats/activity`).
    var bars: [Int]? = nil
    /// The window before this one, for the change; nil for all time or when not served.
    var previousTotal: Int? = nil
    /// Addresses that sent at least one K transaction; nil when not served.
    var activeAddresses: Int? = nil
    /// Network fees K's transactions paid, in sompi; nil when not served.
    var fees: UInt64? = nil
    /// Made-up numbers (the design-stage demo).
    var isDemo = false

    var total: Int { counts.values.reduce(0) { $0.addingReportingOverflow($1).overflow ? .max : $0 + $1 } }
    /// Percent up (or down) on the window before.
    var change: Double? {
        guard let previousTotal, previousTotal > 0 else { return nil }
        return (Double(total) - Double(previousTotal)) / Double(previousTotal) * 100
    }
    /// Kinds with their counts, busiest first.
    var ranked: [(kind: ExplorerTxKind, count: Int)] {
        counts.map { (kind: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }
}

/// What the explorer can open: a page each.
/// The K Explorer setting's links (`KaspaExplorer.k`): `kachat://explorer-tx/<64 hex>` and
/// `kachat://explorer-address/<kaspa address>`, which K opens from its own "View in Explorer"
/// buttons and the system hands back to `KaChatApp.handleIncomingURL`. They open Kaspa Hub's
/// Explorer on that transaction or address (owner, 2026-11-26). Only K writes them.
enum ExplorerDeepLink {
    static let txHost = "explorer-tx"
    static let addressHost = "explorer-address"

    /// The page to open, from one of these links; nil for anything else or a bad payload.
    static func route(from url: URL) -> ExplorerRoute? {
        guard url.scheme?.lowercased() == "kachat", let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let payload = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch host {
        case txHost:
            let id = payload.lowercased()
            guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
            return .transaction(id)
        case addressHost:
            let address = payload.lowercased()
            guard KaspaAddress.isValid(address) else { return nil }
            return .address(address)
        default:
            return nil
        }
    }

    /// The page waiting for the Explorer to show (a cold start, or the section not open yet).
    @MainActor static var pending: ExplorerRoute?

    /// Opens Kaspa Hub's Explorer on `route`. Most of these links are tapped in a sheet (a
    /// payment's details, a message's menu): the sheets close first, or the Explorer would open
    /// behind them.
    @MainActor static func open(_ route: ExplorerRoute) {
        pending = route
        PendingTabRoute.pending = .explorer
        let go = {
            NotificationCenter.default.post(name: .openHubSection, object: nil)
            NotificationCenter.default.post(name: .explorerDeepLink, object: nil)
        }
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        // A sheet that can't be swiped away (a send under way, the backup steps, a site's
        // payment) is never closed by a link, which any app can send: the Explorer opens behind
        // it and shows once it's closed (audit 2026-11-27 L6).
        var presented = root?.presentedViewController
        var locked = false
        while let sheet = presented {
            if sheet.isModalInPresentation { locked = true; break }
            presented = sheet.presentedViewController
        }
        if let root, root.presentedViewController != nil, !locked {
            root.dismiss(animated: true) { go() }
        } else {
            go()
        }
    }
}

extension Notification.Name {
    /// `ExplorerDeepLink.open`: the Explorer, if it's already up, takes the waiting page.
    static let explorerDeepLink = Notification.Name("explorerDeepLink")
}

enum ExplorerRoute: Hashable {
    case transaction(String)
    case block(String)
    case address(String)
    /// A home tile's full chart (Hashrate, KAS Price, Block Reward, Market Cap).
    case chart(ExplorerChartMetric)
}

/// What a typed search turns out to be.
enum ExplorerSearchMatch: Equatable {
    case route(ExplorerRoute)
    case notFound
}

// MARK: - Demo data

/// Made-up data in the real shapes, the same every time for the same id, so any tap lands
/// somewhere believable. Replaced by the node pool and the 30-day history once the design is
/// settled.
enum ExplorerDemo {
    /// A deterministic generator: the same seed, the same numbers.
    struct Seeded {
        private var state: UInt64
        init(_ seed: String) {
            var h: UInt64 = 0xcbf29ce484222325
            for b in seed.utf8 { h ^= UInt64(b); h &*= 0x100000001b3 }
            state = h == 0 ? 1 : h
        }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func hex(_ count: Int) -> String {
            let digits = Array("0123456789abcdef")
            return String((0..<count).map { _ in digits[Int(next() % 16)] })
        }
        mutating func address() -> String {
            let chars = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
            return "kaspa:q" + String((0..<60).map { _ in chars[Int(next() % 32)] })
        }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    static let launchedAt = Date()

    /// Everything a list showed, so its page shows the very same block or transaction.
    @MainActor private static var shownBlocks: [String: ExplorerBlock] = [:]
    @MainActor private static var shownTransactions: [String: ExplorerTransaction] = [:]
    static let baseDaa: UInt64 = 601_640_000
    static let baseBlue: UInt64 = 599_530_000

    /// The network now: the scores run on at 10 blocks a second.
    static func stats(at now: Date) -> ExplorerNetworkStats {
        let elapsed = UInt64(max(0, now.timeIntervalSince(launchedAt)) * 10)
        let wobble = sin(now.timeIntervalSince1970 / 7)
        return ExplorerNetworkStats(
            daaScore: baseDaa + elapsed,
            blueScore: baseBlue + elapsed,
            blocksPerSecond: 10 + wobble * 0.08,
            hashrate: 1.47e18 * (1 + wobble * 0.01),
            mempoolSize: 34 + Int(wobble * 12),
            normalFeerate: 1,
            priorityFeerate: 1.2,
            averageFee24h: 31_400 + UInt64(max(0, wobble) * 1_800),
            circulatingSupply: 26_184_337_015 * 100_000_000 + elapsed * 600_000_000,
            maxSupply: 28_704_026_601 * 100_000_000,
            priceUSD: 0.0842 * (1 + wobble * 0.004),
            nodeVersion: "2.1.0",
            blockReward: 194_457_000,
            nextRewardDrop: launchedAt.addingTimeInterval(6 * 86_400 + 4 * 3_600)
        )
    }

    /// K's activity in `period`. Counts creep up while the screen is open, as a live feed would.
    static func kActivity(_ period: ExplorerKPeriod, at now: Date) -> ExplorerKActivity {
        let elapsed = Int(max(0, now.timeIntervalSince(launchedAt)))
        // a day's worth of each kind
        let base: [ExplorerTxKind: Double] = [
            .kachatMessage: 61_204, .handshake: 1_318, .paymentNotice: 2_406, .kapost: 8_917,
            .kachatName: 264, .kusdtTransfer: 3_752, .kusdtSwap: 941, .chessMove: 12_480,
            .arcadeStamp: 1_633,
        ]
        // per second, roughly each kind's share of the day
        let perSecond: [ExplorerTxKind: Double] = [
            .kachatMessage: 0.7, .handshake: 0.015, .paymentNotice: 0.03, .kapost: 0.1,
            .kachatName: 0.003, .kusdtTransfer: 0.04, .kusdtSwap: 0.01, .chessMove: 0.14,
            .arcadeStamp: 0.02,
        ]
        // how many days' worth each window holds (all time: K's history, growing)
        let days: Double
        switch period {
        case .day: days = 1
        case .week: days = 6.7
        case .month: days = 27.4
        case .allTime: days = 212
        }
        var counts: [ExplorerTxKind: Int] = [:]
        for (kind, perDay) in base {
            counts[kind] = Int(perDay * days) + Int(Double(elapsed) * (perSecond[kind] ?? 0))
        }
        var r = Seeded("k-\(period.rawValue)")
        let bars: [Int]
        switch period {
        case .day:
            // quieter overnight (UTC), busier in the evening
            var hourly = (0..<24).map { hour -> Int in
                let curve = 0.55 + 0.45 * sin(Double(hour - 6) / 24 * 2 * .pi)
                return Int(Double(3_200 + r.int(0...900)) * curve) + 1_400
            }
            hourly[23] = 900 + elapsed / 2
            bars = hourly
        case .week, .month:
            let count = period == .week ? 7 : 30
            var daily = (0..<count).map { index -> Int in
                // a slow climb with weekend dips
                let trend = 78_000 + index * (period == .week ? 1_900 : 520)
                let weekend = (index % 7 == 5 || index % 7 == 6) ? 0.86 : 1
                return Int(Double(trend + r.int(-6_000...6_000)) * weekend)
            }
            daily[count - 1] = 41_000 + elapsed
            bars = daily
        case .allTime:
            // monthly since launch: a fast start, then steady growth
            var monthly = (0..<14).map { index -> Int in
                let growth = 1 - exp(-Double(index + 1) / 4)
                return Int(2_400_000 * growth) + r.int(-90_000...90_000)
            }
            monthly[13] = 2_050_000 + elapsed * 5
            bars = monthly
        }
        let previous: Int?
        switch period {
        case .day: previous = 85_310
        case .week: previous = 584_900
        case .month: previous = 2_212_000
        case .allTime: previous = nil
        }
        let addresses: Int
        switch period {
        case .day: addresses = 9_874
        case .week: addresses = 31_206
        case .month: addresses = 74_532
        case .allTime: addresses = 212_418
        }
        return ExplorerKActivity(
            period: period,
            counts: counts,
            bars: bars,
            previousTotal: previous,
            activeAddresses: addresses + elapsed / 20,
            fees: UInt64(2_418 * days) * 100_000_000 + UInt64(elapsed) * 2_000_000,
            isDemo: true
        )
    }

    /// The newest blocks, newest first, as they'd stand `now`.
    @MainActor
    static func latestBlocks(at now: Date, count: Int = 12) -> [ExplorerBlock] {
        let tick = Int(max(0, now.timeIntervalSince(launchedAt)))
        let blocks = (0..<count).map { i in block(number: tick - i, now: now) }
        for block in blocks { shownBlocks[block.id] = block }
        return blocks
    }

    /// Block `number` counts seconds since launch (one shown a second, of the ten made).
    static func block(number: Int, now: Date) -> ExplorerBlock {
        var r = Seeded("block-\(number)")
        let hash = r.hex(64)
        return makeBlock(hash: hash, number: number, rng: &r)
    }

    @MainActor
    static func block(hash: String) -> ExplorerBlock {
        if let shown = shownBlocks[hash] { return shown }
        var r = Seeded("block-hash-\(hash)")
        return makeBlock(hash: hash, number: r.int(-5000 ... -20), rng: &r)
    }

    private static func makeBlock(hash: String, number: Int, rng r: inout Seeded) -> ExplorerBlock {
        let txCount = r.int(1...9)
        let txs = (0..<txCount).map { i in i == 0 ? "c0" + r.hex(62) : r.hex(64) }
        return ExplorerBlock(
            id: hash,
            blueScore: baseBlue + UInt64(max(0, number * 10 + 5000)),
            daaScore: baseDaa + UInt64(max(0, number * 10 + 5000)),
            time: launchedAt.addingTimeInterval(TimeInterval(number)),
            isChainBlock: r.int(0...3) != 0,
            difficulty: 1.517e16 + Double(r.int(0...900)) * 1e12,
            parents: (0..<r.int(2...7)).map { _ in r.hex(64) },
            children: (0..<r.int(0...3)).map { _ in r.hex(64) },
            mergeSetBlues: r.int(3...8),
            mergeSetReds: r.int(0...1),
            transactionIds: txs
        )
    }

    /// The newest transactions, newest first.
    @MainActor
    static func latestTransactions(at now: Date, count: Int = 14, kOnly: Bool = false) -> [ExplorerTransaction] {
        let tick = Int(max(0, now.timeIntervalSince(launchedAt)) / 2)
        var out: [ExplorerTransaction] = []
        var n = tick
        while out.count < count, n > tick - 400 {
            var r = Seeded("tx-n-\(n)")
            let tx = transaction(id: r.hex(64), at: launchedAt.addingTimeInterval(TimeInterval(n * 2)), mempool: n == tick)
            if !kOnly || tx.kind.isK { out.append(tx) }
            n -= 1
        }
        for tx in out { shownTransactions[tx.id] = tx }
        return out
    }

    private static let kindWeights: [ExplorerTxKind] = [
        .payment, .payment, .payment, .kachatMessage, .kachatMessage, .kachatMessage, .handshake,
        .kapost, .kapost, .kachatName, .kusdtTransfer, .kusdtSwap, .chessMove, .arcadeStamp,
        .paymentNotice, .other,
    ]

    private static let posts = [
        "Kaspa at 10 blocks a second still feels unreal.",
        "Just claimed my .kachat username!",
        "Who's up for a game of chess in Arcade?",
        "gm from the BlockDAG",
    ]

    @MainActor
    static func transaction(id: String) -> ExplorerTransaction {
        if let shown = shownTransactions[id] { return shown }
        var r = Seeded("tx-age-\(id)")
        let isCoinbase = id.hasPrefix("c0")
        return transaction(id: id, at: Date().addingTimeInterval(-TimeInterval(r.int(30...600_000))),
                           mempool: false, forcedKind: isCoinbase ? .coinbase : nil)
    }

    static func transaction(id: String, at time: Date, mempool: Bool, forcedKind: ExplorerTxKind? = nil,
                            involving address: String? = nil, outgoing: Bool = false) -> ExplorerTransaction {
        var r = Seeded("tx-\(id)")
        let kind = forcedKind ?? r.pick(kindWeights)
        let sender = (outgoing ? address : nil) ?? r.address()
        let receiver = (!outgoing ? address : nil) ?? r.address()
        let amount: UInt64
        switch kind {
        case .payment, .other: amount = UInt64(r.int(1...25_000)) * 10_000_000
        case .coinbase: amount = UInt64(r.int(150...400)) * 1_000_000
        case .kusdtTransfer, .kusdtSwap: amount = 150_000_000
        default: amount = 20_000_000
        }
        let spent = kind == .payment || kind == .other
            ? amount + UInt64(r.int(1...900)) * 100_000_000
            : amount + UInt64(r.int(1...6)) * 100_000_000
        let inputs = kind == .coinbase ? [] : [ExplorerIO(index: 0, address: sender, amount: spent)]
        var outputs = [ExplorerIO(index: 0, address: kind.isK && kind != .kusdtTransfer && kind != .kusdtSwap && address == nil ? sender : receiver, amount: amount)]
        if let input = inputs.first, input.amount > amount {
            outputs.append(ExplorerIO(index: 1, address: sender, amount: input.amount - amount - 2_000))
        }
        let decoded: String?
        switch kind {
        case .kapost: decoded = r.pick(posts)
        case .kachatName: decoded = r.pick(["alice.kachat", "satoshi.kachat", "dag.kachat", "kaspa_fan.kachat"])
        case .chessMove: decoded = r.pick(["e2-e4", "Ng1-f3", "O-O", "Qd1xd8+"])
        case .arcadeStamp: decoded = r.pick(["Snake: 412", "2048: 8,960"])
        default: decoded = nil
        }
        return ExplorerTransaction(
            id: id,
            kind: kind,
            time: time,
            blockHash: mempool ? nil : r.hex(64),
            confirmations: mempool ? 0 : max(1, Int(Date().timeIntervalSince(time) * 10)),
            fee: kind == .coinbase ? 0 : UInt64(r.int(2...40)) * 1_000,
            mass: UInt64(r.int(1_600...4_200)),
            inputs: inputs,
            outputs: outputs,
            payloadHex: kind == .payment || kind == .coinbase ? "" : r.hex(r.int(80...320)),
            tokenUnits: kind == .kusdtTransfer || kind == .kusdtSwap ? UInt64(r.int(1...500)) * 1_000_000 + UInt64(r.int(0...99)) * 10_000 : nil,
            decoded: decoded
        )
    }

    @MainActor
    static func address(_ address: String, ownAddress: String?) -> ExplorerAddress {
        var r = Seeded("addr-\(address)")
        let isOwn = address.lowercased() == ownAddress?.lowercased()
        let txs = (0..<r.int(8...18)).map { i -> ExplorerTransaction in
            let id = r.hex(64)
            let age = TimeInterval(i * r.int(3_000...60_000) + r.int(60...900))
            return transaction(id: id, at: Date().addingTimeInterval(-age), mempool: false,
                               forcedKind: r.pick([ExplorerTxKind.payment, .payment, .kachatMessage, .kusdtTransfer, .kapost]),
                               involving: address, outgoing: r.int(0...2) == 0)
        }
        let coins = (0..<r.int(2...6)).map { _ in
            ExplorerCoin(transactionId: r.hex(64), index: r.int(0...2), amount: UInt64(r.int(5...4_000)) * 10_000_000,
                         daaScore: baseDaa - UInt64(r.int(10_000...25_000_000)))
        }
        return ExplorerAddress(
            address: address,
            username: isOwn ? nil : (r.int(0...2) == 0 ? r.pick(["alice", "dag", "satoshi"]) : nil),
            balance: coins.reduce(UInt64(0)) { $0.addingSaturated($1.amount) },
            kusdtUnits: r.int(0...1) == 0 ? UInt64(r.int(1...900)) * 1_000_000 + 500_000 : nil,
            received30d: UInt64(r.int(100...90_000)) * 10_000_000,
            sent30d: UInt64(r.int(50...60_000)) * 10_000_000,
            transactions: txs,
            coins: coins
        )
    }

    @MainActor
    static func remember(_ txs: [ExplorerTransaction]) {
        for tx in txs { shownTransactions[tx.id] = tx }
    }

    /// What a typed search is: an address, a transaction or block id (64 hex), or a username.
    static func search(_ text: String) -> ExplorerSearchMatch {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        if lower.hasPrefix("kaspa:") || lower.hasPrefix("kaspatest:") {
            return .route(.address(lower))
        }
        if lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) {
            // the real search asks the node which one it is; the demo splits them by the last digit
            return lower.last.map { "01234567".contains($0) } == true ? .route(.transaction(lower)) : .route(.block(lower))
        }
        let name = lower.hasSuffix(".kachat") ? String(lower.dropLast(7)) : lower
        if !name.isEmpty, name.count <= 32, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            var r = Seeded("name-\(name)")
            return .route(.address(r.address()))
        }
        return .notFound
    }
}

extension UInt64 {
    /// `self + other`, or the largest value instead of trapping: amounts from an API are summed
    /// with it (audit 2026-11-27 L4).
    func addingSaturated(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
