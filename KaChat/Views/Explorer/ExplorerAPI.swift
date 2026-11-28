import Foundation
import SwiftUI

// The Explorer's data (owner, 2026-11-25: "wire it up to kaspa.stream"): kaspa.stream's REST API,
// the open-source kaspa-rest-server (the same one api.kaspa.org runs), at api.kaspa.stream on
// mainnet and api-tn10.kaspa.stream on testnet-10. Transactions are labelled by what they are in K
// from their payloads, here on the phone. What the API doesn't have stays on demo data and says so:
// K Activity (K's indexer, STATS_INDEXER.md) and the network fees totals.

enum ExplorerAPI {
    static var baseURL: String {
        AppSettings.activeNetwork == .mainnet ? "https://api.kaspa.stream" : "https://api-tn10.kaspa.stream"
    }

    enum Failure: LocalizedError {
        case notFound
        case server(Int)
        case badAnswer

        var errorDescription: String? {
            switch self {
            case .notFound: return AppLocalization.string("Not found on the network.")
            case .server(let code): return String(format: AppLocalization.string("kaspa.stream answered with an error (%d)."), code)
            case .badAnswer: return AppLocalization.string("kaspa.stream sent something K couldn't read.")
            }
        }
    }

    /// Nothing kept between lookups: no cookies, no cache on disk.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// The biggest page K asks for (40 transactions with their inputs) is well under this.
    private static let maxAnswerBytes = 12 * 1024 * 1024

