import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Swap, from the Wallet tab's Swap button (back 2026-11-23): KAS for kUSDT through Trestly's pool
/// on Kaspa, KAS for coins on other networks through ChangeNOW (see SwapService). Opens on the two
/// third-party agreements (`SwapAgreementsView`) until both are accepted. Structure mirrors
/// Android's SwapScreen (amount cards, flip control, swap history) in this app's glass cards.
struct SwapView: View {
    @ObservedObject private var swapService = SwapService.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @State private var showKusdtFromPicker = false

    private enum Tab: Int { case swap, history }
    @State private var selectedTab: Tab = .swap

    @State private var selectedSwap: SwapTransaction?
    @State private var showToAddressPicker = false
    @State private var showCoinPicker = false
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
        if swapService.agreementsAccepted {
            swapScreen
        } else {
            SwapAgreementsView(onCancel: { dismiss() }, onAccept: { swapService.acceptAgreements() })
        }
    }

    private var swapScreen: some View {
        NavigationStack {
            VStack(spacing: 0) {
                swapTabBar

                TabView(selection: $selectedTab) {
                    swapFormPage
                        .tag(Tab.swap)
                    swapHistoryPage
                        .tag(Tab.history)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Swap")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
            }
            .toast(message: toastMessage)
            // a kUSDT swap that went through
            .onChange(of: swapService.notice) { notice in
                guard let notice else { return }
                showToast(notice)
                swapService.notice = nil
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
            .onChange(of: swapService.createSwapState.status) { status in
                if status == .success {
                    showToast("Swap started")
                } else if status == .failed {
                    showToast(swapService.createSwapState.errorMessage ?? "Swap failed")
                }
            }
            .sheet(item: $selectedSwap) { swap in
                SwapDetailView(swap: swap) {
                    guard let prefill = swapService.portfolioPrefill(for: swap) else {
                        showToast("Couldn't read this swap's amounts")
                        return
                    }
                    pendingPortfolioPrefill = prefill
                    pendingPortfolioSwapId = swap.id
                    selectedSwap = nil
                    showPortfolioConfirm = true
                }
            }
            .sheet(isPresented: $showToAddressPicker) {
                SwapAddressPickerView { entry in
                    swapService.selectToSpendingAddress(index: entry.index)
                }
            }
            .sheet(isPresented: $showCoinPicker) {
                SwapCoinPickerView(currentCoin: swapService.otherCoin) { coin in
                    swapService.setOtherCoin(coin)
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

    // MARK: - Page switch (the app's cycle button, `PageCycleBar`, 2026-11-24)

    private var swapTabBar: some View {
        PageCycleBar(tabs: [(tab: Tab.swap, title: "Swap"), (tab: Tab.history, title: "Swap History")],
                     selection: $selectedTab)
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
                    label: "You Send",
                    coin: swapService.fromCoin,
                    amountText: swapService.amountText,
                    field: .amount,
                    isQuoting: swapService.editedSide == .get && swapService.estimateState.status == .loading,
                    onAmountChange: { swapService.setAmountText($0) },
                    onMaxTap: nil
                )

                HStack(spacing: 12) {
                    Button {
                        swapService.flipDirection()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.black)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch direction"))

                    Button {
                        swapService.executeSwap()
                    } label: {
                        Group {
                            if isBusy {
                                ProgressView().tint(.black)
                            } else {
                                Text(swapButtonTitle)
                                    .fontWeight(.bold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .foregroundColor(canSwap ? .black : .secondary)
                        .background(Capsule().fill(canSwap ? Color.accentColor : Color(.systemGray5)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSwap)
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

                if swapService.isKusdt {
                    spendingAddressRow(
                        title: swapService.kasIsSendSide ? "Swap From (kUSDT Lands Here)" : "Swap From (KAS Lands Here)",
                        valueText: swapService.kusdtTarget.map { "\($0.label) \u{00B7} \(shortAddress($0.address))" } ?? "",
                        feeText: nil,
                        onFeeTap: nil,
                        onChangeTap: { showKusdtFromPicker = true }
                    )
                } else if !swapService.kasIsSendSide {
                    spendingAddressRow(
                        title: "Receiving KAS At",
                        valueText: swapService.toAddress.count > 20
                            ? "\(swapService.toAddress.prefix(12))...\(swapService.toAddress.suffix(6))"
                            : swapService.toAddress,
                        feeText: nil,
                        onFeeTap: nil,
                        onChangeTap: { showToAddressPicker = true }
                    )
                }

                rateCard

                if !swapService.isKusdt, let created = swapService.createSwapState.result {
                    swapResultCard(created)
                }

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

    private var swapButtonTitle: LocalizedStringKey { swapService.isKusdt ? "Swap" : "Get Deposit Address" }

    /// One sentence per side, so each language words it whole (audit 2026-11-24 #34).
    private func portfolioPrompt(_ prefill: SwapService.PortfolioPrefill) -> Text {
        let amount = formatKasTrimmed(UInt64((prefill.amountKas * 100_000_000).rounded()))
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

    /// The deposit card, drawn from the exchange ChangeNOW created (its coins, amount, addresses
    /// and tag), never from the coins picked now (audit 2026-11-24 #2). Its status is the live
    /// history entry's, so Refresh Status shows.
    private func swapResultCard(_ created: SwapService.CreatedSwap) -> some View {
        let swap = swapService.history.first { $0.id == created.transaction.id } ?? created.transaction
        return VStack(alignment: .leading, spacing: 10) {
            if created.fromCoin == .kas {
                NavigationLink {
                    ManageAddressesView()
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Go to Spending Addresses")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.accentColor)
                }
                .padding(.bottom, 2)
            }

            Text("Send \(created.fromCoin.displayName) to this address")
                .font(.subheadline.weight(.bold))

            VStack(alignment: .leading, spacing: 2) {
                Text("Amount to Send")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(verbatim: "\(swap.fromAmount) \(created.fromCoin.displayName)")
                    .font(.title3.weight(.bold))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                if let qrImage = makeQRCodeImage(from: swap.payinAddress) {
                    Button {
                        UIPasteboard.general.string = swap.payinAddress
                        Haptics.success()
                        showToast(swap.payinAddress.addressCopiedToastText)
                    } label: {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            Button {
                UIPasteboard.general.string = swap.payinAddress
                Haptics.success()
                showToast(swap.payinAddress.addressCopiedToastText)
            } label: {
                Text(verbatim: swap.payinAddress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            if let tag = swap.payinExtraId, !tag.isEmpty {
                SwapDepositTagBox(tag: tag) {
                    UIPasteboard.general.string = tag
                    Haptics.success()
                    showToast("Destination tag copied")
                }
            }

            // where ChangeNOW pays out, as it answered (audit 2026-11-24 #6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Payout Address")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(verbatim: swap.payoutAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                if let payoutTag = swap.payoutExtraId, !payoutTag.isEmpty {
                    Text("Destination Tag: \(payoutTag)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("Status: \(swapStatusName(swap.status))")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("ChangeNOW Exchange ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    UIPasteboard.general.string = swap.id
                    Haptics.success()
                    showToast("Exchange ID copied")
                } label: {
                    Text(verbatim: swap.id)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("Refresh Status") {
                    swapService.refreshSwapStatus(id: swap.id)
                }
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)

                Spacer()

                if let url = URL(string: "https://changenow.io/exchange/txs/\(swap.id)") {
                    Link("View on ChangeNOW", destination: url)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
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
        editable: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                if isQuoting {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("0.00", text: Binding(get: { amountText }, set: onAmountChange))
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

    /// Only the non-KAS side of the pair is actually pickable - KAS is always the fixed side.
    private func coinBadge(_ coin: SwapCoin) -> some View {
        Group {
            if coin.ticker == "kas" {
                coinBadgeContent(coin)
            } else {
                Button {
                    showCoinPicker = true
                } label: {
                    HStack(spacing: 4) {
                        coinBadgeContent(coin)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
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
                Text(verbatim: "\(swap.fromAmount) \(swap.fromTicker.uppercased()) \u{2192} \(formatDecimalString(swap.toAmount)) \(swap.toTicker.uppercased())")
                    .font(.subheadline.weight(.bold))
                Text(swap.createdAt, style: .date)
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
                        Text(verbatim: "\(swap.fromAmount) \(swap.fromTicker.uppercased()) \u{2192} \(formatDecimal(swap.toAmount)) \(swap.toTicker.uppercased())")
                            .font(.headline)
                        Text(swap.createdAt, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

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

                Section("Deposit Address") {
                    Button {
                        UIPasteboard.general.string = swap.payinAddress
                        Haptics.success()
                        showToast(swap.payinAddress.addressCopiedToastText)
                    } label: {
                        Text(verbatim: swap.payinAddress)
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
                        Text(verbatim: swap.payoutAddress)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    if let payoutTag = swap.payoutExtraId, !payoutTag.isEmpty {
                        Text("Destination Tag: \(payoutTag)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

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
                    Button {
                        guard !isRefreshingStatus else { return }
                        isRefreshingStatus = true
                        Task {
                            let status = await SwapService.shared.refreshSwapStatusAsync(id: swap.id)
                            isRefreshingStatus = false
                            showToast(status.map { String(format: AppLocalization.string("Status: %@"), swapStatusName($0)) }
                                      ?? "Couldn't reach ChangeNOW - try again")
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
                    if let url = URL(string: "https://changenow.io/exchange/txs/\(swap.id)") {
                        Link("View on ChangeNOW", destination: url)
                            .foregroundColor(.accentColor)
                    }
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

/// Lightweight spending-address picker for Swap's "Change" rows - not the full Manage Addresses
/// screen (this only needs tap-to-pick, no rename/hide/withdraw actions).
private struct SwapAddressPickerView: View {
    let onPick: (SpendingAddressEntry) -> Void

    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    /// The address whose action sheet is up.
    @State private var actionTarget: SpendingAddressEntry?

    /// What the list offers. A swap payout goes to a FRESH address - reusing one publishes the
    /// link between this swap and everything that address has already done - so used ones are
    /// filtered out rather than merely marked. The badge stays on each row anyway: the used flag
    /// is filled in by a network check that can fail, and an unlabelled row would be a silent
    /// claim this code cannot always back up.
    private var selectableEntries: [SpendingAddressEntry] {
        entries.filter { !$0.hidden && !$0.everUsed }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Button {
                                generateNewAddress()
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Generate New Address")
                                    Spacer()
                                    if isGenerating {
                                        ProgressView()
                                    }
                                }
                                .foregroundColor(.accentColor)
                            }
                            .disabled(isGenerating)
                        } footer: {
                            Text("A swap pays out to an address you have not used before, so the payout cannot be tied to your earlier activity. Generate one if none are free.")
                        }

                        Section {
                            if selectableEntries.isEmpty {
                                Text("Every address here has been used. Generate a new one above.")
                                    .foregroundColor(.secondary)
                            }
                            ForEach(selectableEntries) { entry in
                                Button {
                                    // Tapping asks what to do with the address rather than
                                    // committing outright - the explorer used to be behind an
                                    // ellipsis menu nobody would find.
                                    actionTarget = entry
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(entry.displayLabel)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                usedBadge(for: entry)
                                            }
                                            Text(entry.shortAddress)
                                                .font(.system(.subheadline, design: .monospaced))
                                                .foregroundColor(.primary)
                                        }
                                        Spacer()
                                        Text(verbatim: "\(formatKas(entry.balanceSompi)) KAS")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Unused Addresses")
                        }
                    }
                }
            }
            .navigationTitle("Choose Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await loadEntries()
            }
            .sheet(item: $actionTarget) { entry in
                addressActionsSheet(entry)
            }
        }
    }

    @ViewBuilder
    private func usedBadge(for entry: SpendingAddressEntry) -> some View {
        Text(entry.everUsed ? "Used" : "Unused")
            .font(.caption2.weight(.semibold))
            .foregroundColor(entry.everUsed ? .orange : .green)
    }

    /// Tap an address: look at it first, or take it. Replaces an ellipsis menu whose only item
    /// was the explorer.
    private func addressActionsSheet(_ entry: SpendingAddressEntry) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(entry.displayLabel)
                    .font(.headline)
                Text(entry.shortAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address) {
                ActionSheetRow(
                    title: "View in Explorer",
                    subtitle: "Check its history before you send a swap to it.",
                    systemImage: "safari"
                ) {
                    actionTarget = nil
                    UIApplication.shared.open(url)
                }
            }
            ActionSheetRow(
                title: "Use for This Swap",
                subtitle: "ChangeNOW pays the swapped KAS out to this address.",
                systemImage: "arrow.down.circle"
            ) {
                actionTarget = nil
                onPick(entry)
                dismiss()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    private func loadEntries() async {
        isLoading = true
        entries = await walletManager.getSpendingAddressList()
        isLoading = false
    }

    private func generateNewAddress() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            await walletManager.generateNextSpendingAddress()
            await loadEntries()
            isGenerating = false
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
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
func swapCoinIcon(_ coin: SwapCoin) -> some View {
    if coin.isTrestly {
        TokenIcon(token: .kusdt, size: 20)
    } else if coin.ticker == "kas" {
        Image("KaspaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
    } else if let assetName = swapCoinLogoAssetNames[coin.ticker] {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .clipShape(Circle())
    } else {
        Text(coin.ticker.uppercased())
            .font(.scaled(size: 8, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.accentColor.opacity(0.3)))
    }
}

/// Reached by tapping either amount card's coin badge (the non-KAS side only - KAS is always the
/// fixed side of the pair). Searchable since `SwapCoin.curated` now has ~50 entries across many
/// networks, not just the one hardcoded USDC-Polygon pair this originally shipped with.
private struct SwapCoinPickerView: View {
    let currentCoin: SwapCoin
    let onPick: (SwapCoin) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var expandedGroups: Set<String> = []

    /// Tickers with more than one network - collapsed to a single row on the root list that
    /// expands in place to show its networks (rather than listing all ~7-9 networks inline
    /// unconditionally), since that's most of what made the flat list unwieldy. Keyed by ticker,
    /// valued by the short name shown for the collapsed row.
    private static let groupedTickers: [String: String] = [
        "usdt": "Tether",
        "usdc": "USD Coin"
    ]

    private enum PickerRow: Identifiable {
        case coin(SwapCoin)
        case group(ticker: String, displayName: String)
        case network(SwapCoin)

        var id: String {
            switch self {
            case .coin(let coin): return "\(coin.ticker)-\(coin.network)"
            case .group(let ticker, _): return "group-\(ticker)"
            case .network(let coin): return "network-\(coin.ticker)-\(coin.network)"
            }
        }
    }

    /// USDC and USDT are pinned as the first two rows (in that order) since they're the most
    /// commonly swapped stablecoins - everything else follows in `SwapCoin.curated`'s order.
    private static let pinnedGroupTickers = ["usdc", "usdt"]

    private var rootRows: [PickerRow] {
        // kUSDT first: K swaps it itself, on Kaspa, through Trestly's pool
        var rows: [PickerRow] = [.coin(.kusdt)]
        for ticker in Self.pinnedGroupTickers {
            guard let displayName = Self.groupedTickers[ticker] else { continue }
            rows.append(.group(ticker: ticker, displayName: displayName))
            if expandedGroups.contains(ticker) {
                for coin in SwapCoin.curated where coin.ticker == ticker {
                    rows.append(.network(coin))
                }
            }
        }
        for coin in SwapCoin.curated where Self.groupedTickers[coin.ticker] == nil {
            rows.append(.coin(coin))
        }
        return rows
    }

    private var filteredRows: [PickerRow] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return rootRows }
        let query = searchText.lowercased()
        return rootRows.filter { row in
            switch row {
            case .coin(let coin):
                return coin.displayName.lowercased().contains(query) || coin.ticker.lowercased().contains(query)
            case .group(let ticker, let displayName):
                return displayName.lowercased().contains(query) || ticker.lowercased().contains(query)
            case .network(let coin):
                return coin.displayName.lowercased().contains(query) || coin.ticker.lowercased().contains(query)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredRows) { row in
                switch row {
                case .coin(let coin):
                    Button {
                        onPick(coin)
                        dismiss()
                    } label: {
                        pickerRow(icon: { swapCoinIcon(coin) }, title: coin.displayName, isSelected: coin == currentCoin)
                    }
                    .buttonStyle(.plain)
                case .group(let ticker, let displayName):
                    // Icon only depends on `.ticker`, so any curated entry sharing this ticker
                    // works as the representative icon for the collapsed row.
                    let representative = SwapCoin.curated.first { $0.ticker == ticker }
                    let isExpanded = expandedGroups.contains(ticker)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                expandedGroups.remove(ticker)
                            } else {
                                expandedGroups.insert(ticker)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if let representative {
                                swapCoinIcon(representative)
                            }
                            Text(displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if currentCoin.ticker == ticker {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .network(let coin):
                    Button {
                        onPick(coin)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Spacer().frame(width: 28)
                            swapCoinIcon(coin)
                            Text(coin.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if coin == currentCoin {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search coins")
            .navigationTitle("Choose Coin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pickerRow<Icon: View>(icon: () -> Icon, title: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            icon()
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
