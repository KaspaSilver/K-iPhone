import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Swap, from the Wallet tab's Swap button (back 2026-11-23): KAS for kUSDT through Trestly's pool
/// on Kaspa, KAS for coins on other networks through ChangeNOW (see SwapService). Opens on the two
/// third-party agreements (`SwapAgreementsView`) until both are accepted.
///
/// Buy and sell, step by step (owner, 2026-11-26: buy / sell words, not "swap"): the Wallet's Buy
/// button (`BuyKaspaSheet` on mainnet: crypto or debit card) asks what to pay with, its Sell button
/// what to get (`SwapCoinChoiceList`), then the order itself with an amount on either
/// side. A ChangeNOW order then shows its deposit (`SwapDepositScreen`: what to send, the QR and
/// address, waiting for payment, the transaction ID) until it finishes (`SwapCompleteScreen`, with
/// Add to Portfolio). A kUSDT order ends on a sent screen once Trestly's trade goes out.
struct SwapView: View {
    /// Where it opens: buying Kaspa (what to pay with), selling it (what to get), the history, or
    /// straight on the order (the debit card's kUSDT for KAS, set up before).
    enum Start: String, Identifiable { case buy, sell, history, form; var id: String { rawValue } }
    var start: Start = .form
    /// Opened to fund the chatting address: bought Kaspa is set to land there to start with.
    var buyToChatting = false

    /// The screens after the first.
    enum Step: Hashable {
        /// Buying Kaspa: where it lands, before the amounts.
        case destination
        case form
        case deposit(String)
        case complete(String)
        case kusdtDone(String)
    }
    @State private var path: [Step] = []

    @ObservedObject private var swapService = SwapService.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @State private var showKusdtFromPicker = false

    @State private var selectedSwap: SwapTransaction?
    @State private var showPortfolioConfirm = false