    static func request(_ path: String, _ query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        guard var parts = URLComponents(string: baseURL + path) else { throw Failure.badAnswer }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw Failure.badAnswer }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badAnswer }
        if http.statusCode == 404 { throw Failure.notFound }
        guard (200...299).contains(http.statusCode) else { throw Failure.server(http.statusCode) }
        guard data.count <= maxAnswerBytes else { throw Failure.badAnswer }
        return (data, http)
    }

    static func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await request(path, query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLog.log("[Explorer] %@ didn't decode: %@", path, String(describing: error))
            throw Failure.badAnswer
        }
    }

    // MARK: Answers

    struct BlockDag: Decodable {
        let virtualDaaScore: String
        let difficulty: Double?
    }
    struct BlueScoreAnswer: Decodable { let blueScore: UInt64 }
    /// TH/s.
    struct HashrateAnswer: Decodable { let hashrate: Double }
    /// KAS.
    struct RewardAnswer: Decodable { let blockreward: Double }
    struct HalvingAnswer: Decodable {
        let nextHalvingTimestamp: Double
        let nextHalvingAmount: Double?
    }
    struct SupplyAnswer: Decodable {
        let circulatingSupply: String
        let maxSupply: String
    }
    struct PriceAnswer: Decodable { let price: Double }
    struct FeeEstimate: Decodable {
        struct Bucket: Decodable { let feerate: Double }
        let priorityBucket: Bucket
        let normalBuckets: [Bucket]
    }
    struct HashratePoint: Decodable {
        let timestamp: Double
        let hashrateKh: Double
        enum CodingKeys: String, CodingKey { case timestamp, hashrateKh = "hashrate_kh" }
    }

    /// A u64 as the node's JSON writes it (audit 2026-11-25 C6): proto3 JSON sends 64-bit numbers
    /// as strings, some builds as plain numbers, and a field that is 0 not at all (so every use
    /// is optional).
    struct FlexUInt64: Decodable, Hashable {
        let value: UInt64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self), let parsed = UInt64(text) {
                value = parsed
            } else if let number = try? container.decode(UInt64.self) {
                value = number
            } else if let number = try? container.decode(Double.self) {
                value = ExplorerAPI.clampedUInt64(number)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a u64")
            }
        }
    }

    /// A Double from an API as a UInt64, never trapping: NaN and negatives are 0, anything past
    /// UInt64's range is its largest value (audit 2026-11-25 C11).
    static func clampedUInt64(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < 18_446_744_073_709_551_615.0 else { return .max }
        return UInt64(value.rounded(.down))
    }

    /// KAS from an API as sompi, never trapping.
    static func sompi(fromKAS kas: Double) -> UInt64 {
        clampedUInt64((kas * 100_000_000).rounded())
    }

    /// A block as the node shows it (`/blocks`, `/blocks-from-bluescore`).
    struct NodeBlock: Decodable {
        struct Header: Decodable {
            struct Parents: Decodable { let parentHashes: [String]? }
            let timestamp: FlexUInt64?
            let daaScore: FlexUInt64?
            let blueScore: FlexUInt64?
            let parents: [Parents]?
        }
        struct Verbose: Decodable {
            let hash: String
            let difficulty: Double?
            let transactionIds: [String]?
            let childrenHashes: [String]?
            let mergeSetBluesHashes: [String]?
            let mergeSetRedsHashes: [String]?
            let isChainBlock: Bool?
        }
        let header: Header
        let verboseData: Verbose
        let transactions: [NodeTransaction]?
    }

    /// A transaction inside a node block: outputs carry amounts and addresses, inputs only the
    /// coin they spend.
    struct NodeTransaction: Decodable {
        struct Input: Decodable {
            struct Outpoint: Decodable { let transactionId: String?; let index: Int? }
            let previousOutpoint: Outpoint?
        }
        struct Output: Decodable {
            struct Verbose: Decodable { let scriptPublicKeyAddress: String? }
            let amount: FlexUInt64?
            let verboseData: Verbose?
        }
        struct Verbose: Decodable { let transactionId: String? }
        let inputs: [Input]?
        let outputs: [Output]?
        let subnetworkId: String?
        let payload: String?
        let mass: FlexUInt64?
        let verboseData: Verbose?
    }

    /// A transaction as the indexer keeps it (`/transactions/{id}`, an address's history).
    struct IndexedTransaction: Decodable {
        struct Input: Decodable {
            let index: Int?
            let previous_outpoint_hash: String?
            let previous_outpoint_address: String?
            let previous_outpoint_amount: UInt64?
            let covenant_id: String?
        }
        struct Output: Decodable {
            let index: Int?
            let amount: UInt64?
            let script_public_key_address: String?
            let covenant_id: String?
        }
        let transaction_id: String
        let subnetwork_id: String?
        let mass: String?
        let payload: String?
        let block_hash: [String]?
        let block_time: Double?
        let is_accepted: Bool?
        let accepting_block_hash: String?
        let accepting_block_blue_score: UInt64?
        let inputs: [Input]?
        let outputs: [Output]?
    }

    struct BalanceAnswer: Decodable { let balance: UInt64 }
    struct CountAnswer: Decodable { let total: Int }

    // MARK: Reading what a transaction is

    /// kUSDT's and its pool's covenant ids as hex, made once per network rather than for every
    /// transaction (audit 2026-11-25 E1).
    private static let mainnetKusdt = (pool: Kusdt.deployment(for: .mainnet).poolId.hexString,
                                       token: Kusdt.deployment(for: .mainnet).covenantId.hexString)
    private static let testnetKusdt = (pool: Kusdt.deployment(for: .testnet).poolId.hexString,
                                       token: Kusdt.deployment(for: .testnet).covenantId.hexString)

    /// How much of a payload the lists read for its kind: K's prefixes, an action and a room's
    /// name all fit in its first 128 bytes, so a 100 KB photo isn't decoded to label a row.
    private static let kindPrefixHexLength = 256

    /// A transaction's kind and what K can show of it, read from its payload and the covenants it
    /// touches: K's own protocols (`kchat:1:`, the older `ciph_msg:`, KaPost's legacy `k:1:`),
    /// kUSDT and its pool, and mining rewards. Lists read only the payload's first bytes and
    /// leave `decoded` empty; `full` (a transaction's own page) decodes it all, KaPost's
    /// signature check included (audit 2026-11-25 E1). Safe off the main actor.
    static func classify(payloadHex: String?, subnetwork: String?, covenants: [String],
                         network: NetworkType, full: Bool = false) -> (ExplorerTxKind, String?) {
        if let subnetwork, subnetwork.hasPrefix("01") { return (.coinbase, nil) }
        let ids = network == .mainnet ? mainnetKusdt : testnetKusdt
        if covenants.contains(where: { $0.lowercased() == ids.pool }) { return (.kusdtSwap, nil) }
        if covenants.contains(where: { $0.lowercased() == ids.token }) { return (.kusdtTransfer, nil) }
        guard let payloadHex, !payloadHex.isEmpty else { return (.payment, nil) }
        let text: String
        if full {
            guard let bytes = Data(hexString: payloadHex) else { return (.payment, nil) }
            // K's payloads start with plain text; anything else is some other app's
            guard let decoded = String(data: bytes, encoding: .utf8) else { return (.other, nil) }
            text = decoded
        } else {
            guard let bytes = Data(hexString: String(payloadHex.prefix(kindPrefixHexLength))) else { return (.payment, nil) }
            // cut mid-character at worst: only the prefixes below are compared
            text = String(decoding: bytes, as: UTF8.self)
        }
        var rest: Substring
        if text.hasPrefix("kchat:1:") {
            rest = text.dropFirst("kchat:1:".count)
        } else if text.hasPrefix("ciph_msg:1:") {
            rest = text.dropFirst("ciph_msg:1:".count)
        } else if text.hasPrefix("ciph_msg:") {
            rest = text.dropFirst("ciph_msg:".count)
        } else if text.hasPrefix("k:1:") {
            return (.kapost, full ? KaPostsProtocol.parseChainPayload(text)?.message.trimmedPreview : nil)
        } else {
            return (.other, nil)
        }
        let action = rest.prefix { $0 != ":" }
        rest = rest.dropFirst(action.count + 1)
        switch action {
        case "handshake", "self_stash": return (.handshake, nil)
        case "comm", "gcomm", "gctl", "dm": return (.kachatMessage, nil)
        case "pay", "tip": return (.payment, nil)
        case "name", "offer", "profile": return (.kachatName, nil)
        case "bcast":
            let channel = String(rest.prefix { $0 != ":" })
            let content = String(rest.dropFirst(channel.count + 1))
            switch channel {
            case ChessTournamentCodec.arenaChannel, ChessBotCodec.channel: return (.chessMove, nil)
            case ArcadeStamp.channel: return (.arcadeStamp, nil)
            default: return (.publicChat, full ? "#\(channel): \(content)".trimmedPreview : nil)
            }
        default:
            // post, reply, quote, vote, follow...: KaPost shares the root
            return (.kapost, full ? KaPostsProtocol.parseChainPayload(text)?.message.trimmedPreview : nil)
        }
    }

    /// A transaction a list built, with its payload read in full for its own page.
    static func readFully(_ tx: ExplorerTransaction) -> ExplorerTransaction {
        guard tx.decoded == nil, tx.kind == .kapost || tx.kind == .publicChat else { return tx }
        let (_, decoded) = classify(payloadHex: tx.payloadHex, subnetwork: nil, covenants: [],
                                    network: AppSettings.activeNetwork, full: true)
        return tx.with(decoded: decoded)
    }

    // MARK: Mapping

    /// `full` reads the payload in full (a transaction's own page); lists read only its kind.
    static func transaction(_ tx: IndexedTransaction, virtualBlueScore: UInt64?, network: NetworkType,
                            full: Bool = false) -> ExplorerTransaction {
        let inputs = (tx.inputs ?? []).enumerated().map { offset, input in
            ExplorerIO(index: input.index ?? offset, address: input.previous_outpoint_address ?? "",
                       amount: input.previous_outpoint_amount ?? 0)
        }
        let outputs = (tx.outputs ?? []).enumerated().map { offset, output in
            ExplorerIO(index: output.index ?? offset, address: output.script_public_key_address ?? "",
                       amount: output.amount ?? 0)
        }
        let covenants = (tx.inputs ?? []).compactMap(\.covenant_id) + (tx.outputs ?? []).compactMap(\.covenant_id)
        let (kind, decoded) = classify(payloadHex: tx.payload, subnetwork: tx.subnetwork_id, covenants: covenants,
                                       network: network, full: full)
        // the fee is only known when every input's amount came back
        let resolved = !(tx.inputs ?? []).isEmpty && (tx.inputs ?? []).allSatisfy { $0.previous_outpoint_amount != nil }
        // third-party amounts: summed without trapping (audit 2026-11-27 L4)
        let inSum = inputs.reduce(UInt64(0)) { $0.addingSaturated($1.amount) }
        let outSum = outputs.reduce(UInt64(0)) { $0.addingSaturated($1.amount) }
        let fee: UInt64? = kind == .coinbase ? 0 : (resolved && inSum >= outSum ? inSum - outSum : nil)
        var confirmations = 0
        if tx.is_accepted == true, let accepted = tx.accepting_block_blue_score, let virtual = virtualBlueScore {
            confirmations = Int(clamping: virtual > accepted ? virtual - accepted : 0) + 1
        }
        return ExplorerTransaction(
            id: tx.transaction_id,
            kind: kind,
            time: Date(timeIntervalSince1970: (tx.block_time ?? Date().timeIntervalSince1970 * 1000) / 1000),
            blockHash: tx.block_hash?.first,
            confirmations: confirmations,
            fee: fee,
            mass: UInt64(tx.mass ?? "") ?? 0,
            inputs: inputs,
            outputs: outputs,
            payloadHex: tx.payload ?? "",
            tokenUnits: nil,
            decoded: decoded,
            isAccepted: tx.is_accepted
        )
    }

    static func transaction(_ tx: NodeTransaction, at offset: Int, in block: NodeBlock,
                            network: NetworkType) -> ExplorerTransaction {
        let (kind, decoded) = classify(payloadHex: tx.payload, subnetwork: tx.subnetworkId, covenants: [], network: network)
        let ids = block.verboseData.transactionIds ?? []
        return ExplorerTransaction(
            id: tx.verboseData?.transactionId ?? (offset < ids.count ? ids[offset] : ""),
            kind: kind,
            time: Date(timeIntervalSince1970: Double(block.header.timestamp?.value ?? 0) / 1000),
            blockHash: block.verboseData.hash,
            confirmations: 0,
            fee: kind == .coinbase ? 0 : nil,
            mass: tx.mass?.value ?? 0,
            inputs: (tx.inputs ?? []).indices.map { ExplorerIO(index: $0, address: "", amount: 0) },
            outputs: (tx.outputs ?? []).enumerated().map {
                ExplorerIO(index: $0, address: $1.verboseData?.scriptPublicKeyAddress ?? "", amount: $1.amount?.value ?? 0)
            },
            payloadHex: tx.payload ?? "",
            tokenUnits: nil,
            decoded: decoded
        )
    }

    static func block(_ block: NodeBlock, network: NetworkType) -> ExplorerBlock {
        let v = block.verboseData
        return ExplorerBlock(
            id: v.hash,
            blueScore: block.header.blueScore?.value ?? 0,
            daaScore: block.header.daaScore?.value ?? 0,
            time: Date(timeIntervalSince1970: Double(block.header.timestamp?.value ?? 0) / 1000),
            isChainBlock: v.isChainBlock ?? false,
            difficulty: v.difficulty ?? 0,
            parents: block.header.parents?.first?.parentHashes ?? [],
            children: v.childrenHashes ?? [],
            mergeSetBlues: v.mergeSetBluesHashes?.count ?? 0,
            mergeSetReds: v.mergeSetRedsHashes?.count ?? 0,
            transactionIds: v.transactionIds ?? [],
            transactions: (block.transactions ?? []).enumerated()
                .map { transaction($1, at: $0, in: block, network: network) }
                .filter { !$0.id.isEmpty }
        )
    }

    // MARK: Pages

    static func transaction(id: String) async throws -> ExplorerTransaction {
        // seconds old: kaspa.stream hasn't indexed it yet, but the node already sent it
        do { return try await indexedTransaction(id: id) } catch Failure.notFound {
            if let live = await ExplorerLive.shared.transaction(id: id) { return readFully(live) }
            throw Failure.notFound
        }
    }

    private static func indexedTransaction(id: String) async throws -> ExplorerTransaction {
        let network = AppSettings.activeNetwork
        let tx = try await get(IndexedTransaction.self, "/transactions/\(id)", [
            URLQueryItem(name: "inputs", value: "true"),
            URLQueryItem(name: "outputs", value: "true"),
            URLQueryItem(name: "resolve_previous_outpoints", value: "light"),
        ])
        let blue = await ExplorerLive.shared.currentBlueScore()
        return transaction(tx, virtualBlueScore: blue, network: network, full: true)
    }

    static func block(hash: String) async throws -> ExplorerBlock {
        let network = AppSettings.activeNetwork
        do {
            return block(try await get(NodeBlock.self, "/blocks/\(hash)", [URLQueryItem(name: "includeTransactions", value: "true")]),
                         network: network)
        } catch Failure.notFound {
            if let live = await ExplorerLive.shared.block(hash: hash) { return live }
            throw Failure.notFound
        }
    }

    /// An address page's first page of history: small, since every transaction comes with its
    /// payload (kaspa.stream can leave payloads out but not cut them short, and a row's kind
    /// needs the payload's first bytes; audit 2026-11-25 E4). Load More asks for more at a time.
    static let firstAddressPage = 20
    static let laterAddressPage = 40

    /// One page of an address's history, newest first, and where the next page starts.
    static func addressPage(_ address: String, before: Int64?, limit: Int = laterAddressPage) async throws -> ([ExplorerTransaction], Int64?) {
        let network = AppSettings.activeNetwork
        var query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        let (data, http) = try await request("/addresses/\(address)/full-transactions-page", query)
        guard let txs = try? JSONDecoder().decode([IndexedTransaction].self, from: data) else { throw Failure.badAnswer }
        let blue = await ExplorerLive.shared.currentBlueScore()
        let next = (http.value(forHTTPHeaderField: "x-next-page-before")).flatMap { Int64($0) }
        return (txs.map { transaction($0, virtualBlueScore: blue, network: network) }, txs.count < limit ? nil : next)
    }

    static func address(_ address: String) async throws -> ExplorerAddress {
        async let balance = get(BalanceAnswer.self, "/addresses/\(address)/balance")
        async let count = try? get(CountAnswer.self, "/addresses/\(address)/transactions-count")
        async let page = addressPage(address, before: nil, limit: firstAddressPage)
        async let kusdt = try? KusdtBalances.fetch(address: address).units
        async let identity = KachatNamesRegistry.shared.refreshIdentity(address: address)
        let (txs, next) = try await page
        // received and sent over the last 30 days, from the history page (complete when it
        // reaches back that far)
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        var received: UInt64 = 0, sent: UInt64 = 0
        // what the network accepted only: an unaccepted copy moved nothing
        for tx in txs where tx.time >= monthAgo && !tx.isNotAccepted {
            let net = tx.net(for: address)
            if net.isIncoming { received = received.addingSaturated(net.amount) } else { sent = sent.addingSaturated(net.amount) }
        }
        let coversMonth = next == nil || (txs.last.map { $0.time < monthAgo } ?? true)
        return ExplorerAddress(
            address: address,
            username: (await identity)?.label.map(KachatNameLabel.display),
            balance: try await balance.balance,
            kusdtUnits: await kusdt,
            received30d: received,
            sent30d: sent,
            summaryCoversMonth: coversMonth,
            transactionCount: (await count)?.total,
            transactions: txs,
            nextPageBefore: next,
            coins: []
        )
    }

    /// What a 64-character id is, with light calls (no inputs, no block transactions); the node's
    /// copy when kaspa.stream hasn't indexed it yet. Throws when kaspa.stream couldn't be asked
    /// and nothing was found, so "not found" means not found (audit 2026-11-25 C11).
    enum IdMatch: Equatable {
        case transaction(ExplorerTxKind)
        case block
        case notFound
    }

    static func identify(_ id: String) async throws -> IdMatch {
        let network = AppSettings.activeNetwork
        var unreachable: Error?
        do {
            let tx = try await get(IndexedTransaction.self, "/transactions/\(id)", [
                URLQueryItem(name: "inputs", value: "false"), URLQueryItem(name: "outputs", value: "true"),
            ])
            let covenants = (tx.outputs ?? []).compactMap(\.covenant_id)
            return .transaction(classify(payloadHex: tx.payload, subnetwork: tx.subnetwork_id,
                                         covenants: covenants, network: network).0)
        } catch Failure.notFound {
        } catch {
            unreachable = error
        }
        if let live = await ExplorerLive.shared.transaction(id: id) { return .transaction(live.kind) }
        do {
            _ = try await request("/blocks/\(id)", [URLQueryItem(name: "includeTransactions", value: "false")])
            return .block
        } catch Failure.notFound {
        } catch {
            unreachable = unreachable ?? error
        }
        if await ExplorerLive.shared.block(hash: id) != nil { return .block }
        if let unreachable { throw unreachable }
        return .notFound
    }

    /// What a search finds: an address, a transaction or block id, or a .kachat username.
    static func search(_ raw: String) async -> ExplorerSearchMatch {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("kaspa:") || lower.hasPrefix("kaspatest:") {
            return KaspaAddress.isValid(lower) ? .route(.address(lower)) : .notFound
        }
        if lower.count == 64, lower.allSatisfy(\.isHexDigit) {
            switch try? await identify(lower) {
            case .transaction: return .route(.transaction(lower))
            case .block: return .route(.block(lower))
            case .notFound, nil: return .notFound
            }
        }
        if let address = await NameServicesClient.shared.resolveEverywhere(text).first?.address {
            return .route(.address(address))
        }
        return .notFound
    }

    // MARK: History for the charts

    /// The network's hashrate over `period`, oldest first, in H/s.
    static func hashrateHistory(_ period: ExplorerKPeriod) async throws -> [ExplorerChartPoint] {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        func month(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", c.year!, c.month!)
        }
        var raw: [HashratePoint] = []
        let since: Date
        switch period {
        case .day:
            since = now.addingTimeInterval(-86_400)
            for d in Set([day(since), day(now)]) {
                raw += (try? await get([HashratePoint].self, "/info/hashrate/history/\(d)")) ?? []
            }
        case .week, .month:
            since = now.addingTimeInterval(period == .week ? -7 * 86_400 : -30 * 86_400)
            for m in Set([month(since), month(now)]) {
                raw += (try? await get([HashratePoint].self, "/info/hashrate/history/\(m)")) ?? []
            }
        case .allTime:
            since = .distantPast
            raw = try await get([HashratePoint].self, "/info/hashrate/history", [URLQueryItem(name: "resolution", value: "7d")])
        }
        let points = raw
            .map { ExplorerChartPoint(date: Date(timeIntervalSince1970: $0.timestamp / 1000), value: $0.hashrateKh * 1000) }
            .filter { $0.date >= since }
            .sorted { $0.date < $1.date }
        guard !points.isEmpty else { throw Failure.notFound }
        return downsample(points, to: 240)
    }

    /// KAS's price over `period`, from the price feed Portfolio uses (CoinGecko, then Gate.io).
    static func priceHistory(_ period: ExplorerKPeriod) async -> [ExplorerChartPoint] {
        let days: Int
        switch period {
        case .day: days = 1
        case .week: days = 7
        case .month: days = 30
        case .allTime: days = 0
        }
        let history = await CoinGeckoService.shared.getPriceHistory(days: days, currency: .usDollar)
        return downsample(history.map { ExplorerChartPoint(date: $0.timestamp, value: $0.value) }.sorted { $0.date < $1.date }, to: 240)
    }

    static func downsample(_ points: [ExplorerChartPoint], to limit: Int) -> [ExplorerChartPoint] {
        guard points.count > limit else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }
}

