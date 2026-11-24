import Combine
import Foundation

/// Swap (back 2026-11-23, the Wallet tab's Swap button): KAS for kUSDT natively through Trestly's
/// pool on Kaspa (`TrestlyTrade`, when kUSDT is the other coin), and KAS for coins on other networks
/// through ChangeNOW. Both open only after their third-party agreements (`SwapAgreementsView`).
///
/// ChangeNOW: KAS <-> another coin — combines the roles of Android's
/// SwapViewModel + SwapRepository into one observable service, matching this app's existing
/// pattern of a single `*.shared` service driving Views directly rather than a separate
/// repository layer. Neither side of a swap is something this app sends automatically: whichever
/// coin the user is giving up, they pay into the ChangeNOW deposit address themselves (shown as a
/// QR code), same as the "to" side already worked when that coin wasn't KAS.
@MainActor
final class SwapService: ObservableObject {
    static let shared = SwapService()

    /// The account (lowercased chatting address) whose history and agreements are loaded. Swap
    /// state follows the account (audit 2026-11-24 #5).
    private var account: String?
    private var accountObserver: AnyCancellable?

    @Published private(set) var history: [SwapTransaction] = []

    // True = KAS is what you're sending (the curated coin is what you receive); false = the
    // reverse. KAS is always one side of the pair, only which side flips. Defaults to false -
    // most people opening Swap are looking to acquire KAS, not sell it, so "You Send" starts on
    // the other coin and "You Get" starts on KAS.
    @Published var kasIsSendSide: Bool = false
    @Published var otherCoin: SwapCoin = .usdcPolygon
    /// The "You Send" amount. Typed by the user when `editedSide == .send`; otherwise filled in
    /// by the reverse quote for whatever they typed under "You Get".
    @Published var amountText: String = ""
    /// The "You Get" amount - the mirror of `amountText`: typed when `editedSide == .get`, else
    /// the direct quote's answer.
    @Published var receiveAmountText: String = ""

    /// Which amount the user last typed. The other one is a quote and gets overwritten by every
    /// estimate; the typed one is the input the swap is created from.
    enum AmountSide { case send, get }
    @Published private(set) var editedSide: AmountSide = .send
    /// Where ChangeNOW should deliver the "to" coin — only asked for when that coin isn't KAS
    /// (KAS always comes back to this wallet automatically).
    @Published var payoutAddressText: String = ""
    /// The payout's tag (XRP's destination tag) for a coin that may need one (`SwapCoin.needsMemo`);
    /// optional, sent as ChangeNOW's `extraId` (audit 2026-11-24 #1).
    @Published var payoutExtraIdText: String = ""

    /// Where swap-received KAS lands. Nil previews the next never-used spending address (same
    /// index math as WalletManager.generateNextSpendingAddress, just not reserved/persisted
    /// until executeSwap actually calls it) - set to a specific index to reuse an existing
    /// address instead, e.g. one already received into from a prior swap.
    @Published private(set) var toAddressOverrideIndex: Int?
    @Published private(set) var toAddress: String = ""

    enum EstimateStatus { case idle, loading, success, failed }
    struct EstimateUiState {
        var status: EstimateStatus = .idle
        /// Both sides of the quote once it succeeds - the typed one echoed back, the other one
        /// ChangeNOW's answer.
        var fromAmount: Double?
        var toAmount: Double?
        var errorMessage: String?
    }
    @Published private(set) var estimateState = EstimateUiState()

    enum CreateSwapStatus { case idle, creating, success, failed }
    /// The exchange ChangeNOW created, with the coins and amount it was made for: the deposit
    /// card is drawn from this, never from the coins picked now (audit 2026-11-24 #2).
    struct CreatedSwap: Equatable {
        let transaction: SwapTransaction
        let fromCoin: SwapCoin
        let toCoin: SwapCoin
    }
    struct CreateSwapUiState {
        var status: CreateSwapStatus = .idle
        var result: CreatedSwap?
        var errorMessage: String?
    }
    @Published private(set) var createSwapState = CreateSwapUiState()

    private var estimateTask: Task<Void, Never>?

    // MARK: kUSDT (Trestly)