    /// Portfolios that already hold the swap being added, so the chooser can flag the duplicate
    /// before it happens rather than leaving the ledger quietly counting it twice.
    private var duplicatePortfolioIds: Set<UUID> {
        guard let swapId = pendingPortfolioSwapId else { return [] }
        return PortfolioViewModel.shared.portfolioIdsContaining(
            sourceTxId: PortfolioViewModel.swapSourceTxId(swapId)
        )
    }
    @State private var pendingPortfolioPrefill: SwapService.PortfolioPrefill?
    @State private var pendingPortfolioSwapId: String?
    @State private var pendingDeleteSwap: SwapTransaction?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case amount
        case receiveAmount
        case payoutAddress
        case payoutExtraId
    }

    var body: some View {
        // the history is only a list: no agreement needed to read it
        if swapService.agreementsAccepted || start == .history {
            swapScreen
        } else {
            SwapAgreementsView(onCancel: { dismiss() }, onAccept: { swapService.acceptAgreements() })
        }
    }

    private var swapScreen: some View {
        NavigationStack(path: $path) {
            rootScreen
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                stepScreen(step)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .toast(message: toastMessage)
            // a kUSDT swap that went through: its own screen, from the swap itself
            .onChange(of: swapService.notice) { notice in
                guard let notice else { return }
                swapService.notice = nil
                if path.last == .form || (path.isEmpty && start == .form) {
                    path.append(.kusdtDone(notice))
                } else {
                    showToast(notice)
                }
            }
            .sheet(item: $swapService.kusdtApproval) { request in
                TrestlyApprovalSheet(request: request) { approved in
                    swapService.kusdtApproval = nil
                    request.respond(approved)
                }
                .onDisappear { request.respond(false) }
            }
            .sheet(isPresented: $showKusdtFromPicker) {
                KusdtSwapFromPicker(current: swapService.kusdtTarget?.address) { target in
                    swapService.setKusdtFrom(target)
                }
            }
            // a ChangeNOW exchange made: its deposit screen
            .onChange(of: swapService.createSwapState.status) { status in
                if status == .success, let created = swapService.createSwapState.result {
                    path.append(.deposit(created.transaction.id))
                } else if status == .failed {
                    showToast(swapService.createSwapState.errorMessage ?? "Swap failed")
                }
            }
            .sheet(item: $selectedSwap) { swap in
                SwapDetailView(swap: swap) {
                    selectedSwap = nil
                    addToPortfolio(swap)
                }
            }
            // A half sheet rather than a confirmation dialog, like every other chooser in the
            // app: each portfolio gets a row with room to say when the swap is already in it.
            .sheet(isPresented: $showPortfolioConfirm, onDismiss: {
                pendingPortfolioPrefill = nil
                pendingPortfolioSwapId = nil
            }) {
                let portfolios = PortfolioManager.shared.portfolios
                VStack(spacing: 12) {
                    Text("Add to Portfolio")
                        .font(.headline)
                        .padding(.top, 22)
                    if let prefill = pendingPortfolioPrefill {
                        portfolioPrompt(prefill)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(portfolios) { portfolio in
                                let duplicate = duplicatePortfolioIds.contains(portfolio.id)
                                ActionSheetRow(
                                    title: portfolio.name,
                                    subtitle: duplicate
                                        ? "Already holds this swap - adding it again double-counts it."
                                        : "The swap lands in this portfolio.",
                                    systemImage: duplicate ? "exclamationmark.triangle" : "chart.pie",
                                    tint: duplicate ? .orange : .accentColor
                                ) {
                                    if let prefill = pendingPortfolioPrefill, let swapId = pendingPortfolioSwapId {
                                        swapService.confirmAddToPortfolio(prefill, swapId: swapId, portfolioId: portfolio.id)
                                        showToast(String(format: AppLocalization.string("Added to %@"), portfolio.name))
                                    }
                                    showPortfolioConfirm = false
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
                .presentationDetents([.height(CGFloat(150 + min(portfolios.count, 4) * 78)), .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Delete this swap?",
                isPresented: Binding(get: { pendingDeleteSwap != nil }, set: { if !$0 { pendingDeleteSwap = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDeleteSwap {
                        swapService.deleteSwap(id: pendingDeleteSwap.id)
                    }
                    pendingDeleteSwap = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteSwap = nil
                }
            } message: {
                Text("This only removes it from your local history - it doesn't affect the actual exchange.")
            }
        }
    }

    // MARK: - The steps

    @ViewBuilder
    private var rootScreen: some View {
        switch start {
        case .buy:
            SwapCoinChoiceList(
                question: AppLocalization.string("What do you want to pay with?"),
                coins: SwapCoinChoiceList.everyCoin(includingKaspa: false)
            ) { coin in
                choosePair(from: coin, to: .kas)
            }
            .navigationTitle("Buy Kaspa")
            .navigationBarTitleDisplayMode(.inline)
        case .sell:
            SwapCoinChoiceList(
                question: AppLocalization.string("What do you want for your Kaspa?"),
                coins: SwapCoinChoiceList.everyCoin(includingKaspa: false)
            ) { coin in
                choosePair(from: .kas, to: coin)
            }
            .navigationTitle("Sell Kaspa")
            .navigationBarTitleDisplayMode(.inline)
        case .history:
            swapHistoryPage
                .navigationTitle("Buy/Sell History")
                .navigationBarTitleDisplayMode(.inline)
        case .form:
            formScreen
        }
    }

    @ViewBuilder
    private func stepScreen(_ step: Step) -> some View {
        switch step {
        case .destination:
            SwapDestinationStep { path.append(.form) }
        case .form:
            formScreen
        case .deposit(let id):
            SwapDepositScreen(swapId: id, onCopied: { showToast($0) }) {
                // finished: the completion takes the deposit's place
                if let last = path.indices.last { path[last] = .complete(id) }
            }
            .navigationBarBackButtonHidden(true)
        case .complete(let id):
            SwapCompleteScreen(swapId: id, onAddToPortfolio: { swap in addToPortfolio(swap) }, onDone: { dismiss() })
                .navigationBarBackButtonHidden(true)
        case .kusdtDone(let message):
            SwapSentScreen(message: message, onDone: { dismiss() })
                .navigationBarBackButtonHidden(true)
        }
    }

    /// The order: Buy Kaspa with a coin or Sell Kaspa for one, an amount on either side.
    private var formScreen: some View {
        swapFormPage
            .navigationTitle(Text(verbatim: swapService.kasIsSendSide
                ? String(format: AppLocalization.string("Sell Kaspa for %@"), swapService.otherCoin.displayName)
                : String(format: AppLocalization.string("Buy Kaspa with %@"), swapService.otherCoin.displayName)))
            .navigationBarTitleDisplayMode(.inline)
    }

    /// The pair picked on the coin screen: Kaspa is always one side (bought or sold), so which side
    /// it's on sets the direction and the other coin is the pair's.
    private func choosePair(from first: SwapCoin, to second: SwapCoin) {
        let kasSends = first == .kas
        if swapService.kasIsSendSide != kasSends { swapService.flipDirection() }
        swapService.setOtherCoin(kasSends ? second : first)
        swapService.setAmountText("")
        if !kasSends && buyToChatting { swapService.useChattingToAddress() } else { swapService.useFreshToAddress() }
        // buying Kaspa: where it lands is its own step (owner, 2026-11-26), for kUSDT too
        path.append(kasSends ? .form : .destination)
    }

    /// Add to Portfolio, from the completion screen or a history entry: the portfolio chooser.
    private func addToPortfolio(_ swap: SwapTransaction) {
        guard let prefill = swapService.portfolioPrefill(for: swap) else {
            showToast("Couldn't read this swap's amounts")
            return
        }
        pendingPortfolioPrefill = prefill
        pendingPortfolioSwapId = swap.id
        showPortfolioConfirm = true
    }

    // MARK: - Swap form

    private var isBusy: Bool {
        swapService.createSwapState.status == .creating
    }

    private var canSwap: Bool {
        swapService.estimateState.status == .success && !isBusy
    }

    private var needsPayoutAddress: Bool {
        swapService.toCoin.ticker != "kas" && !swapService.isKusdt
    }

    private var swapFormPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Both cards take input. Type under "You Send" and "You Get" is quoted; type
                // under "You Get" and the reverse quote fills "You Send" with what that costs.
                swapAmountCard(
                    label: "You Pay",
                    coin: swapService.fromCoin,
                    amountText: swapService.amountText,
                    field: .amount,
                    isQuoting: swapService.editedSide == .get && swapService.estimateState.status == .loading,
                    onAmountChange: { swapService.setAmountText($0) },
                    // kUSDT swaps spend what K holds: Max, and the balance beside "You Send"
                    // (owner, 2026-11-24). A ChangeNOW coin is paid from elsewhere.
                    onMaxTap: (swapService.kusdtMaxSend ?? 0) > 0 ? { swapService.setMaxAmount() } : nil,
                    available: kusdtAvailableText
                )
                .task(id: "\(swapService.isKusdt)|\(swapService.kusdtTarget?.address ?? "")|\(swapService.kasIsSendSide)") {
                    swapService.refreshKusdtBalances()
                }

                // Why Max on a buy is less than the balance (owner, 2026-11-24: "max does not
                // actually pull"): what stays behind, and what it's for.
                if swapService.isKusdt, swapService.kasIsSendSide {
                    Text(verbatim: String(format: AppLocalization.string("Max keeps %@ back: %@ goes inside your new kUSDT coin, and up to %@ pays the network fee."),
                                          KaspaUnit.amount(SwapService.kasKeptForBuy),
                                          KaspaUnit.amount(WalletToken.kusdt.kasPerCoinSompi),
                                          KaspaUnit.amount(SwapService.feeKeptForBuy)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                swapAmountCard(
                    label: "You Get",
                    coin: swapService.toCoin,
                    amountText: swapService.receiveAmountText,
                    field: .receiveAmount,
                    isQuoting: swapService.editedSide == .send && swapService.estimateState.status == .loading,
                    onAmountChange: { swapService.setReceiveAmountText($0) },
                    onMaxTap: nil,
                    // Trestly's pool quotes from what you send: "You Get" is its answer
                    editable: !swapService.isKusdt
                )

                if needsPayoutAddress {
                    TextField("Receive \(swapService.toCoin.displayName) at", text: $swapService.payoutAddressText)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .payoutAddress)
                        .padding(12)
                        .background(glassBackground(cornerRadius: 14))
                }

                // The payout's tag, for a coin whose exchange addresses need one: XRP's
                // destination tag (audit 2026-11-24 #1)
                if needsPayoutAddress && swapService.toCoin.needsMemo {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Destination tag (optional)", text: $swapService.payoutExtraIdText)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(swapService.toCoin == .xrp ? .numberPad : .asciiCapable)
                            .numericKeyboardDoneButton()
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .payoutExtraId)
                            .padding(12)
                            .background(glassBackground(cornerRadius: 14))
                        Text("Only if the receiving address needs one, as most exchanges do. Without it, the exchange can't credit your coins.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // buying with kUSDT, the address was picked on the "where" step
                if swapService.isKusdt && swapService.kasIsSendSide {
                    spendingAddressRow(
                        title: swapService.kasIsSendSide ? "Swap From (kUSDT Lands Here)" : "Swap From (KAS Lands Here)",
                        valueText: swapService.kusdtTarget.map { "\($0.label) \u{00B7} \(shortAddress($0.address))" } ?? "",
                        feeText: nil,
                        onFeeTap: nil,
                        onChangeTap: { showKusdtFromPicker = true }
                    )
                }

                rateCard

                swapButton

                if swapService.isKusdt {
                    Link("Powered by Trestly", destination: SwapAgreementsView.trestlyTermsURL)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .underline()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                } else {
                    Link("Powered by ChangeNOW", destination: URL(string: "https://changenow.io/terms-of-use/changenow-terms")!)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .underline()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// Swap, under the amounts. A ChangeNOW swap goes on to its deposit screen; a kUSDT one asks
    /// for approval first.
    private var swapButton: some View {
        Button {
            focusedField = nil
            swapService.executeSwap()
        } label: {
            Group {
                if isBusy {
                    ProgressView().tint(.black)
                } else {
                    Text(LocalizedStringKey(swapService.kasIsSendSide ? "Sell Kaspa" : "Buy Kaspa"))
                        .fontWeight(.bold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundColor(canSwap ? .black : .secondary)
            .background(Capsule().fill(canSwap ? Color.accentColor : Color(.systemGray5)))
        }
        .buttonStyle(.plain)
        .disabled(!canSwap)
    }

    /// One sentence per side, so each language words it whole (audit 2026-11-24 #34).
    private func portfolioPrompt(_ prefill: SwapService.PortfolioPrefill) -> Text {
        let amount = formatKasTrimmed(ExplorerAPI.clampedUInt64((prefill.amountKas * 100_000_000).rounded()))
        let price = "\(currencySymbol)\(String(format: "%.2f", prefill.fiatValue))"
        return prefill.type == .buy
            ? Text("Buy \(amount) KAS at \(price) - choose which portfolio to add it to.")
            : Text("Sell \(amount) KAS at \(price) - choose which portfolio to add it to.")
    }

    private func shortAddress(_ address: String) -> String {
        address.count > 20 ? "\(address.prefix(12))...\(address.suffix(6))" : address
    }

    private var rateCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rate")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(rateText)
                .font(.caption)
                .foregroundColor(swapService.estimateState.status == .failed ? .red : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(glassBackground(cornerRadius: 14))
    }

    private var rateText: String {
        if swapService.estimateState.status == .success {
            // Both figures come from the quote itself, whichever side was typed.
            let fromAmount = swapService.estimateState.fromAmount ?? 0
            let toAmount = swapService.estimateState.toAmount ?? 0
            guard fromAmount > 0 else { return "\u{2014}" }
            let fromLabel = swapService.kasIsSendSide ? "KAS" : swapService.otherCoin.displayName
            let toLabel = swapService.kasIsSendSide ? swapService.otherCoin.displayName : "KAS"
            return "1 \(fromLabel) \u{2248} \(String(format: "%.8f", toAmount / fromAmount)) \(toLabel)"
        } else if swapService.estimateState.status == .failed {
            return swapService.estimateState.errorMessage ?? AppLocalization.string("Unavailable")
        }
        return "\u{2014}"
    }

    // MARK: - Reusable pieces

    /// One amount card. `isQuoting` marks the card whose figure is being fetched for the
    /// other card's input - it shows a spinner where the number will land, instead of an
    /// empty field that reads as "nothing entered".
    private func swapAmountCard(
        label: String,
        coin: SwapCoin,
        amountText: String,
        field: FocusField,
        isQuoting: Bool,
        onAmountChange: @escaping (String) -> Void,
        onMaxTap: (() -> Void)?,
        available: String? = nil,
        editable: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 8)
                if let available {
                    Text(verbatim: String(format: AppLocalization.string("Available: %@"), available))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            HStack(spacing: 12) {
                if isQuoting {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Thousands grouped as you type (owner, 2026-11-26: "12,345.5"), as Send Kaspa's
                    // amount: the field shows `grouped`, and what's typed goes back plain.
                    TextField("0.00", text: Binding(
                        get: { KaspaAmountEntry.grouped(amountText) },
                        set: { onAmountChange(KaspaAmountEntry.ungrouped($0, previous: KaspaAmountEntry.grouped(amountText))) }
                    ))
                        .font(.title2.weight(.semibold))
                        .keyboardType(.decimalPad)
                        .numericKeyboardDoneButton()
                        .focused($focusedField, equals: field)
                        .disabled(!editable)
                }
                if let onMaxTap {
                    Button("Max", action: onMaxTap)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                coinBadge(coin)
            }
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    /// The Swap From address's balance of what a kUSDT swap sends: KAS on a buy, kUSDT on a sell.
    private var kusdtAvailableText: String? {
        guard swapService.isKusdt else { return nil }
        if swapService.kasIsSendSide {
            return swapService.kusdtFromKasSompi.map { KaspaUnit.amount($0) }
        }
        return TokenAmount.amount(swapService.kusdtFromUnits, token: .kusdt)
    }

    /// The coin, fixed: it's picked on the coin screens before.
    private func coinBadge(_ coin: SwapCoin) -> some View {
        coinBadgeContent(coin)
    }

    private func coinBadgeContent(_ coin: SwapCoin) -> some View {
        HStack(spacing: 6) {
            swapCoinIcon(coin)
            Text(coin.displayName)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.systemGray5)))
    }

    private func spendingAddressRow(title: LocalizedStringKey, valueText: String, feeText: String?, onFeeTap: (() -> Void)?, onChangeTap: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(valueText)
                    .font(.caption.weight(.bold))
                if let feeText, let onFeeTap {
                    Button(action: onFeeTap) {
                        Text(feeText)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button("Change", action: onChangeTap)
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
        }
        .padding(12)
        .background(glassBackground(cornerRadius: 14))
    }

    // MARK: - Swap history page

    private var swapHistoryPage: some View {
        Group {
            if swapService.history.isEmpty {
                VStack {
                    Spacer()
                    Text("No swaps yet.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(swapService.history) { swap in
                        HStack(spacing: 8) {
                            Button {
                                selectedSwap = swap
                            } label: {
                                swapHistoryRow(swap)
                            }
                            .buttonStyle(.plain)

                            Button {
                                pendingDeleteSwap = swap
                            } label: {
                                Image(systemName: "trash")
                                    .font(.scaled(size: 16, weight: .semibold))
                                    .foregroundColor(.red)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func swapHistoryRow(_ swap: SwapTransaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(swap.fromAmount) \(SwapTransaction.displayTicker(swap.fromTicker)) \u{2192} \(swap.isTrestly ? swap.toAmount : formatDecimalString(swap.toAmount)) \(SwapTransaction.displayTicker(swap.toTicker))")
                    .font(.subheadline.weight(.bold))
                HStack(spacing: 4) {
                    Text(swap.createdAt, style: .date)
                    // which service ran it: kUSDT swaps go through Trestly's pool on Kaspa
                    Text(verbatim: "· " + (swap.isTrestly ? "Trestly" : "ChangeNOW"))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            statusBadge(swap.status)
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    // MARK: - Helpers

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func formatKasTrimmed(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private var currencySymbol: String {
        if settingsViewModel.settings.currency == .bitcoin { return "₿" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settingsViewModel.settings.currency.code
        return formatter.currencySymbol ?? settingsViewModel.settings.currency.code
    }

    private func formatDecimalString(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        return String(format: "%.8f", value)
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// "Finished"/"Failed"/etc. pill, matching the withdraw/consolidate history rows' orange/green/red
/// status coloring convention used elsewhere in this app.
private func statusBadge(_ status: String) -> some View {
    Text(swapStatusName(status))
        .font(.caption.weight(.bold))
        .foregroundColor(statusColor(status))
}

/// ChangeNOW's status, in the app's language (audit 2026-11-24 #35).
private func swapStatusName(_ status: String) -> String {
    switch status.lowercased() {
    case "new": return AppLocalization.string("New")
    case "waiting": return AppLocalization.string("Waiting")
    case "confirming": return AppLocalization.string("Confirming")
    case "exchanging": return AppLocalization.string("Exchanging")
    case "sending": return AppLocalization.string("Sending")
    case "finished": return AppLocalization.string("Finished")
    case "failed": return AppLocalization.string("Failed")
    case "refunded": return AppLocalization.string("Refunded")
    case "verifying": return AppLocalization.string("Verifying")
    case "expired": return AppLocalization.string("Expired")
    default: return status.capitalized
    }
}

/// ChangeNOW's deposit tag (XRP's destination tag), which the deposit must carry: shown large,
/// with Copy and why it's required, on the deposit card and in Swap History (audit 2026-11-24 #1).
private struct SwapDepositTagBox: View {
    let tag: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Destination Tag (Memo)")
                    .font(.caption.weight(.bold))
            }
            .foregroundColor(.orange)
            Text(verbatim: tag)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Text("Required: send with this destination tag (memo), or the deposit can't be credited and may be lost.")
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onCopy) {
                Label("Copy Destination Tag", systemImage: "doc.on.doc")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1)
        )
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "finished": return .green
    case "failed", "refunded": return .red
    default: return .orange
    }
}

/// Full detail for one past swap — its deposit QR again, live-ish status, the ChangeNOW exchange
/// id, and a link to track it on changenow.io.
private struct SwapDetailView: View {
    let initialSwap: SwapTransaction
    let onAddToPortfolio: () -> Void

    init(swap: SwapTransaction, onAddToPortfolio: @escaping () -> Void) {
        self.initialSwap = swap
        self.onAddToPortfolio = onAddToPortfolio
    }

    @ObservedObject private var swapService = SwapService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var isRefreshingStatus = false

    /// The LIVE history entry - the sheet used to render the captured value, so Refresh
    /// updated storage but the visible status never changed.
    private var swap: SwapTransaction {
        swapService.history.first { $0.id == initialSwap.id } ?? initialSwap
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(swap.fromAmount) \(SwapTransaction.displayTicker(swap.fromTicker)) \u{2192} \(swap.isTrestly ? swap.toAmount : formatDecimal(swap.toAmount)) \(SwapTransaction.displayTicker(swap.toTicker))")
                            .font(.headline)
                        Text(swap.createdAt, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !swap.isTrestly {
                    HStack {
                        Spacer()
                        if let qrImage = makeQRCodeImage(from: swap.payinAddress) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 180, height: 180)
                                .padding(12)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Spacer()
                    }
                    }
                }

                if swap.isTrestly {
                    trestlySections
                } else {
                changeNowSections
                }
            }
            .toast(message: toastMessage)
            .navigationTitle("Swap Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// A kUSDT swap through Trestly's pool on Kaspa (owner, 2026-11-27): the address it traded
    /// from, its status, and its Kaspa transaction. No deposit address or exchange id: nothing
    /// was sent to a third party.
    @ViewBuilder
    private var trestlySections: some View {
        Section("Swapped Through") {
            Text("Trestly's kUSDT pool on Kaspa")
        }
        Section("Address") {
            Button {
                UIPasteboard.general.string = swap.payoutAddress
                Haptics.success()
                showToast(swap.payoutAddress.addressCopiedToastText)
            } label: {
                Text(verbatim: swap.payoutAddress.wrappingAnywhere)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        statusSection
        Section("Transaction ID") {
            Button {
                UIPasteboard.general.string = swap.id
                Haptics.success()
                showToast(AppLocalization.string("Transaction ID copied"))
            } label: {
                Text(verbatim: swap.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        Section {
            refreshButton(failure: "Couldn't reach the network - try again")
            if let url = AppSettings.load().kaspaExplorer.txURL(for: swap.id) {
                Button("View in Explorer") { UIApplication.shared.open(url) }
                    .foregroundColor(.accentColor)
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text(swapStatusName(swap.status))
                    .fontWeight(.bold)
                    .foregroundColor(statusColor(swap.status))
                Spacer()
                if swap.status == "finished" {
                    Button("Add to Portfolio", action: onAddToPortfolio)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private func refreshButton(failure: String) -> some View {
        Button {
            guard !isRefreshingStatus else { return }
            isRefreshingStatus = true
            Task {
                let status = await SwapService.shared.refreshSwapStatusAsync(id: swap.id)
                isRefreshingStatus = false
                showToast(status.map { String(format: AppLocalization.string("Status: %@"), swapStatusName($0)) }
                          ?? AppLocalization.string(failure))
            }
        } label: {
            HStack {
                Text("Refresh Status")
                    .foregroundColor(.accentColor)
                Spacer()
                if isRefreshingStatus {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }
        }
    }

    @ViewBuilder
    private var changeNowSections: some View {
                Section("Deposit Address") {
                    Button {
                        UIPasteboard.general.string = swap.payinAddress
                        Haptics.success()
                        showToast(swap.payinAddress.addressCopiedToastText)
                    } label: {
                        Text(verbatim: swap.payinAddress.wrappingAnywhere)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                if let tag = swap.payinExtraId, !tag.isEmpty {
                    Section {
                        SwapDepositTagBox(tag: tag) {
                            UIPasteboard.general.string = tag
                            Haptics.success()
                            showToast("Destination tag copied")
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }

                Section("Payout Address") {
                    Button {
                        UIPasteboard.general.string = swap.payoutAddress
                        Haptics.success()
                        showToast(swap.payoutAddress.addressCopiedToastText)
                    } label: {
                        Text(verbatim: swap.payoutAddress.wrappingAnywhere)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    if let payoutTag = swap.payoutExtraId, !payoutTag.isEmpty {
                        Text("Destination Tag: \(payoutTag)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                statusSection

                Section("ChangeNOW Exchange ID") {
                    Button {
                        UIPasteboard.general.string = swap.id
                        Haptics.success()
                        showToast("Exchange ID copied")
                    } label: {
                        Text(verbatim: swap.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                Section {
                    refreshButton(failure: "Couldn't reach ChangeNOW - try again")
                    if let url = URL(string: "https://changenow.io/exchange/txs/\(swap.id)") {
                        Link("View on ChangeNOW", destination: url)
                            .foregroundColor(.accentColor)
                    }
                }
    }

    private func formatDecimal(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        return String(format: "%.8f", value)
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Ticker -> `Assets.xcassets` imageset name for coins with real brand art (sourced from the
/// Tangem wallet app's bundled network logos, via its own remote icon CDN -
/// `s3.eu-central-1.amazonaws.com/tangem.api/coins/large/{coingecko-id}.png`). Tickers not listed
/// here have no available art and fall back to the plain ticker-text circle.
private let swapCoinLogoAssetNames: [String: String] = [
    "btc": "CoinBtc",
    "eth": "CoinEth",
    "sol": "CoinSol",
    "xrp": "CoinXrp",
    "bnb": "CoinBnb",
    "trx": "CoinTrx",
    "hype": "CoinHype",
    "doge": "CoinDoge",
    "ltc": "CoinLtc",
    "ada": "CoinAda",
    "bch": "CoinBch",
    "etc": "CoinEtc",
    "usdc": "CoinUsdc",
    "usdt": "CoinUsdt",
    "zec": "CoinZec",
    "xmr": "CoinXmr"
]

/// KAS and the tickers in `swapCoinLogoAssetNames` get their real brand marks; everything else
/// falls back to its ticker in a plain colored circle. Top-level (not a method on `SwapView`) so
/// `SwapCoinPickerView`'s rows can share it too.
@ViewBuilder
func swapCoinIcon(_ coin: SwapCoin, size: CGFloat = 20) -> some View {
    if coin.isTrestly {
        TokenIcon(token: .kusdt, size: size)
    } else if coin.ticker == "kas" {
        Image("KaspaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    } else if let assetName = swapCoinLogoAssetNames[coin.ticker] {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(Circle())
    } else {
        Text(coin.ticker.uppercased())
            .font(.scaled(size: size * 0.4, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.opacity(0.3)))
    }
}

// MARK: - The agreements before Swap

/// Shown before Swap opens, until both are accepted (per account, `SwapService.acceptAgreements`):
/// ChangeNOW's for coins on other networks and Trestly's for kUSDT, each a third party K doesn't
/// run, each with its terms and its own checkbox (owner's call, 2026-11-23: two agreements, one box
/// each). Continue unlocks when both are checked.
struct SwapAgreementsView: View {
    let onCancel: () -> Void
    let onAccept: () -> Void

    @State private var changeNowChecked = false
    @State private var trestlyChecked = false

    static let changeNowTermsURL = URL(string: "https://changenow.io/terms-of-use")!

    /// `/terms` on the Trestly site set in Settings > Connection (trestly.io on mainnet).
    static var trestlyTermsURL: URL {
        let site = URL(string: AppSettings.load().trestlySiteURL) ?? URL(string: "https://trestly.io")!
        var parts = URLComponents()
        parts.scheme = site.scheme ?? "https"
        parts.host = site.host ?? "trestly.io"
        parts.port = site.port
        parts.path = "/terms"
        return parts.url ?? URL(string: "https://trestly.io/terms")!
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Swap uses two services K doesn't run. Read and agree to both before you continue.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    agreementCard(
                        title: "ChangeNOW",
                        subtitle: "Coins on other networks",
                        icon: AnyView(Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.accentColor)),
                        text: "Swaps between Kaspa and coins on other networks (Bitcoin, Ethereum, USDC, USDT and others) are made by ChangeNOW, a third-party exchange. K only asks ChangeNOW for a quote and a deposit address and shows the swap's status; ChangeNOW does the exchange and sends the coins. K isn't responsible for failed, delayed or lost swaps. If one doesn't go through, contact ChangeNOW's support.",
                        termsTitle: "Read ChangeNOW's Terms of Use",
                        termsURL: Self.changeNowTermsURL,
                        checkboxText: "I understand ChangeNOW is a third party, not K, and I agree to ChangeNOW's Terms of Use.",
                        checked: $changeNowChecked
                    )

                    agreementCard(
                        title: "Trestly",
                        subtitle: "kUSDT on Kaspa",
                        icon: AnyView(TokenIcon(token: .kusdt, size: 30)),
                        text: "Swaps between KAS and kUSDT go through Trestly's pool on Kaspa. Trestly is a third party: it issues kUSDT and runs the pool, not K. Trestly's own code prices each swap and builds its transaction; K shows it to you, signs it with your address's key only after you approve, and sends it. Prices move, and the pool can be paused or limit sells. K isn't responsible for the pool, the token or a swap's outcome.",
                        termsTitle: "Read Trestly's Terms of Service",
                        termsURL: Self.trestlyTermsURL,
                        checkboxText: "I understand Trestly is a third party, not K, and I agree to Trestly's Terms of Service.",
                        checked: $trestlyChecked
                    )
                }
                .padding(20)
            }
            .navigationTitle("Before You Swap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                let ready = changeNowChecked && trestlyChecked
                Button {
                    Haptics.success()
                    onAccept()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(Color.accentColor.opacity(ready ? 1 : 0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private func agreementCard(title: String, subtitle: LocalizedStringKey, icon: AnyView, text: LocalizedStringKey,
                               termsTitle: LocalizedStringKey, termsURL: URL, checkboxText: LocalizedStringKey,
                               checked: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: termsURL) {
                Label(termsTitle, systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            Button {
                Haptics.selection()
                checked.wrappedValue.toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: checked.wrappedValue ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundColor(checked.wrappedValue ? .accentColor : .secondary)
                    Text(checkboxText)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked.wrappedValue ? .isSelected : [])
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 20))
    }
}

// MARK: - kUSDT: which address swaps

/// Where a kUSDT swap trades from (and lands): the Chatting Address, every address holding kUSDT,
/// or a regular spending address holding KAS. Never a quantum one: Trestly's code trades only from
/// plain Schnorr addresses.
private struct KusdtSwapFromPicker: View {
    let current: String?
    let onPick: (TrestlyTarget?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var tokens = TokenWallet.shared
    @State private var kasByAddress: [String: UInt64] = [:]
    @State private var kasAddresses: [SpendingAddressEntry] = []

    private var choices: [TrestlyTarget] {
        var list: [TrestlyTarget] = []
        let held = tokens.holdings(of: .kusdt)
        if let chatting = walletManager.currentWallet?.publicAddress {
            list.append(TrestlyTarget(label: AppLocalization.string("Chatting Address"), address: chatting, spendingIndex: nil,
                                      units: held.first(where: \.isChatting)?.units ?? 0))
        }
        for holding in held where !holding.isChatting {
            list.append(TrestlyTarget(holding: holding))
        }
        for entry in kasAddresses where !list.contains(where: { $0.address == entry.address }) {
            list.append(TrestlyTarget(label: entry.displayLabel, address: entry.address, spendingIndex: entry.index))
        }
        return list
    }

    private func kas(_ address: String) -> UInt64 {
        if let wallet = walletManager.currentWallet, wallet.publicAddress == address { return wallet.balanceSompi ?? 0 }
        return kasByAddress[address] ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The swap's KAS and kUSDT both stay on this address.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ForEach(choices) { choice in
                        Button {
                            Haptics.impact(.light)
                            onPick(choice.spendingIndex == nil ? nil : choice)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice.address == current ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundColor(choice.address == current ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: choice.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.primary)
                                    Text(verbatim: choice.address.count > 24 ? "\(choice.address.prefix(14))...\(choice.address.suffix(8))" : choice.address)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                    Text(verbatim: "\(KaspaUnit.amount(kas(choice.address))) \u{00B7} \(TokenAmount.amount(choice.units, token: .kusdt))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sendKaspaGlass(cornerRadius: 18))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Swap From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            let entries = await walletManager.getSpendingAddressList()
            kasByAddress = Dictionary(entries.map { ($0.address, $0.balanceSompi) }, uniquingKeysWith: { first, _ in first })
            kasAddresses = entries.filter { !$0.isQuantum && $0.balanceSompi > 0 }.sorted { $0.index < $1.index }
        }
    }
}

// MARK: - Swap step by step (owner, 2026-11-26)

/// The Wallet tab's Buy button, a half sheet (owner, 2026-11-26): Buy Kaspa with Crypto or with
/// Debit Card (mainnet only; its order's stage under it, as the Wallet card it replaced showed).
/// Sell has its own button and goes straight in; the history is a card on the Wallet tab.
struct BuyKaspaSheet: View {
    let onCrypto: () -> Void
    let onDebitCard: () -> Void
    @ObservedObject private var tracker = CardBuyTracker.shared

    private var debitSubtitle: String {
        _ = tracker.buy
        if let buy = DebitCardBuy.shownOrder { return BuyKaspaStatus.line(buy) }
        return AppLocalization.string("Pay by card. It lands as kUSDT, then you buy Kaspa with it.")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Buy Kaspa")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)
            ActionSheetRow(
                title: "Buy Kaspa with Crypto",
                subtitle: "Pay with another coin, like kUSDT or Bitcoin.",
                systemImage: "bitcoinsign.circle"
            ) { onCrypto() }
            ActionSheetRow(
                title: "Buy Kaspa with Debit Card",
                subtitle: debitSubtitle,
                systemImage: "creditcard"
            ) { onDebitCard() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A screen of coins to pick from: what to pay with (Buy) or what to get (Sell): kUSDT, then USD
/// Coin and Tether folded by network, then the rest. Search once the
/// list is long.
struct SwapCoinChoiceList: View {
    let question: String
    let coins: [SwapCoin]
    let onPick: (SwapCoin) -> Void

    @State private var searchText = ""
    @State private var expanded: Set<String> = []

    /// Tickers on several networks, folded into one row that opens in place.
    private static let groupNames: [String: String] = ["usdc": "USD Coin", "usdt": "Tether"]

    /// Every coin K swaps, in the list's order.
    static func everyCoin(includingKaspa: Bool) -> [SwapCoin] {
        var list: [SwapCoin] = includingKaspa ? [.kas] : []
        list.append(.kusdt)
        for ticker in ["usdc", "usdt"] {
            list += SwapCoin.curated.filter { $0.ticker == ticker }
        }
        list += SwapCoin.curated.filter { groupNames[$0.ticker] == nil }
        return list
    }

    private enum Row: Identifiable {
        case coin(SwapCoin)
        case group(String)
        case network(SwapCoin)

        var id: String {
            switch self {
            case .coin(let coin): return "c-\(coin.ticker)-\(coin.network)"
            case .group(let ticker): return "g-\(ticker)"
            case .network(let coin): return "n-\(coin.ticker)-\(coin.network)"
            }
        }
    }

    private var rows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            return coins
                .filter { $0.displayName.lowercased().contains(query) || $0.ticker.contains(query) }
                .map { .coin($0) }
        }
        var out: [Row] = []
        var seen: Set<String> = []
        for coin in coins {
            let siblings = coins.filter { $0.ticker == coin.ticker }
            if Self.groupNames[coin.ticker] != nil, siblings.count > 1 {
                guard !seen.contains(coin.ticker) else { continue }
                seen.insert(coin.ticker)
                out.append(.group(coin.ticker))
                if expanded.contains(coin.ticker) {
                    out += siblings.map { .network($0) }
                }
            } else {
                out.append(.coin(coin))
            }
        }
        return out
    }

    private static func symbol(_ coin: SwapCoin) -> String {
        coin.isTrestly ? "kUSDT" : coin.ticker.uppercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: question)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                if coins.count > 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search coins", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(12)
                    .background(glassBackground(cornerRadius: 14))
                    .padding(.bottom, 4)
                }
                ForEach(rows) { row in
                    switch row {
                    case .coin(let coin):
                        coinRow(coin, indent: false)
                    case .network(let coin):
                        coinRow(coin, indent: true)
                    case .group(let ticker):
                        groupRow(ticker)
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func coinRow(_ coin: SwapCoin, indent: Bool) -> some View {
        Button {
            Haptics.impact(.light)
            onPick(coin)
        } label: {
            HStack(spacing: 12) {
                swapCoinIcon(coin, size: indent ? 26 : 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: coin.displayName)
                        .font(indent ? .subheadline.weight(.semibold) : .headline)
                        .foregroundColor(.primary)
                    Text(verbatim: Self.symbol(coin))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(glassBackground(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, indent ? 24 : 0)
    }

    private func groupRow(_ ticker: String) -> some View {
        let networks = coins.filter { $0.ticker == ticker }
        let isOpen = expanded.contains(ticker)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isOpen { expanded.remove(ticker) } else { expanded.insert(ticker) }
            }
        } label: {
            HStack(spacing: 12) {
                if let first = networks.first {
                    swapCoinIcon(first, size: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.groupNames[ticker] ?? ticker.uppercased())
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(verbatim: String(format: AppLocalization.string("%@ on %d networks"), ticker.uppercased(), networks.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(14)
            .background(glassBackground(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A coin of a saved swap, by its ticker and network, with its name.
private func swapCoinFor(ticker: String, network: String) -> SwapCoin {
    ([SwapCoin.kas, .kusdt] + SwapCoin.curated).first { $0.ticker == ticker && $0.network == network }
        ?? SwapCoin(ticker: ticker, network: network, displayName: ticker.uppercased())
}

private func swapQRImage(_ string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
}

/// A ChangeNOW swap's deposit: what to send and where (QR and address, the tag if the coin needs
/// one), waiting for payment, and the transaction ID. Checks ChangeNOW every 10 s while it shows,
/// and moves on to the completion screen once the swap finishes. Drawn from the exchange made,
/// never from the coins picked now (audit 2026-11-24 #2).
private struct SwapDepositScreen: View {
    let swapId: String
    let onCopied: (String) -> Void
    let onFinished: () -> Void

    @ObservedObject private var swapService = SwapService.shared
    @State private var showSendKas = false

    private var swap: SwapTransaction? { swapService.history.first { $0.id == swapId } }

    var body: some View {
        Group {
            if let swap {
                content(swap)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Send Payment")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: swapId) {
            while !Task.isCancelled {
                if let status = await swapService.refreshSwapStatusAsync(id: swapId) {
                    if status.lowercased() == "finished" {
                        Haptics.success()
                        onFinished()
                        return
                    }
                    // failed, refunded or expired: nothing more will happen, so stop asking
                    // (audit 2026-11-27 L18)
                    if SwapService.isEndStatus(status) { return }
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func content(_ swap: SwapTransaction) -> some View {
        let from = swapCoinFor(ticker: swap.fromTicker, network: swap.fromNetwork)
        let to = swapCoinFor(ticker: swap.toTicker, network: swap.toNetwork)
        return ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(verbatim: String(format: AppLocalization.string("Send %@ %@"),
                                          KaspaAmountEntry.grouped(swap.fromAmount), from.displayName))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(verbatim: to == .kas
                         ? AppLocalization.string("to buy Kaspa")
                         : String(format: AppLocalization.string("to sell it for %@"), to.displayName))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)

                statusCard(swap, to: to)

                if let image = swapQRImage(swap.payinAddress) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Deposit Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(verbatim: swap.payinAddress.wrappingAnywhere)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    copyButton("Copy Address") {
                        UIPasteboard.general.string = swap.payinAddress
                        onCopied(swap.payinAddress.addressCopiedToastText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(glassBackground(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount to Send")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(verbatim: "\(KaspaAmountEntry.grouped(swap.fromAmount)) \(from.displayName)")
                        .font(.title3.weight(.bold))
                    copyButton("Copy Amount") {
                        UIPasteboard.general.string = swap.fromAmount
                        onCopied(AppLocalization.string("Amount copied"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(glassBackground(cornerRadius: 18))

                if let tag = swap.payinExtraId, !tag.isEmpty {
                    SwapDepositTagBox(tag: tag) {
                        UIPasteboard.general.string = tag
                        Haptics.success()
                        onCopied(AppLocalization.string("Destination tag copied"))
                    }
                }

                // Kaspa in: K pays it, the address and amount filled in. Once K has sent it, or
                // ChangeNOW has seen a deposit, the button is gone: a second tap paid it twice
                // (audit 2026-11-27 M1).
                if from == .kas, let sent = swap.kasSendTxId {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Sent from K", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        Text(verbatim: sent)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(glassBackground(cornerRadius: 18))
                } else if from == .kas, ["new", "waiting"].contains(swap.status.lowercased()),
                          let sompi = KaspaUnit.sompi(fromUserText: swap.fromAmount) {
                    Button {
                        showSendKas = true
                    } label: {
                        Label("Send KAS from K", systemImage: "arrow.up.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundColor(.black)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showSendKas) {
                        if let wallet = WalletManager.shared.currentWallet {
                            WithdrawKaspaView(
                                fromAddress: wallet.publicAddress,
                                availableBalanceSompi: wallet.balanceSompi,
                                paymentRequest: PaymentRequest(address: swap.payinAddress, amountSompi: sompi, memo: "",
                                                               toChattingAddress: false, creator: nil, signature: nil),
                                onSent: { txId in swapService.recordDepositSent(swapId: swap.id, txId: txId) },
                                onOutcomeUnknown: { txId in swapService.recordDepositSent(swapId: swap.id, txId: txId) }
                            )
                            .environmentObject(ContactsManager.shared)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Transaction ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(verbatim: swap.id)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        copyButton("Copy ID") {
                            UIPasteboard.general.string = swap.id
                            onCopied(AppLocalization.string("Exchange ID copied"))
                        }
                        Spacer()
                        if let url = URL(string: "https://changenow.io/exchange/txs/\(swap.id)") {
                            Link("View on ChangeNOW", destination: url)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(glassBackground(cornerRadius: 18))

                if !swap.toAmount.isEmpty {
                    Text(verbatim: String(format: AppLocalization.string("You get about %@ %@, sent to %@."),
                                          KaspaAmountEntry.grouped(swap.toAmount), to.displayName,
                                          "\(swap.payoutAddress.prefix(12))...\(swap.payoutAddress.suffix(6))"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private func copyButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.success()
            action()
        } label: {
            Label(title, systemImage: "doc.on.doc")
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// Where the swap is: waiting for payment until ChangeNOW sees it, then each step.
    private func statusCard(_ swap: SwapTransaction, to: SwapCoin) -> some View {
        let status = swap.status.lowercased()
        let problem = ["failed", "refunded", "expired", "verifying"].contains(status)
        let title: String
        let detail: String
        switch status {
        case "confirming":
            title = AppLocalization.string("Payment received")
            detail = AppLocalization.string("Waiting for it to confirm.")
        case "exchanging":
            title = AppLocalization.string("Exchanging")
            detail = AppLocalization.string("ChangeNOW is converting your coins.")
        case "sending":
            title = String(format: AppLocalization.string("Sending your %@"), to.displayName)
            detail = AppLocalization.string("Almost done.")
        case "failed":
            title = swapStatusName(status)
            detail = AppLocalization.string("ChangeNOW couldn't finish this order. Check it on ChangeNOW.")
        case "refunded":
            title = swapStatusName(status)
            detail = AppLocalization.string("ChangeNOW sent the coins back.")
        case "expired":
            title = swapStatusName(status)
            detail = AppLocalization.string("Nothing arrived in time. Start a new order.")
        case "verifying":
            title = swapStatusName(status)
            detail = AppLocalization.string("ChangeNOW is checking this order.")
        default:
            title = AppLocalization.string("Waiting for payment")
            detail = AppLocalization.string("Send the amount above. This screen updates by itself.")
        }
        return HStack(spacing: 12) {
            if problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }
}

/// A ChangeNOW order that finished: Purchase Complete or Sale Complete, what went in and what came
/// out, Add to Portfolio, and Done.
private struct SwapCompleteScreen: View {
    let swapId: String
    let onAddToPortfolio: (SwapTransaction) -> Void
    let onDone: () -> Void

    @ObservedObject private var swapService = SwapService.shared

    var body: some View {
        let swap = swapService.history.first { $0.id == swapId }
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)
            Text(LocalizedStringKey(swap?.toTicker == "kas" ? "Purchase Complete" : "Sale Complete"))
                .font(.title.weight(.bold))
            if let swap {
                let from = swapCoinFor(ticker: swap.fromTicker, network: swap.fromNetwork)
                let to = swapCoinFor(ticker: swap.toTicker, network: swap.toNetwork)
                VStack(spacing: 6) {
                    Text(verbatim: String(format: AppLocalization.string("You paid %@ %@"),
                                          KaspaAmountEntry.grouped(swap.fromAmount), from.displayName))
                    if !swap.toAmount.isEmpty {
                        Text(verbatim: String(format: AppLocalization.string("You got about %@ %@"),
                                              KaspaAmountEntry.grouped(swap.toAmount), to.displayName))
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            Spacer()
            if let swap {
                Button {
                    onAddToPortfolio(swap)
                } label: {
                    Label(LocalizedStringKey(swap.addedToPortfolio ? "Added to Portfolio" : "Add to Portfolio"),
                          systemImage: swap.addedToPortfolio ? "checkmark" : "chart.pie.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundColor(swap.addedToPortfolio ? .secondary : .black)
                        .background(Capsule().fill(swap.addedToPortfolio ? Color(.systemGray5) : Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(swap.addedToPortfolio)
            }
            Button {
                onDone()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 25))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .navigationTitle(Text(LocalizedStringKey(swap?.toTicker == "kas" ? "Purchase Complete" : "Sale Complete")))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A kUSDT swap Trestly's pool took: what it says, and Done.
private struct SwapSentScreen: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)
            Text("Order Sent")
                .font(.title.weight(.bold))
            Text(verbatim: message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                onDone()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .navigationTitle("Order Sent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Buying Kaspa, its own step before the amounts (owner, 2026-11-26): "Where should your Kaspa
/// land?" Through ChangeNOW: a fresh address (the default, as Buy Kaspa with Debit Card has it: an
/// exchange's coins stay apart from the username and chats) or one picked from the account's
/// addresses (`OwnAddressList`, the Chatting Address too). With kUSDT: one of the addresses
/// holding kUSDT, since Trestly's trade pays from an address and lands its Kaspa on the same one.
private struct SwapDestinationStep: View {
    let onContinue: () -> Void
    @ObservedObject private var swapService = SwapService.shared
    @ObservedObject private var tokens = TokenWallet.shared
    @State private var choosing = false
    /// The address picked under Choose an Address.
    @State private var picked: String?

    private var canContinue: Bool { swapService.isKusdt || !choosing || picked != nil }

    /// kUSDT: the Chatting Address and every address holding kUSDT, most first after it.
    private var kusdtChoices: [TrestlyTarget] {
        let held = tokens.holdings(of: .kusdt)
        var list: [TrestlyTarget] = []
        if let chatting = WalletManager.shared.currentWallet?.publicAddress {
            list.append(TrestlyTarget(label: AppLocalization.string("Chatting Address"), address: chatting, spendingIndex: nil,
                                      units: held.first(where: \.isChatting)?.units ?? 0))
        }
        for holding in held.filter({ !$0.isChatting && $0.units > 0 }).sorted(by: { $0.units > $1.units }) {
            list.append(TrestlyTarget(holding: holding))
        }
        return list
    }

    private var kusdtStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("kUSDT is paid from one address, and your Kaspa lands on that same address.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(kusdtChoices) { choice in
                let isPicked = choice.address == swapService.kusdtTarget?.address
                Button {
                    Haptics.impact(.light)
                    swapService.setKusdtFrom(choice.spendingIndex == nil ? nil : choice)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(isPicked ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: choice.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Text(verbatim: "\(choice.address.prefix(14))...\(choice.address.suffix(8))")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                            Text(verbatim: TokenAmount.amount(choice.units, token: .kusdt))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(glassBackground(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isPicked ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SendStepQuestion(text: "Where should your Kaspa land?")
                if swapService.isKusdt {
                    kusdtStep
                } else {
                HStack(spacing: 10) {
                    SelectablePill(title: "Fresh Address", selected: !choosing) {
                        choosing = false
                        picked = nil
                        swapService.useFreshToAddress()
                    }
                    SelectablePill(title: "Choose an Address", selected: choosing) {
                        choosing = true
                    }
                    Spacer(minLength: 0)
                }
                if choosing {
                    OwnAddressList(selected: picked) { source in
                        switch source {
                        case .chatting:
                            swapService.useChattingToAddress()
                        case .spending(let index, _, _):
                            swapService.selectToSpendingAddress(index: index)
                        }
                        picked = swapService.toAddress
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A new address that has never been used, so this purchase stays apart from your username and chats.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !swapService.toAddress.isEmpty {
                            Text(verbatim: swapService.toAddress.wrappingAnywhere)
                                .font(.system(.footnote, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(glassBackground(cornerRadius: 18))
                }
                }
            }
            .padding(16)
        }
        // opened to fund the chatting address: Choose an Address, the Chatting Address picked
        .onAppear {
            if swapService.toChatting, !swapService.isKusdt {
                choosing = true
                picked = swapService.toAddress
            }
        }
        .task(id: swapService.isKusdt) {
            if swapService.isKusdt { await tokens.refreshIfStale(everyAddress: true) }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Haptics.impact(.light)
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundColor(canContinue ? .black : .secondary)
                    .background(Capsule().fill(canContinue ? Color.accentColor : Color(.systemGray5)))
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .navigationTitle("Buy Kaspa")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Buy Kaspa from anywhere (the Wallet tab's Buy, a chat's "Fund your chatting address" card): the
/// half sheet of Buy Kaspa with Crypto or with Debit Card on mainnet, straight to crypto elsewhere,
/// and the screens each opens. `toChatting`: bought Kaspa is set to land on the Chatting Address.
struct BuyKaspaFlow: ViewModifier {
    @Binding var isPresented: Bool
    var toChatting = false
    @State private var showSheet = false
    @State private var afterSheet: (() -> Void)?
    @State private var swapCover: SwapView.Start?
    @State private var buyKaspaCover: BuyKaspaOpen?

    /// Anything of the flow on screen, or about to be (a sheet choice waiting to open its screen).
    private var isOpen: Bool {
        showSheet || afterSheet != nil || swapCover != nil || buyKaspaCover != nil
    }

    private func syncPresence() {
        BuyKaspaFlowPresence.shared.isOpen = isOpen
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { open in
                guard open else { return }
                isPresented = false
                if DebitCardBuy.isOffered { showSheet = true } else { swapCover = .buy }
                syncPresence()
            }
            .onChange(of: showSheet) { _ in syncPresence() }
            .onChange(of: swapCover?.id) { _ in syncPresence() }
            .onChange(of: buyKaspaCover?.id) { _ in syncPresence() }
            .onDisappear { if isOpen { BuyKaspaFlowPresence.shared.isOpen = false } }
            .sheet(isPresented: $showSheet, onDismiss: {
                let next = afterSheet
                afterSheet = nil
                next?()
                syncPresence()
            }) {
                BuyKaspaSheet(
                    onCrypto: { choose { swapCover = .buy } },
                    onDebitCard: {
                        choose {
                            DebitCardBuy.open(openSwap: { swapCover = $0 },
                                              openPage: { buyKaspaCover = BuyKaspaOpen(resume: $0) })
                        }
                    }
                )
                .fittedSheetDetents(270)
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $swapCover) { start in
                SwapView(start: start, buyToChatting: toChatting)
            }
            .fullScreenCover(item: $buyKaspaCover) { open in
                BuyKaspaView(resume: open.resume, preferChatting: toChatting)
            }
    }

    private func choose(_ next: @escaping () -> Void) {
        afterSheet = next
        showSheet = false
    }
}

/// A funding card's Buy Kaspa flow is on screen. The card's hosts (the chat composers, the "not
/// enough funds" sheet) keep the card while it is: the card goes the moment the account is funded,
/// and the flow's screens (deposit, Purchase Complete, Add to Portfolio) would close with it.
@MainActor
final class BuyKaspaFlowPresence: ObservableObject {
    static let shared = BuyKaspaFlowPresence()
    @Published var isOpen = false
}

extension View {
    func buyKaspaFlow(isPresented: Binding<Bool>, toChatting: Bool = false) -> some View {
        modifier(BuyKaspaFlow(isPresented: isPresented, toChatting: toChatting))
    }
}
