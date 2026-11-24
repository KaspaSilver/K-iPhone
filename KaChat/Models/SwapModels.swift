import Foundation

/// One side of a swap pair — ChangeNOW addresses currencies by (ticker, network) since some
/// tickers exist on more than one chain. Mirrors Android's SwapModels.kt. kUSDT is the one coin
/// that isn't ChangeNOW's: it goes through Trestly (`isTrestly`).
struct SwapCoin: Equatable, Hashable {
    let ticker: String
    let network: String
    let displayName: String

    /// Kaspa itself — always one side of every swap this app can do. Verified against
    /// ChangeNOW's live /v2/exchange/currencies list: ticker "kas", network "kas".
    static let kas = SwapCoin(ticker: "kas", network: "kas", displayName: "Kaspa")

    /// kUSDT on Kaspa: swapped natively through Trestly's pool (`TrestlyTrade`), never through
    /// ChangeNOW (which doesn't list it). First in the coin picker.
    static let kusdt = SwapCoin(ticker: "kusdt", network: "kaspa-trestly", displayName: "kUSDT (Kaspa)")

    /// Swapped through Trestly's pool on Kaspa rather than ChangeNOW.
    var isTrestly: Bool { self == .kusdt }

    /// A coin whose addresses are shared (ChangeNOW's own deposit address, an exchange's) and
    /// tell payments apart by a tag sent with them: XRP's destination tag. ChangeNOW's deposit
    /// for it comes with `payinExtraId`, which must go with the payment, and a payout to an
    /// exchange may need one (`extraId`) (audit 2026-11-24 #1).
    var needsMemo: Bool { self == .xrp }

    /// A payout tag K can send for this coin: XRP's destination tag is a whole number below 2^32.
    func isValidMemo(_ text: String) -> Bool {
        let memo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memo.isEmpty else { return true }
        if self == .xrp {
            return memo.count <= 10 && memo.allSatisfy { $0.isASCII && $0.isNumber } && (UInt64(memo) ?? .max) <= UInt64(UInt32.max)
        }
        return memo.count <= 100
    }

    /// ChangeNOW's network code for Polygon is "matic" (not "polygon") — confirmed against the
    /// live /v2/exchange/currencies list.
    static let usdcPolygon = SwapCoin(ticker: "usdc", network: "matic", displayName: "USDC Coin (Polygon)")

    // MARK: - Single-network coins
    // All ticker/network pairs below were verified against ChangeNOW's live
    // /v2/exchange/currencies list before adding - getting one of these wrong would send a swap's
    // payout to the wrong chain, so none of this is guessed. Pi Network and DASH were explicitly
    // requested but do not exist anywhere in ChangeNOW's currency list (checked twice), so they
    // are not included.
    static let btc = SwapCoin(ticker: "btc", network: "btc", displayName: "Bitcoin")
    static let eth = SwapCoin(ticker: "eth", network: "eth", displayName: "Ethereum")
    static let sol = SwapCoin(ticker: "sol", network: "sol", displayName: "Solana")
    static let xrp = SwapCoin(ticker: "xrp", network: "xrp", displayName: "XRP")
    static let bnb = SwapCoin(ticker: "bnb", network: "bsc", displayName: "BNB (BNB Smart Chain)")
    static let trx = SwapCoin(ticker: "trx", network: "trx", displayName: "TRON")
    static let hype = SwapCoin(ticker: "hype", network: "hyperevm", displayName: "Hyperliquid")
    static let doge = SwapCoin(ticker: "doge", network: "doge", displayName: "Dogecoin")
    static let ltc = SwapCoin(ticker: "ltc", network: "ltc", displayName: "Litecoin")
    static let zec = SwapCoin(ticker: "zec", network: "zec", displayName: "Zcash")
    static let xmr = SwapCoin(ticker: "xmr", network: "xmr", displayName: "Monero")
    static let ada = SwapCoin(ticker: "ada", network: "ada", displayName: "Cardano")
    static let bch = SwapCoin(ticker: "bch", network: "bch", displayName: "Bitcoin Cash")
    static let etc = SwapCoin(ticker: "etc", network: "etc", displayName: "Ethereum Classic")