    /// The address a kUSDT swap trades from: KAS leaves it and kUSDT lands on it (or the other way
    /// round). nil is the Chatting Address. Only plain (Schnorr) addresses: Trestly's code trades
    /// from nothing else.
    @Published var kusdtFrom: TrestlyTarget?
    /// The pool's quote for what was typed, in the received side's base units (sompi or kUSDT units).
    @Published private(set) var kusdtQuote: UInt64?
    /// The trade waiting for Approve or Decline, shown as `TrestlyApprovalSheet`.
    @Published var kusdtApproval: TrestlyApproval?
    /// "Swapped 10 KAS for 0.26 kUSDT", for the screen's toast; cleared once shown.
    @Published var notice: String?

    var isKusdt: Bool { otherCoin.isTrestly }

    /// The kUSDT swap's address, the Chatting Address unless another was picked.
    var kusdtTarget: TrestlyTarget? {
        if let kusdtFrom { return kusdtFrom }
        guard let chatting = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return TrestlyTarget(label: AppLocalization.string("Chatting Address"), address: chatting, spendingIndex: nil)
    }

    /// The typed "You Send" amount in base units: sompi when KAS is sent (a buy), kUSDT units when
    /// kUSDT is (a sell).
    private var kusdtAmountIn: UInt64? {
        let units = kasIsSendSide
            ? KaspaUnit.sompi(fromUserText: amountText)
            : TokenAmount.units(fromTyped: amountText, token: .kusdt)
        guard let units, units > 0 else { return nil }
        return units
    }

    /// 1% under the quote: the least the swap goes ahead for, if the pool moves before it lands.
    private static func minimumOut(_ quote: UInt64) -> UInt64 { quote - quote / 100 }