private extension String {
    /// A payload's text as a one-paragraph preview.
    var trimmedPreview: String? {
        let flat = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        return flat.count > 280 ? String(flat.prefix(280)) + "…" : flat
    }
}

extension ExplorerNetworkStats {
    /// Before kaspa.stream's first answer: drawn as placeholders.
    static let empty = ExplorerNetworkStats(
        blocksPerSecond: 0, hashrate: 0, mempoolSize: 0, normalFeerate: 0,
        priorityFeerate: 0, averageFee24h: 0, circulatingSupply: 0, maxSupply: 1, priceUSD: 0,
        nodeVersion: "", blockReward: 0, nextRewardDrop: Date()
    )
}

// MARK: - Live network

/// The Explorer home's live numbers and newest blocks while the Explorer shows: blocks as K's own
/// node announces them (kaspa.stream's API has no live feed), the network's numbers from
/// kaspa.stream every minute, the mempool from the node. Blocks land in a buffer and reach the
/// screen once a second, not ten times. Between blocks the DAA score runs on at the measured rate.
@MainActor
final class ExplorerLive: ObservableObject {
    static let shared = ExplorerLive()

    @Published private(set) var stats: ExplorerNetworkStats?
    @Published private(set) var latestBlocks: [ExplorerBlock] = []
    @Published private(set) var latestTransactions: [ExplorerTransaction] = []
    /// kaspa.stream couldn't be reached and nothing is known yet.
    @Published private(set) var failed = false