    // MARK: - Tether (USDT), every network ChangeNOW lists
    static let usdtEth = SwapCoin(ticker: "usdt", network: "eth", displayName: "Tether (ERC20)")
    static let usdtTrx = SwapCoin(ticker: "usdt", network: "trx", displayName: "Tether (TRC20)")
    static let usdtBsc = SwapCoin(ticker: "usdt", network: "bsc", displayName: "Tether (BNB Smart Chain)")
    static let usdtSol = SwapCoin(ticker: "usdt", network: "sol", displayName: "Tether (Solana)")
    static let usdtMatic = SwapCoin(ticker: "usdt", network: "matic", displayName: "Tether (Polygon)")
    static let usdtArbitrum = SwapCoin(ticker: "usdt", network: "arbitrum", displayName: "Tether (Arbitrum)")
    static let usdtOp = SwapCoin(ticker: "usdt", network: "op", displayName: "Tether (Optimism)")

    // MARK: - USDC, every other network ChangeNOW lists (Polygon is `usdcPolygon` above)
    static let usdcEth = SwapCoin(ticker: "usdc", network: "eth", displayName: "USDC Coin (Ethereum)")
    static let usdcSol = SwapCoin(ticker: "usdc", network: "sol", displayName: "USDC Coin (Solana)")
    static let usdcBsc = SwapCoin(ticker: "usdc", network: "bsc", displayName: "USDC Coin (BNB Smart Chain)")
    static let usdcAlgo = SwapCoin(ticker: "usdc", network: "algo", displayName: "USDC Coin (Algorand)")
    static let usdcOp = SwapCoin(ticker: "usdc", network: "op", displayName: "USDC Coin (Optimism)")
    static let usdcArbitrum = SwapCoin(ticker: "usdc", network: "arbitrum", displayName: "USDC Coin (Arbitrum)")
    static let usdcBase = SwapCoin(ticker: "usdc", network: "base", displayName: "USDC Coin (Base)")
    static let usdcSui = SwapCoin(ticker: "usdc", network: "sui", displayName: "USDC Coin (Sui)")

    static let curated: [SwapCoin] = [
        btc, eth, sol, xrp, bnb, trx, hype, doge, ltc, zec, xmr, ada, bch, etc,
        usdtEth, usdtTrx, usdtBsc, usdtSol, usdtMatic, usdtArbitrum, usdtOp,
        usdcPolygon, usdcEth, usdcSol, usdcBsc, usdcAlgo, usdcOp, usdcArbitrum, usdcBase, usdcSui
    ]
}

/// Local record of a swap this device initiated, kept for the "Swap History" list — ChangeNOW is
/// the source of truth for the exchange itself, this just remembers it happened and caches the
/// last status we saw so the list has something to show without a network round trip on open.
struct SwapTransaction: Codable, Identifiable, Equatable {
    let id: String // ChangeNOW exchange id — also the primary key
    let fromTicker: String
    let fromNetwork: String
    let toTicker: String
    let toNetwork: String
    let fromAmount: String
    var toAmount: String
    let payinAddress: String
    let payoutAddress: String
    var status: String
    let createdAt: Date
    /// Set once this device auto-sent KAS to payinAddress, when KAS was the "from" side.
    var kasSendTxId: String?
    /// Set once the KAS leg of this swap has been recorded as a portfolio transaction.
    var addedToPortfolio: Bool = false
    /// ChangeNOW's deposit tag (XRP's destination tag): the deposit must carry it or it isn't
    /// credited. Optional, so history saved before it decodes (audit 2026-11-24 #1).
    var payinExtraId: String? = nil
    /// The tag (destination tag / memo) the payout goes out with, when one was given.
    var payoutExtraId: String? = nil
}