    private init() {
        account = Self.currentAccount
        history = Self.loadHistory(account: account)
        refreshToAddress()
        // `$currentWallet` fires before the value is set, so the change is handled on the next
        // turn of the main queue, once the new account is in place.
        accountObserver = WalletManager.shared.$currentWallet
            .map { $0?.publicAddress.lowercased() }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.accountChanged() }
            }
    }

    private static var currentAccount: String? {
        WalletManager.shared.currentWallet?.publicAddress.lowercased()
    }

    /// Another account (or none): nothing of the last one's swap stays on screen or goes into
    /// the next one's requests - its history, picked addresses, typed payout, quote and created
    /// exchange (audit 2026-11-24 #5).
    private func accountChanged() {
        let now = Self.currentAccount
        guard now != account else { return }
        account = now
        history = Self.loadHistory(account: now)
        estimateTask?.cancel()
        kusdtFrom = nil
        kusdtQuote = nil
        toAddressOverrideIndex = nil
        payoutAddressText = ""
        payoutExtraIdText = ""
        amountText = ""
        receiveAmountText = ""
        editedSide = .send
        estimateState = EstimateUiState()
        createSwapState = CreateSwapUiState()
        refreshToAddress()
        // `agreementsAccepted` is per account
        objectWillChange.send()
    }

    // MARK: - Coin selection / direction

    var fromCoin: SwapCoin { kasIsSendSide ? .kas : otherCoin }
    var toCoin: SwapCoin { kasIsSendSide ? otherCoin : .kas }

    func flipDirection() {
        kasIsSendSide.toggle()
        clearCreatedSwap()
        clearQuotedAmount()
        rescheduleEstimate()
    }

    func setOtherCoin(_ coin: SwapCoin) {
        if coin != otherCoin {
            clearCreatedSwap()
            payoutExtraIdText = ""
        }
        otherCoin = coin
        // Trestly's pool quotes from what you send, so a typed "You Get" moves to "You Send"
        if coin.isTrestly, editedSide == .get {
            amountText = ""
            editedSide = .send
        }
        clearQuotedAmount()
        rescheduleEstimate()
    }

    /// Swap from another address (kUSDT): the quote is that address's to make again.
    func setKusdtFrom(_ target: TrestlyTarget?) {
        kusdtFrom = target
        rescheduleEstimate()
    }

    /// The pair changed, so the quoted side's figure is for a different pair - blank it until
    /// the new quote lands; the typed side stays as the input.
    private func clearQuotedAmount() {
        switch editedSide {
        case .send: receiveAmountText = ""
        case .get: amountText = ""
        }
    }

    /// "You Send" typed: the "You Get" figure is now stale, so it clears until the quote lands.
    /// Cleaned as every amount field is: "1,5" becomes "1.5", never 15 (audit 2026-11-24 #3).
    func setAmountText(_ text: String) {
        amountText = KaspaUnit.sanitizeAmountInput(text)
        editedSide = .send
        receiveAmountText = ""
        rescheduleEstimate()
    }

    /// "You Get" typed: the reverse quote will fill "You Send" with what that costs.
    func setReceiveAmountText(_ text: String) {
        receiveAmountText = KaspaUnit.sanitizeAmountInput(text)
        editedSide = .get
        amountText = ""
        rescheduleEstimate()
    }

    /// The amount the user typed, whichever card it was.
    private var editedAmountText: String {
        editedSide == .send ? amountText : receiveAmountText
    }

    /// A typed amount as a number, read the way the field cleans it ("1,5" is 1.5).
    private static func decimalValue(_ text: String) -> Double? {
        Double(KaspaUnit.sanitizeAmountInput(text))
    }

    /// Plain decimal text for a quoted amount: up to 8 places, trailing zeros trimmed, never
    /// scientific notation - it is shown in the card and, for a reverse quote, sent back to
    /// ChangeNOW as the `fromAmount` the exchange is created with.
    static func formatQuotedAmount(_ value: Double) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - To spending address selection

    func selectToSpendingAddress(index: Int) {
        toAddressOverrideIndex = index
        refreshToAddress()
    }

    /// The legacy slot the payout will take (`generateNextSpendingAddress` at send time): one past
    /// the legacy chain. `maxSpendingAddressIndex` already covers a legacy primary; a quantum
    /// primary's index must not enter legacy arithmetic.
    private func nextFreshSpendingIndex() -> Int {
        WalletManager.shared.maxSpendingAddressIndex + 1
    }

    func refreshToAddress() {
        let index = toAddressOverrideIndex ?? nextFreshSpendingIndex()
        toAddress = WalletManager.shared.spendingAddress(at: index) ?? ""
    }

    // MARK: - Live quote

    /// Debounced live quote — re-fires on every relevant field change rather than needing an
    /// explicit "Get Rate" tap.
    private func rescheduleEstimate() {
        estimateTask?.cancel()
        kusdtQuote = nil
        if isKusdt {
            rescheduleKusdtEstimate()
            return
        }
        guard let amount = Self.decimalValue(editedAmountText), amount > 0 else {
            estimateState = EstimateUiState()
            return
        }
        let from = fromCoin
        let to = toCoin
        let side = editedSide
        let amountStr = KaspaUnit.sanitizeAmountInput(editedAmountText)
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            estimateState = EstimateUiState(status: .loading)
            do {
                // Direct quote answers "You Get" for a typed "You Send"; the reverse quote
                // answers "You Send" for a typed "You Get". Either way the quoted side's card
                // is filled from the response so both figures are ChangeNOW's, not ours.
                let response: ChangeNowEstimateResponse
                switch side {
                case .send:
                    response = try await ChangeNowAPIClient.shared.getEstimatedAmount(
                        fromCurrency: from.ticker,
                        fromNetwork: from.network,
                        toCurrency: to.ticker,
                        toNetwork: to.network,
                        fromAmount: amountStr
                    )
                case .get:
                    response = try await reverseQuote(from: from, to: to, target: amount)
                }
                guard !Task.isCancelled else { return }
                switch side {
                case .send: receiveAmountText = Self.formatQuotedAmount(response.toAmount)
                case .get: amountText = Self.formatQuotedAmount(response.fromAmount)
                }
                estimateState = EstimateUiState(
                    status: .success,
                    fromAmount: response.fromAmount,
                    toAmount: response.toAmount
                )
            } catch {
                guard !Task.isCancelled else { return }
                estimateState = EstimateUiState(status: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    /// kUSDT: Trestly's `prepare` for what was typed (nothing signed), with no minimum, so the
    /// pool's own quote lands in "You Get". A paused pool or its circuit breaker says so instead.
    private func rescheduleKusdtEstimate() {
        guard let amountIn = kusdtAmountIn, let target = kusdtTarget else {
            receiveAmountText = ""
            estimateState = EstimateUiState()
            return
        }
        let buying = kasIsSendSide
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            estimateState = EstimateUiState(status: .loading)
            do {
                let prepared = try await TrestlyTrade.prepare(
                    method: "kusdt_swap",
                    params: ["side": buying ? "buy" : "sell", "amountIn": String(amountIn), "minOut": "0"],
                    target: target
                )
                guard !Task.isCancelled else { return }
                guard let quote = TrestlyApproval.number(prepared["quote"]), quote > 0 else {
                    throw TrestlyProvider.ProviderError(code: TrestlyProvider.Code.failed, message: AppLocalization.string("The pool gives nothing for this amount."))
                }
                if prepared["paused"] as? Bool == true {
                    throw TrestlyProvider.ProviderError(code: TrestlyProvider.Code.failed, message: AppLocalization.string("Trestly's pool is paused right now, so swaps are stopped for the moment."))
                }
                if prepared["breaker"] is String {
                    throw TrestlyProvider.ProviderError(code: TrestlyProvider.Code.failed, message: AppLocalization.string("The pool's circuit breaker limits sells right now. Try a smaller amount, or again later."))
                }
                kusdtQuote = quote
                receiveAmountText = buying ? TokenAmount.typed(quote, token: .kusdt) : KaspaUnit.plain(quote)
                // the rate line works on whole coins
                let sentWhole = buying ? Double(amountIn) / 100_000_000 : Double(amountIn) / 1_000_000
                let gotWhole = buying ? Double(quote) / 1_000_000 : Double(quote) / 100_000_000
                estimateState = EstimateUiState(status: .success, fromAmount: sentWhole, toAmount: gotWhole)
            } catch {
                guard !Task.isCancelled else { return }
                receiveAmountText = ""
                estimateState = EstimateUiState(status: .failed, errorMessage: Self.message(error))
            }
        }
    }

    /// Trestly's own words for a refusal, else the error's.
    private static func message(_ error: Error) -> String {
        (error as? TrestlyProvider.ProviderError)?.message ?? error.localizedDescription
    }

    // MARK: - Reverse quote on the standard flow

    /// A standard-flow quote is a straight line in the send amount: `to = slope × from +
    /// intercept` (rate applied after the deposit fee, then the withdrawal fee off the top) -
    /// probes at 5, 50 and 500 USDC gave the same slope to seven figures. Two direct quotes
    /// pin the line for a pair; cached briefly so retyping the target costs one confirming
    /// quote, not three.
    private struct LinearQuote {
        let slope: Double
        let intercept: Double
        let minFrom: Double
        let fetchedAt: Date

        func from(forTarget target: Double) -> Double { (target - intercept) / slope }
        func to(forFrom from: Double) -> Double { slope * from + intercept }
    }
    private var linearQuoteCache: [String: LinearQuote] = [:]
    private static let linearQuoteTTL: TimeInterval = 60

    private func linearQuote(from: SwapCoin, to: SwapCoin) async throws -> LinearQuote {
        let key = "\(from.ticker)/\(from.network)>\(to.ticker)/\(to.network)"
        if let cached = linearQuoteCache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.linearQuoteTTL {
            return cached
        }
        let client = ChangeNowAPIClient.shared
        let minFrom = try await client.getMinAmount(
            fromCurrency: from.ticker, fromNetwork: from.network,
            toCurrency: to.ticker, toNetwork: to.network
        )
        // Two probes well inside the accepted range, a decade apart so fee rounding cannot
        // tilt the slope.
        let lowFrom = minFrom * 2
        let highFrom = minFrom * 20
        async let low = client.getEstimatedAmount(
            fromCurrency: from.ticker, fromNetwork: from.network,
            toCurrency: to.ticker, toNetwork: to.network,
            fromAmount: Self.formatQuotedAmount(lowFrom)
        )
        async let high = client.getEstimatedAmount(
            fromCurrency: from.ticker, fromNetwork: from.network,
            toCurrency: to.ticker, toNetwork: to.network,
            fromAmount: Self.formatQuotedAmount(highFrom)
        )
        let (lowQuote, highQuote) = try await (low, high)
        let slope = (highQuote.toAmount - lowQuote.toAmount) / (highQuote.fromAmount - lowQuote.fromAmount)
        guard slope > 0, slope.isFinite else {
            throw KasiaError.apiError(AppLocalization.string("ChangeNOW returned an unusable rate for this pair."))
        }
        let model = LinearQuote(
            slope: slope,
            intercept: lowQuote.toAmount - slope * lowQuote.fromAmount,
            minFrom: minFrom,
            fetchedAt: Date()
        )
        linearQuoteCache[key] = model
        return model
    }

    /// What to send to receive `target`, on the standard flow: solve the pair's line for the
    /// send amount, then confirm it with a real direct quote at that amount - the response's
    /// `toAmount` is what ChangeNOW itself says lands, and that is the figure shown in the rate
    /// line. One refinement if the confirmation is off by more than 0.2% (a rate tick between
    /// the probes and now); the send amount is rounded up at the eighth place so the payout
    /// errs toward the target, not under it.
    private func reverseQuote(from: SwapCoin, to: SwapCoin, target: Double) async throws -> ChangeNowEstimateResponse {
        let model = try await linearQuote(from: from, to: to)
        var sendAmount = (model.from(forTarget: target) * 100_000_000).rounded(.up) / 100_000_000
        guard sendAmount >= model.minFrom else {
            let minTo = model.to(forFrom: model.minFrom)
            throw KasiaError.apiError(String(
                format: AppLocalization.string("The least you can get is about %@ %@."),
                Self.formatQuotedAmount(minTo), to.displayName
            ))
        }
        let client = ChangeNowAPIClient.shared
        var confirmed = try await client.getEstimatedAmount(
            fromCurrency: from.ticker, fromNetwork: from.network,
            toCurrency: to.ticker, toNetwork: to.network,
            fromAmount: Self.formatQuotedAmount(sendAmount)
        )
        if abs(confirmed.toAmount - target) / target > 0.002 {
            sendAmount += (target - confirmed.toAmount) / model.slope
            sendAmount = max(model.minFrom, (sendAmount * 100_000_000).rounded(.up) / 100_000_000)
            confirmed = try await client.getEstimatedAmount(
                fromCurrency: from.ticker, fromNetwork: from.network,
                toCurrency: to.ticker, toNetwork: to.network,
                fromAmount: Self.formatQuotedAmount(sendAmount)
            )
        }
        return confirmed
    }

    // MARK: - Execute swap

    func executeSwap() {
        if isKusdt {
            executeKusdtSwap()
            return
        }
        // `amountText` is either what the user typed under "You Send" or the reverse quote's
        // answer for what they typed under "You Get" - the exchange is always created from
        // the send amount, so a "You Get" target rides on the standard flow: the deposit is
        // the quoted figure and the payout floats with the rate, as with any typed send.
        let amountStr = KaspaUnit.sanitizeAmountInput(amountText)
        guard let amount = Self.decimalValue(amountStr), amount > 0 else { return }
        let from = fromCoin
        let to = toCoin
        let startedOn = account
        // the payout's tag, for a coin that may need one (audit 2026-11-24 #1)
        let extraId: String? = {
            guard to.needsMemo else { return nil }
            let memo = payoutExtraIdText.trimmingCharacters(in: .whitespacesAndNewlines)
            return memo.isEmpty ? nil : memo
        }()
        if let extraId, !to.isValidMemo(extraId) {
            createSwapState = CreateSwapUiState(
                status: .failed,
                errorMessage: AppLocalization.string("This destination tag isn't valid. It's a whole number, with no letters or spaces.")
            )
            return
        }

        createSwapState = CreateSwapUiState(status: .creating)

        Task {
            let payoutAddress: String
            // Swapping into KAS lands in a fresh, never-used spending address by default (rather
            // than the active one, so exchange-received coins can't be chain-linked to everyday
            // spending out of this wallet) unless the user explicitly picked a different address
            // to reuse. Swapping out of KAS needs somewhere else to send the other coin, since
            // this wallet doesn't hold it.
            if to.ticker == "kas" {
                if let overrideIndex = toAddressOverrideIndex {
                    payoutAddress = WalletManager.shared.spendingAddress(at: overrideIndex) ?? ""
                } else {
                    await WalletManager.shared.generateNextSpendingAddress()
                    let freshIndex = WalletManager.shared.maxSpendingAddressIndex
                    payoutAddress = WalletManager.shared.spendingAddress(at: freshIndex) ?? ""
                }
            } else {
                payoutAddress = payoutAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // the account changed while the address was found: it may be the other account's
            // (audit 2026-11-24 #5)
            guard startedOn == account else {
                createSwapState = CreateSwapUiState()
                return
            }

            guard !payoutAddress.isEmpty else {
                createSwapState = CreateSwapUiState(
                    status: .failed,
                    errorMessage: String(format: AppLocalization.string("Enter an address to receive the %@."), to.displayName)
                )
                return
            }

            do {
                let response = try await ChangeNowAPIClient.shared.createTransaction(
                    fromCurrency: from.ticker,
                    fromNetwork: from.network,
                    toCurrency: to.ticker,
                    toNetwork: to.network,
                    fromAmount: amountStr,
                    address: payoutAddress,
                    extraId: extraId
                )
                guard let payinAddress = response.payinAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payinAddress.isEmpty else {
                    createSwapState = CreateSwapUiState(
                        status: .failed,
                        errorMessage: AppLocalization.string("ChangeNOW didn't return a deposit address.")
                    )
                    return
                }
                // ChangeNOW's answer must be the exchange asked for: its payout address, both
                // coins and the amount. Otherwise its deposit address isn't shown (audit 2026-11-24 #6).
                guard Self.answerMatches(response, from: from, to: to, amount: amount,
                                    payoutAddress: payoutAddress, extraId: extraId) else {
                    createSwapState = CreateSwapUiState(
                        status: .failed,
                        errorMessage: AppLocalization.string("ChangeNOW's answer doesn't match this swap, so K didn't show its deposit address. Nothing was sent.")
                    )
                    return
                }
                let payinExtraId = response.payinExtraId?.trimmingCharacters(in: .whitespacesAndNewlines)

                let transaction = SwapTransaction(
                    id: response.id,
                    fromTicker: from.ticker,
                    fromNetwork: from.network,
                    toTicker: to.ticker,
                    toNetwork: to.network,
                    fromAmount: amountStr,
                    toAmount: response.toAmount.map { Self.formatQuotedAmount($0) } ?? "",
                    payinAddress: payinAddress,
                    payoutAddress: payoutAddress,
                    status: response.status ?? "new",
                    createdAt: Date(),
                    kasSendTxId: nil,
                    payinExtraId: (payinExtraId?.isEmpty ?? true) ? nil : payinExtraId,
                    payoutExtraId: extraId
                )
                // filed under the account it was made on, even if that changed meanwhile
                guard startedOn == account else {
                    Self.appendToStoredHistory(transaction, account: startedOn)
                    createSwapState = CreateSwapUiState()
                    return
                }
                history.insert(transaction, at: 0)
                saveHistory()

                createSwapState = CreateSwapUiState(
                    status: .success,
                    result: CreatedSwap(transaction: transaction, fromCoin: from, toCoin: to)
                )
                amountText = ""
                receiveAmountText = ""
                editedSide = .send
                estimateState = EstimateUiState()
                toAddressOverrideIndex = nil
                refreshToAddress()
            } catch {
                guard startedOn == account else {
                    createSwapState = CreateSwapUiState()
                    return
                }
                createSwapState = CreateSwapUiState(status: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    /// Whether ChangeNOW created the exchange K asked for (audit 2026-11-24 #6): the same payout
    /// address (letter case aside: some networks write addresses either way), the same coins on
    /// the same networks where it names them, a send amount within 1% of the one asked, and the
    /// payout tag if it echoes one. The payout address must be in the answer.
    private static func answerMatches(_ response: ChangeNowTransactionResponse, from: SwapCoin, to: SwapCoin,
                                 amount: Double, payoutAddress: String, extraId: String?) -> Bool {
        func same(_ answered: String?, _ asked: String) -> Bool {
            guard let answered = answered?.trimmingCharacters(in: .whitespacesAndNewlines), !answered.isEmpty else { return true }
            return answered.caseInsensitiveCompare(asked) == .orderedSame
        }
        guard let payout = response.payoutAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              payout.caseInsensitiveCompare(payoutAddress) == .orderedSame else { return false }
        guard same(response.fromCurrency, from.ticker), same(response.toCurrency, to.ticker),
              same(response.fromNetwork, from.network), same(response.toNetwork, to.network) else { return false }
        if let sent = response.fromAmount, !(abs(sent - amount) <= amount * 0.01) { return false }
        if let extraId, let echoed = response.payoutExtraId, !echoed.isEmpty, echoed != extraId { return false }
        return true
    }

    /// The created exchange's deposit card goes once the coin, direction or account changes: it
    /// belongs to the exchange made, not to the coins picked now (audit 2026-11-24 #2).
    private func clearCreatedSwap() {
        guard createSwapState.status != .creating else { return }
        createSwapState = CreateSwapUiState()
    }

    /// kUSDT: Trestly's code prepares the swap with a minimum 1% under the quote, K shows it in
    /// `TrestlyApprovalSheet`, and only on Approve signs with the address's key and sends
    /// (`TrestlyTrade.run`, the same path Trestly's site uses).
    private func executeKusdtSwap() {
        guard let amountIn = kusdtAmountIn, let quote = kusdtQuote, let target = kusdtTarget else { return }
        let buying = kasIsSendSide
        createSwapState = CreateSwapUiState(status: .creating)
        Task {
            do {
                let done = try await TrestlyTrade.run(
                    method: "kusdt_swap",
                    params: ["side": buying ? "buy" : "sell", "amountIn": String(amountIn),
                             "minOut": String(Self.minimumOut(quote))],
                    target: target,
                    native: true,
                    ask: { await self.askKusdt($0) }
                )
                Haptics.success()
                notice = TrestlyTrade.recordSwap(done, target: target) ?? AppLocalization.string("Swap sent")
                createSwapState = CreateSwapUiState()
                amountText = ""
                receiveAmountText = ""
                kusdtQuote = nil
                estimateState = EstimateUiState()
            } catch let error as TrestlyProvider.ProviderError where error.code == TrestlyProvider.Code.rejected {
                createSwapState = CreateSwapUiState()
            } catch {
                createSwapState = CreateSwapUiState(status: .failed, errorMessage: Self.message(error))
            }
        }
    }

    /// Shows the approval and waits for Approve or Decline (closing the sheet declines).
    private func askKusdt(_ request: TrestlyApproval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            request.answer = { approved in continuation.resume(returning: approved) }
            kusdtApproval = request
        }
    }

    func refreshSwapStatus(id: String) {
        Task { _ = await refreshSwapStatusAsync(id: id) }
    }

    /// Awaitable variant for the detail screen's Refresh button: returns the fresh status on
    /// success (history is updated + published either way) so the UI can give real feedback.
    func refreshSwapStatusAsync(id: String) async -> String? {
        guard let response = try? await ChangeNowAPIClient.shared.getTransactionStatus(id: id),
              let status = response.status else { return nil }
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].status = status
            saveHistory()
        }
        return status
    }

    func deleteSwap(id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    // MARK: - Add to Portfolio

    struct PortfolioPrefill {
        let type: PortfolioTransactionType
        let amountKas: Double
        let fiatValue: Double
        let timestamp: Date
        let notes: String
    }

    /// Computes what a "finished" swap would add to the Portfolio ledger, for the caller to
    /// show a confirmation before actually saving (see `confirmAddToPortfolio`) - this app
    /// doesn't have Android's prefilled-add-transaction-screen navigation flow, so a lightweight
    /// confirm-then-save replaces it instead.
    func portfolioPrefill(for swap: SwapTransaction) -> PortfolioPrefill? {
        let isKasReceived = swap.toTicker == "kas"
        guard let amountKas = Double(isKasReceived ? swap.toAmount : swap.fromAmount),
              let fiatValue = Double(isKasReceived ? swap.fromAmount : swap.toAmount) else {
            return nil
        }
        return PortfolioPrefill(
            type: isKasReceived ? .buy : .sell,
            amountKas: amountKas,
            fiatValue: fiatValue,
            timestamp: swap.createdAt,
            notes: "ChangeNOW swap \(swap.id)"
        )
    }

    func confirmAddToPortfolio(_ prefill: PortfolioPrefill, swapId: String, portfolioId: UUID? = nil) {
        // Goes through the shared view model (not a direct PortfolioLedgerStore write) so
        // Portfolio's own @Published transactions list picks this up immediately if it's already
        // open, instead of only reflecting it after the app is relaunched.
        PortfolioViewModel.shared.addTransaction(
            type: prefill.type,
            amountKas: prefill.amountKas,
            fiatValue: prefill.fiatValue,
            timestamp: prefill.timestamp,
            notes: prefill.notes,
            portfolioId: portfolioId,
            // Namespaced so it can never collide with a Kaspa txid. Without this a swap had no
            // provenance at all and could be added to the same portfolio over and over.
            sourceTxId: PortfolioViewModel.swapSourceTxId(swapId)
        )

        if let index = history.firstIndex(where: { $0.id == swapId }) {
            history[index].addedToPortfolio = true
            saveHistory()
        }
    }

    // MARK: - Agreements

    /// Swap opens only once both third-party agreements are accepted (`SwapAgreementsView`):
    /// ChangeNOW for coins on other networks, Trestly for kUSDT. Kept per account (its chatting
    /// address) on this device; a new version of the text (`agreementsVersion`) asks again.
    static let agreementsVersion = 1

    private static func agreementsStorageKey(version: Int = SwapService.agreementsVersion, account: String) -> String {
        "kachat_swap_agreements_v\(version)_\(account)"
    }

    private static var agreementsKey: String? {
        currentAccount.map { agreementsStorageKey(account: $0) }
    }

    var agreementsAccepted: Bool {
        guard let key = Self.agreementsKey else { return false }
        return UserDefaults.standard.bool(forKey: key)
    }

    func acceptAgreements() {
        guard let key = Self.agreementsKey else { return }
        UserDefaults.standard.set(true, forKey: key)
        objectWillChange.send()
    }

    // MARK: - History persistence

    /// Kept per account (its lowercased chatting address) since 2026-11-24 (audit #5); before,
    /// one list for every account on the phone.
    private static let legacyHistoryKey = "kachat_swap_history"

    private static func historyKey(account: String) -> String {
        "kachat_swap_history_\(account)"
    }

    private static func loadHistory(account: String?) -> [SwapTransaction] {
        guard let account else { return [] }
        let defaults = UserDefaults.standard
        // The one list from before goes, once, to the account open when Swap first loads: an
        // exchange still waiting for its deposit must not lose its address.
        if let legacy = defaults.data(forKey: legacyHistoryKey) {
            if defaults.data(forKey: historyKey(account: account)) == nil {
                defaults.set(legacy, forKey: historyKey(account: account))
            }
            defaults.removeObject(forKey: legacyHistoryKey)
        }
        guard let data = defaults.data(forKey: historyKey(account: account)),
              let decoded = try? JSONDecoder().decode([SwapTransaction].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveHistory() {
        history.sort { $0.createdAt > $1.createdAt }
        guard let account, let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey(account: account))
    }

    /// An exchange created for an account that is no longer the open one: into its stored list.
    private static func appendToStoredHistory(_ transaction: SwapTransaction, account: String?) {
        guard let account else { return }
        var list = loadHistory(account: account)
        list.insert(transaction, at: 0)
        list.sort { $0.createdAt > $1.createdAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: historyKey(account: account))
    }

    /// The account is being removed (`WalletManager.removeLocalData`): its swap history and its
    /// accepted agreements, every version (audit 2026-11-24 #5).
    static func removeAllData(forWalletAddress address: String) {
        let account = address.lowercased()
        UserDefaults.standard.removeObject(forKey: historyKey(account: account))
        for version in 1...agreementsVersion {
            UserDefaults.standard.removeObject(forKey: agreementsStorageKey(version: version, account: account))
        }
    }
}