    /// The newest blocks the list keeps.
    private static let keptBlocks = 15
    /// At most this many blocks wait for the next flush, the newest (audit 2026-11-25 E2).
    private static let pendingCap = 30

    private var loop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var handlerId: UUID?
    private var pending: [ExplorerBlockDetail] = []
    private var daaAnchor: (score: UInt64, at: Date)?
    private var blocksPerSecond: Double = 10
    /// Where the blocks-per-second measurement started: the DAA score rises about one per block.
    private var rateStart: (score: UInt64, at: Date)?
    private var blueScore: UInt64?
    /// When `blueScore` was last known good.
    private var blueScoreAt = Date.distantPast
    private var difficulty: Double = 0
    private var slow: (hashrate: Double, reward: Double, nextDrop: Date, circulating: UInt64, max: UInt64,
                       price: Double, feerate: Double, priority: Double)?
    private var slowAt = Date.distantPast
    private var restAt = Date.distantPast
    private var mempool = 0
    /// The network everything here belongs to (audit 2026-11-25 C5): a switch empties it all.
    private var network: NetworkType?
    /// Bumped by every reset, so an answer that was on its way for the old network is dropped.
    private var generation = 0

    func start() {
        resetIfNetworkChanged()
        guard loop == nil else { return }
        ExplorerBlockDetail.wanted = true
        // called off the main actor; the block is built later, and only if the list keeps it
        handlerId = NodePoolService.shared.addBlockHandler { block in
            guard let detail = block.explorer else { return }
            Task { @MainActor in ExplorerLive.shared.receive(detail) }
        }
        Task { await NodePoolService.shared.subscribeBlockAdded(client: "explorer") }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.flush()
                // in its own task, so a slow kaspa.stream never holds up the once-a-second flush
                if tick % 10 == 0, self.refreshTask == nil {
                    self.refreshTask = Task { [weak self] in
                        await self?.refresh()
                        // a cancelled one was already let go by stop()
                        if !Task.isCancelled { self?.refreshTask = nil }
                    }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        refreshTask?.cancel()
        refreshTask = nil
        ExplorerBlockDetail.wanted = false
        rateStart = nil
        if let handlerId { BlockScanRegistry.shared.remove(handlerId) }
        handlerId = nil
        pending = []
        Task { await NodePoolService.shared.unsubscribeBlockAdded(client: "explorer") }
    }

    /// Empties everything when the network isn't the one it was gathered on: the scores only go
    /// up and the lists sort by DAA score, so the old network's would otherwise stay on top.
    private func resetIfNetworkChanged() {
        let current = AppSettings.activeNetwork
        let previous = self.network
        self.network = current
        guard let previous, previous != current else { return }
        generation += 1
        stats = nil
        latestBlocks = []
        latestTransactions = []
        failed = false
        pending = []
        daaAnchor = nil
        blocksPerSecond = 10
        rateStart = nil
        blueScore = nil
        blueScoreAt = .distantPast
        difficulty = 0
        slow = nil
        slowAt = .distantPast
        restAt = .distantPast
        mempool = 0
        ExplorerKStats.shared.resetIfNetworkChanged()
    }

    private func receive(_ detail: ExplorerBlockDetail) {
        pending.append(detail)
        guard pending.count > Self.pendingCap else { return }
        pending.sort { $0.daaScore > $1.daaScore }
        pending.removeLast(pending.count - Self.pendingCap)
    }

    /// The DAA score now, run on from the newest block at the measured rate.
    func daaScore(at now: Date) -> UInt64 {
        guard let anchor = daaAnchor else { return 0 }
        return anchor.score + UInt64(max(0, min(now.timeIntervalSince(anchor.at), 5)) * blocksPerSecond)
    }

    /// For confirmations: the virtual chain's blue score, asked for again when it's more than
    /// ten seconds old (a detail page opened later would otherwise count from a stale one).
    func currentBlueScore() async -> UInt64? {
        resetIfNetworkChanged()
        if let blueScore, Date().timeIntervalSince(blueScoreAt) < 10 { return blueScore }
        let started = self.generation
        if let fresh = (try? await ExplorerAPI.get(ExplorerAPI.BlueScoreAnswer.self, "/info/virtual-chain-blue-score"))?.blueScore,
           started == self.generation {
            blueScore = max(blueScore ?? 0, fresh)
            blueScoreAt = Date()
        }
        return blueScore
    }

    /// A block or transaction the node sent while the Explorer was open.
    func block(hash: String) -> ExplorerBlock? { latestBlocks.first { $0.id == hash } }
    func transaction(id: String) -> ExplorerTransaction? {
        latestTransactions.first { $0.id == id } ?? latestBlocks.lazy.flatMap(\.transactions).first { $0.id == id }
    }

    /// The blocks the node sent since the last second, onto the lists. Only blocks the list will
    /// keep are built, off the main actor (audit 2026-11-25 E1).
    private func flush() async {
        resetIfNetworkChanged()
        guard !pending.isEmpty else { return }
        let fresh = pending
        pending = []
        let now = Date()
        if let newest = fresh.max(by: { $0.daaScore < $1.daaScore }),
           newest.daaScore >= daaAnchor?.score ?? 0 {
            daaAnchor = (newest.daaScore, now)
            if let start = rateStart, newest.daaScore > start.score, now.timeIntervalSince(start.at) >= 10 {
                blocksPerSecond = Double(newest.daaScore - start.score) / now.timeIntervalSince(start.at)
                rateStart = (newest.daaScore, now)
            } else if rateStart == nil {
                rateStart = (newest.daaScore, now)
            }
            if newest.blueScore >= blueScore ?? 0 {
                blueScore = newest.blueScore
                blueScoreAt = now
            }
            difficulty = newest.difficulty
        }
        var seen = Set(latestBlocks.map(\.id))
        // below the 15th block shown: it would fall off the list at once
        let lowestShown = latestBlocks.count >= Self.keptBlocks ? latestBlocks.last?.daaScore ?? 0 : 0
        let kept = Array(fresh
            .filter { seen.insert($0.hash).inserted && $0.daaScore >= lowestShown }
            .sorted { $0.daaScore > $1.daaScore }
            .prefix(Self.keptBlocks))
        guard !kept.isEmpty else { publishStats(); return }
        let network = self.network ?? AppSettings.activeNetwork, started = self.generation
        let blocks = await Task.detached(priority: .utility) {
            kept.map { ExplorerLive.block($0, network: network) }
        }.value
        guard started == self.generation else { return }
        let shown = Set(latestBlocks.map(\.id))
        let added = blocks.filter { !shown.contains($0.id) }
        latestBlocks = Array((added + latestBlocks).sorted { $0.daaScore > $1.daaScore }.prefix(Self.keptBlocks))
        mergeTransactions(added.flatMap(\.transactions).filter { $0.kind != .coinbase })
        publishStats()
    }

    /// Runs off the main actor: reads only the payload's first bytes for each kind.
    nonisolated private static func block(_ d: ExplorerBlockDetail, network: NetworkType) -> ExplorerBlock {
        let time = Date(timeIntervalSince1970: Double(d.timestamp) / 1000)
        let txs = d.transactions.map { tx -> ExplorerTransaction in
            let (kind, decoded) = ExplorerAPI.classify(payloadHex: tx.payloadHex, subnetwork: tx.subnetwork,
                                                      covenants: tx.outputs.map(\.covenantId).filter { !$0.isEmpty },
                                                      network: network)
            return ExplorerTransaction(
                id: tx.id, kind: kind, time: time, blockHash: d.hash, confirmations: 0,
                fee: kind == .coinbase ? 0 : nil, mass: tx.mass,
                inputs: (0..<tx.inputCount).map { ExplorerIO(index: $0, address: "", amount: 0) },
                outputs: tx.outputs.enumerated().map { ExplorerIO(index: $0, address: $1.address, amount: $1.amount) },
                payloadHex: tx.payloadHex, tokenUnits: nil, decoded: decoded
            )
        }
        return ExplorerBlock(
            id: d.hash, blueScore: d.blueScore, daaScore: d.daaScore, time: time, isChainBlock: d.isChainBlock,
            difficulty: d.difficulty, parents: d.parents, children: d.children, mergeSetBlues: d.mergeSetBlues,
            mergeSetReds: d.mergeSetReds, transactionIds: d.transactionIds, transactions: txs
        )
    }

    /// kaspa.stream's numbers (every 10 s for the scores while no block has come, every minute for
    /// the rest) and the node's mempool.
    private func refresh() async {
        resetIfNetworkChanged()
        let started = self.generation
        let now = Date()
        if latestBlocks.isEmpty || now.timeIntervalSince(restAt) > 60 {
            let dag = try? await ExplorerAPI.get(ExplorerAPI.BlockDag.self, "/info/blockdag")
            let blue = try? await ExplorerAPI.get(ExplorerAPI.BlueScoreAnswer.self, "/info/virtual-chain-blue-score")
            guard started == self.generation, !Task.isCancelled else { return }
            if let dag, let score = UInt64(dag.virtualDaaScore), score > daaAnchor?.score ?? 0 {
                daaAnchor = (score, Date())
                difficulty = dag.difficulty ?? difficulty
            }
            if let blue {
                blueScore = max(blueScore ?? 0, blue.blueScore)
                blueScoreAt = Date()
            }
            restAt = now
        }
        if slow == nil || now.timeIntervalSince(slowAt) > 60 { await refreshSlow() }
        guard started == self.generation, !Task.isCancelled else { return }
        await ExplorerKStats.shared.refresh()
        let info = try? await NodePoolService.shared.getInfo()
        guard started == self.generation, !Task.isCancelled else { return }
        if let info { mempool = Int(clamping: info.mempoolSize) }
        failed = slow == nil
        publishStats()
    }

    private func refreshSlow() async {
        let started = self.generation
        async let hashrate = ExplorerAPI.get(ExplorerAPI.HashrateAnswer.self, "/info/hashrate", [URLQueryItem(name: "stringOnly", value: "false")])
        async let reward = ExplorerAPI.get(ExplorerAPI.RewardAnswer.self, "/info/blockreward", [URLQueryItem(name: "stringOnly", value: "false")])
        async let halving = ExplorerAPI.get(ExplorerAPI.HalvingAnswer.self, "/info/halving")
        async let supply = ExplorerAPI.get(ExplorerAPI.SupplyAnswer.self, "/info/coinsupply")
        async let price = ExplorerAPI.get(ExplorerAPI.PriceAnswer.self, "/info/price", [URLQueryItem(name: "stringOnly", value: "false")])
        async let fees = ExplorerAPI.get(ExplorerAPI.FeeEstimate.self, "/info/fee-estimate")
        guard let h = try? await hashrate, let r = try? await reward, let s = try? await supply,
              let p = try? await price else {
            AppLog.log("[Explorer] kaspa.stream's network numbers didn't load")
            return
        }
        let next = (try? await halving).map { Date(timeIntervalSince1970: $0.nextHalvingTimestamp) } ?? Date()
        let f = try? await fees
        guard started == self.generation else { return }
        slow = (h.hashrate * 1e12, r.blockreward, next, UInt64(s.circulatingSupply) ?? 0, UInt64(s.maxSupply) ?? 0,
                p.price, f?.normalBuckets.first?.feerate ?? 0, f?.priorityBucket.feerate ?? 0)
        slowAt = Date()
    }

    /// The fee tile's stand-in until a real average is served: the demo's number in Debug builds,
    /// nothing in Release.
    private static var demoAverageFee: UInt64 {
        #if DEBUG
        return ExplorerDemo.stats(at: Date()).averageFee24h
        #else
        return 0
        #endif
    }

    private func publishStats() {
        // still waits for the first block, as when the DAA score was part of it
        guard let slow, daaAnchor != nil else { return }
        let next = ExplorerNetworkStats(
            blocksPerSecond: blocksPerSecond,
            hashrate: slow.hashrate,
            mempoolSize: mempool,
            normalFeerate: slow.feerate,
            priorityFeerate: slow.priority,
            // not in kaspa.stream's API: the demo's in Debug builds, 0 (shown as "–") in Release
            averageFee24h: Self.demoAverageFee,
            circulatingSupply: slow.circulating,
            maxSupply: slow.max,
            priceUSD: slow.price,
            nodeVersion: "",
            blockReward: ExplorerAPI.sompi(fromKAS: slow.reward),
            nextRewardDrop: slow.nextDrop
        )
        if next != stats { stats = next }
    }

    /// The newest transactions seen, newest first, at most 300.
    private func mergeTransactions(_ fresh: [ExplorerTransaction]) {
        guard !fresh.isEmpty else { return }
        var seen = Set(latestTransactions.map(\.id))
        var merged = latestTransactions
        for tx in fresh where seen.insert(tx.id).inserted { merged.append(tx) }
        merged.sort { $0.time > $1.time }
        latestTransactions = Array(merged.prefix(300))
    }
}

// MARK: - K's own numbers (K's indexer)

/// K Activity from K's indexer, and the network's fees from Kaspalytics (owner, 2026-11-25: keep
/// what the indexer tracks small and use everything else). `GET /stats` counts K's protocols for
/// the last 24 hours, 7 days and all time; `GET /stats/activity?period=` adds the window before and
/// the bars (K-Digital-Freedom-Indexer docs/EXPLORER_STATS.md), used as soon as it's served.
/// Whatever isn't served is left off the card.
@MainActor
final class ExplorerKStats: ObservableObject {
    static let shared = ExplorerKStats()

    /// Each period's numbers, as last fetched.
    @Published private(set) var activity: [ExplorerKPeriod: ExplorerKActivity] = [:]
    /// K Activity's periods: 24 Hours, 7 Days and All Time (owner, 2026-11-25: no 30 Days).
    nonisolated static let cardPeriods: [ExplorerKPeriod] = [.day, .week, .allTime]
    @Published private(set) var periods: [ExplorerKPeriod] = ExplorerKStats.cardPeriods

    private var fetchedAt = Date.distantPast
    /// `/stats/activity` answered 404: not served by this indexer, so not asked again this
    /// session. Any other failure only waits an hour (`richRetryAt`; audit 2026-11-25 C11).
    private var richUnavailable = false
    private var richRetryAt = Date.distantPast
    /// The network these numbers are for (audit 2026-11-25 C5).
    private var network: NetworkType?
    private var generation = 0

    /// `/stats` keys -> what the card calls them. `selfStash` and `groupUpdates` are machinery
    /// (a handshake's saved copy, group control), not left out by accident.
    nonisolated static let categories: [(key: String, kind: ExplorerTxKind)] = [
        ("messages", .kachatMessage), ("groupMessages", .kachatMessage), ("handshakes", .handshake),
        ("payments", .payment), ("paymentNotices", .paymentNotice), ("kaposts", .kapost),
        ("kapostActions", .kapost), ("publicChats", .publicChat), ("chessMoves", .chessMove),
        ("kachatNames", .kachatName), ("kusdtTransfers", .kusdtTransfer), ("kusdtSwaps", .kusdtSwap),
        ("arcadeScores", .arcadeStamp),
    ]

    private static var base: String? {
        var url = AppSettings.load().indexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url.isEmpty ? nil : url
    }

    /// Kaspalytics' daily fees (owner, 2026-11-25): every day since October 2023, all of Kaspa,
    /// in KAS. Its undocumented chart API (`kaspalytics.com/api/charts/...`), refreshed hourly on
    /// their side; mainnet only. Used for 7 Days, 30 Days and All Time and for the tile when K's
    /// indexer doesn't serve fees, since that only counts from its deploy on.
    @Published private(set) var dailyFees: [ExplorerChartPoint] = []
    /// Kaspalytics' average fee per transaction on the last full day, in sompi.
    @Published private(set) var lastDayAverageFee: UInt64?
    private var kaspalyticsAt = Date.distantPast

    /// Where a fee number came from, so the screen can say so.
    enum FeeSource { case indexer, kaspalytics, demo }

    /// The fees chart's points for `period` (7 Days, 30 Days, All Time), all from Kaspalytics: K's
    /// indexer doesn't count fees (owner, 2026-11-25: keep its work small).
    func feeSeries(_ period: ExplorerKPeriod) -> (points: [ExplorerChartPoint], source: FeeSource)? {
        guard !dailyFees.isEmpty else { return nil }
        switch period {
        case .day: return nil
        case .week: return (Array(dailyFees.suffix(7)), .kaspalytics)
        case .month: return (Array(dailyFees.suffix(30)), .kaspalytics)
        case .allTime: return (Self.monthly(dailyFees), .kaspalytics)
        }
    }

    /// The tile's average fee per transaction: Kaspalytics' last full day.
    var averageFee: (sompi: UInt64, source: FeeSource)? {
        lastDayAverageFee.map { ($0, .kaspalytics) }
    }

    /// At most once a minute (Kaspalytics at most once an hour).
    func refresh() async {
        resetIfNetworkChanged()
        guard Date().timeIntervalSince(fetchedAt) > 60 else { return }
        fetchedAt = Date()
        if AppSettings.activeNetwork == .mainnet, Date().timeIntervalSince(kaspalyticsAt) > 3600 {
            await loadKaspalytics()
        }
        guard let base = Self.base else { return }
        await loadActivity(base)
    }

    /// Forgets everything fetched for another network: mainnet's fees and K Activity must not
    /// show on testnet, nor the other way round.
    func resetIfNetworkChanged() {
        let current = AppSettings.activeNetwork
        let previous = network
        network = current
        guard let previous, previous != current else { return }
        generation += 1
        activity = [:]
        periods = Self.cardPeriods
        fetchedAt = .distantPast
        richUnavailable = false
        richRetryAt = .distantPast
        dailyFees = []
        lastDayAverageFee = nil
        kaspalyticsAt = .distantPast
    }

    // MARK: Kaspalytics

    private struct ChartAnswer: Decodable {
        struct Dataset: Decodable { let label: String; let data: [Double?] }
        let labels: [String]
        let datasets: [Dataset]
    }

    /// Kaspalytics' labels: ISO 8601 with or without fractional seconds, or a plain day.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoDay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static func kaspalyticsDate(_ label: String) -> Date? {
        isoFractional.date(from: label) ?? isoPlain.date(from: label) ?? isoDay.date(from: label)
    }

    private func loadKaspalytics() async {
        let started = generation
        let base = "https://www.kaspalytics.com/api/charts/transactions/accepted/fees"
        guard let total = await Self.fetch(ChartAnswer.self, "\(base)/total", maxBytes: 4 * 1024 * 1024).value,
              let fees = total.datasets.first(where: { $0.label == "Fees" }) else { return }
        let points = zip(total.labels, fees.data).compactMap { label, value -> ExplorerChartPoint? in
            guard let value, let date = Self.kaspalyticsDate(label) else { return nil }
            return ExplorerChartPoint(date: date, value: value)
        }
        guard !points.isEmpty, started == generation else { return }
        dailyFees = points.sorted { $0.date < $1.date }
        if let average = await Self.fetch(ChartAnswer.self, "\(base)/average", maxBytes: 4 * 1024 * 1024).value,
           let values = average.datasets.first(where: { $0.label == "Fee" })?.data,
           let last = values.last(where: { $0 != nil }) ?? nil, started == generation {
            lastDayAverageFee = ExplorerAPI.sompi(fromKAS: last)
        }
        kaspalyticsAt = Date()
    }

    /// Daily totals summed into calendar months (UTC), for All Time.
    private static func monthly(_ daily: [ExplorerChartPoint]) -> [ExplorerChartPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var sums: [Date: Double] = [:]
        for point in daily {
            let month = calendar.dateInterval(of: .month, for: point.date)?.start ?? point.date
            sums[month, default: 0] += point.value
        }
        return sums.map { ExplorerChartPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    // MARK: Activity

    private struct Counts: Decodable {
        let total: Int?
        let last24h: Int?
        let last7d: Int?
        let last30d: Int?
    }
    private struct StatsAnswer: Decodable { let categories: [String: Counts] }

    /// `/stats/activity?period=` (proposed): one period, complete.
    private struct ActivityAnswer: Decodable {
        struct Bar: Decodable { let t: Double; let count: Int }
        let categories: [String: Int]
        let previous: [String: Int]?
        let series: [Bar]?
    }

    private static func kinds(_ values: [String: Int]) -> [ExplorerTxKind: Int] {
        var counts: [ExplorerTxKind: Int] = [:]
        for (key, kind) in categories {
            guard let value = values[key] else { continue }
            // a server's numbers never trap (audit 2026-11-27 L4)
            let (sum, overflow) = counts[kind, default: 0].addingReportingOverflow(max(0, value))
            counts[kind] = overflow ? .max : sum
        }
        return counts
    }

    private func loadActivity(_ base: String) async {
        let started = generation
        if !richUnavailable, Date() >= richRetryAt {
            var rich: [ExplorerKPeriod: ExplorerKActivity] = [:]
            var notServed = false
            for period in Self.cardPeriods {
                let answer = await Self.fetch(ActivityAnswer.self, "\(base)/stats/activity?period=\(Self.name(period))")
                guard let value = answer.value else {
                    notServed = answer.status == 404
                    break
                }
                rich[period] = ExplorerKActivity(
                    period: period,
                    counts: Self.kinds(value.categories),
                    bars: value.series?.sorted { $0.t < $1.t }.map(\.count),
                    previousTotal: value.previous.map { previous in
                        Self.kinds(previous).values.reduce(0) { sum, count in
                            sum.addingReportingOverflow(count).overflow ? .max : sum + count
                        }
                    },
                )
            }
            guard started == generation else { return }
            if rich.count == Self.cardPeriods.count {
                activity = rich
                periods = Self.cardPeriods
                return
            }
            // not served (yet): /stats; asked again next session after a 404, else in an hour
            if notServed { richUnavailable = true } else { richRetryAt = Date().addingTimeInterval(3600) }
        }
        guard let stats = await Self.fetch(StatsAnswer.self, "\(base)/stats").value, started == generation else { return }
        func window(_ pick: (Counts) -> Int?) -> [ExplorerTxKind: Int]? {
            let values = stats.categories.compactMapValues(pick)
            return values.isEmpty ? nil : Self.kinds(values)
        }
        var next: [ExplorerKPeriod: ExplorerKActivity] = [:]
        if let day = window(\.last24h) { next[.day] = ExplorerKActivity(period: .day, counts: day) }
        if let week = window(\.last7d) { next[.week] = ExplorerKActivity(period: .week, counts: week) }
        if let all = window(\.total) { next[.allTime] = ExplorerKActivity(period: .allTime, counts: all) }
        guard !next.isEmpty else { return }
        activity = next
        periods = Self.cardPeriods.filter { next[$0] != nil }
    }

    private static func name(_ period: ExplorerKPeriod) -> String {
        switch period {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .allTime: return "all"
        }
    }

    /// The answer, or nil with the HTTP status when there was one (nil status: no answer at all).
    private static func fetch<T: Decodable>(_ type: T.Type, _ url: String,
                                            maxBytes: Int = 2 * 1024 * 1024) async -> (value: T?, status: Int?) {
        guard let url = URL(string: url) else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, nil) }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard let status, (200...299).contains(status), data.count <= maxBytes else { return (nil, status) }
        return (try? JSONDecoder().decode(T.self, from: data), status)
    }
}
