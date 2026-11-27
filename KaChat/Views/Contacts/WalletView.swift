import SwiftUI
import UIKit

/// The Wallet tab: everything this account holds and what you can do with it. The total up top,
/// split into the chatting and spending addresses, swiping to a card per token (kUSDT); Send,
/// Receive and Request under it; then the Chatting Address and Your Domains, as cards in the list (laid out as
/// KaPay's Wallet tab, 2026-11-19). Manage Addresses opens from the balance card's Tap to Manage.
struct WalletView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @ObservedObject private var priceModel = KasPriceModel.shared

    /// Every revealed spending address together. Nil until it's known, which shows as a dash.
    @State private var spendingTotalSompi: UInt64?
    /// The pending coalesced refresh - see `scheduleRefresh`.
    @State private var refreshTask: Task<Void, Never>?
    @State private var appearRefreshedAt: Date?
    @State private var action: WalletAction?
    @State private var showBackupHygiene = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    /// The balance card's Kaspa page, tapped: Manage Addresses, pushed.
    @State private var showManageAddresses = false
    /// A token's page of the balance card, tapped: Manage kUSDT (`TokenManageView`), pushed.
    @State private var openToken: WalletToken?
    /// Swap (owner's call, 2026-11-23: it replaced Swap Stablecoins): the agreements the first
    /// time, then the swap screen (`SwapView`), full screen, opening where this says. An item, not
    /// a flag beside a separate start: a flag's cover read the start before it was set, so Swap
    /// History opened Swap.
    @State private var swapCover: SwapView.Start?
    /// The Buy button's half sheet (`BuyKaspaSheet`, owner 2026-11-26): Buy Kaspa with Crypto or
    /// with Debit Card (mainnet; elsewhere Buy goes straight to crypto).
    @State private var showSwapChoice = false
    /// What that sheet picked, opened once it has closed.
    @State private var afterSwapChoice: (() -> Void)?
    /// Buy Kaspa with Debit Card (owner, 2026-11-26): the flow, full screen, with an order still
    /// on its way to open on its page. An item, as `swapCover`, so the order is never stale.
    @State private var buyKaspaCover: BuyKaspaOpen?
    /// The balance card's page: 0 is Kaspa, then one per token (`TokenWallet.tokens`).
    @State private var balancePage = 0
    /// The pull's address sweep is still going (it runs on after the spinner ends).
    @State private var isScanningAddresses = false
    /// The tallest page, so the swipeable card is as tall as its content.
    @State private var balanceCardHeight: CGFloat = 196
    /// .kachat names of this wallet in their grace period: the banner at the top.
    @StateObject private var expiredKachatNames = KachatExpiredNamesModel()

    private enum WalletAction: String, Identifiable {
        case send, receive, request
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PinnedListHeader(title: "Wallet")
                ScrollView {
                    if let wallet = walletManager.currentWallet {
                        content(wallet)
                    }
                }
                .refreshable { await scanAndRefresh() }
            }
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(item: $action) { action in
                switch action {
                case .send:
                    // "What are you sending?" first: Kaspa or a token
                    SendAssetChooser(kaspaTotal: totalSompi(walletManager.currentWallet))
                case .receive:
                    NavigationStack {
                        ReceiveKaspaQRView()
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { self.action = nil }
                                }
                            }
                    }
                case .request:
                    CreatePaymentRequestView()
                }
            }
            .sheet(isPresented: $showBackupHygiene) {
                BackupHygieneView()
            }
            .navigationDestination(isPresented: $showManageAddresses) {
                ManageAddressesView()
            }
            .navigationDestination(isPresented: Binding(get: { openToken != nil }, set: { if !$0 { openToken = nil } })) {
                if let openToken { TokenManageView(token: openToken) }
            }
            // a tapped "Received kUSDT" notification (`TokenRoute`): its Manage screen
            .onReceive(NotificationCenter.default.publisher(for: .openToken)) { _ in takeTokenRoute() }
            .fullScreenCover(item: $swapCover) { start in
                SwapView(start: start)
            }
            .sheet(isPresented: $showSwapChoice, onDismiss: {
                let next = afterSwapChoice
                afterSwapChoice = nil
                next?()
            }) {
                BuyKaspaSheet(
                    onCrypto: { choose { swapCover = .buy } },
                    onDebitCard: { choose { openDebitCardBuy() } }
                )
                .fittedSheetDetents(270)
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $buyKaspaCover) { open in
                BuyKaspaView(resume: open.resume)
            }
            // keeps a debit card order followed (it was the Wallet card's job)
            .task(id: walletManager.currentWallet?.publicAddress) {
                CardBuyTracker.shared.ensurePolling()
            }
            .onAppear {
                takeTokenRoute()
                priceModel.refreshIfStale()
                // Decided before the tap, so Receive opens on a code rather than a spinner.
                Task { await warmReceiveAddress() }
                // The network part at most every 30 s: switching tabs back and forth would start
                // these requests each time. Arriving funds still refresh at once, below.
                if let at = appearRefreshedAt, Date().timeIntervalSince(at) < 30 { return }
                appearRefreshedAt = Date()
                Task { await refresh(force: false) }
            }
            // its own modifier, so this chain stays within what the type checker solves
            .modifier(KachatExpiredNamesLoading(model: expiredKachatNames,
                                                address: walletManager.currentWallet?.publicAddress))
            .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
                scheduleRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ownAddressActivity)) { _ in
                scheduleRefresh()
            }
            .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
                // The total belongs to the account it was read for: a dash until the new one's lands.
                spendingTotalSompi = nil
                scheduleRefresh()
            }
        }
    }

    private func content(_ wallet: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // one of your .kachat names expired and is in grace: renew it in time (at the top of
            // the Wallet tab, as KaPay has it)
            if !expiredKachatNames.visible.isEmpty {
                KachatExpiredNamesBanner(model: expiredKachatNames)
            }
            balancePager(wallet)
            if isScanningAddresses {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning your addresses for balances…")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
            actionsRow
            if backupStatus.isHygieneDue(wallet.publicAddress) {
                BackupHygieneCard { showBackupHygiene = true }
            }
            // Testnet only: free TN10 coins for the chatting address, from the official faucet.
            if AppSettings.load().networkType == .testnet {
                TestnetFaucetClaimButton(address: wallet.publicAddress)
            }
            chattingAddressSection(wallet)
            // Request moved off the button row into the list (owner, 2026-11-26)
            listCard("Request Payment", systemImage: "doc.text") { action = .request }
            // moved here from Profile (owner's call, 2026-11-19), as KaPay's Wallet tab has it
            YourDomainsCard(onToast: { message, style in showToast(message, style: style) })
            listCard("Buy/Sell History", systemImage: "clock.arrow.circlepath") { swapCover = .history }
            // No Notifications card: they are behind Profile's bell since 2026-11-21, with KaPost's.
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: - Balance

    /// The chatting balance, as the other tabs show it.
    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        return HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text(verbatim: sompi.map(KaspaUnit.amount) ?? "-- \(KaspaUnit.symbol)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    /// Both parts or a dash: a total missing one of them would read as the whole balance.
    private func totalSompi(_ wallet: Wallet?) -> UInt64? {
        guard let chatting = wallet?.balanceSompi, let spendingTotalSompi else { return nil }
        return chatting + spendingTotalSompi
    }

    /// Total Balance, then a page per token (kUSDT), swiped between, with a pill per card under it
    /// (owner's design, 2026-11-19, as in KaPay). Each card says "Tap to Manage": Total Balance
    /// opens Manage Addresses, a token's page opens its screen.
    private func balancePager(_ wallet: Wallet) -> some View {
        let tokens = TokenWallet.shared.tokens
        return VStack(spacing: 10) {
            // Plain taps, not NavigationLinks or a long-press menu: those hold the touch a moment
            // before a swipe can have it, and swiping felt stuck.
            SlidingCardPager(pages: [
                AnyView(
                    balanceCard(wallet)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(BalanceCardHeightReader())
                        .onTapGesture {
                            Haptics.impact(.light)
                            showManageAddresses = true
                        }
                )
            ] + tokens.map { token in
                AnyView(
                    TokenBalanceCard(token: token)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(BalanceCardHeightReader())
                        .onTapGesture {
                            Haptics.impact(.light)
                            openToken = token
                        }
                )
            }, page: $balancePage)
            .frame(height: balanceCardHeight)
            .onPreferenceChange(BalanceCardHeightKey.self) { height in
                if height > 0 { balanceCardHeight = height }
            }
            BalancePagePills(titles: [AppLocalization.string("Kaspa")] + tokens.map(\.symbol), selected: $balancePage)
        }
    }

    /// Opens the token a notification named, once the tab is on screen (a push onto a stack
    /// that isn't showing yet came up blank).
    private func takeTokenRoute() {
        guard TokenRoute.pending != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let id = TokenRoute.pending else { return }
            TokenRoute.pending = nil
            openToken = TokenWallet.shared.tokens.first(where: { $0.id == id }) ?? .kusdt
        }
    }

    private func balanceCard(_ wallet: Wallet) -> some View {
        let chatting = wallet.balanceSompi
        let total = totalSompi(wallet)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Total Balance")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    TapToManageLabel()
                }
                Text(verbatim: total.map(KaspaUnit.groupedAmount) ?? "--")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let fiat = fiatText(total) {
                    Text(verbatim: fiat)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                balancePart(title: "Chatting", sompi: chatting)
                balancePart(title: "Spending", sompi: spendingTotalSompi)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func balancePart(title: LocalizedStringKey, sompi: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: sompi.map(KaspaUnit.groupedAmount) ?? "--")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the total is worth in your currency. Testnet coins aren't worth anything.
    private func fiatText(_ sompi: UInt64?) -> String? {
        guard let sompi, AppSettings.load().networkType == .mainnet,
              let price = priceModel.currentPriceUsd, price > 0 else { return nil }
        return formatFiatAmount(Double(sompi) / 100_000_000.0 * price, currency: priceModel.currentCurrency, decimals: 4)
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            actionButton(title: "Send", icon: "arrow.up") { action = .send }
            actionButton(title: "Receive", icon: "arrow.down") { action = .receive }
            // Buy and Sell, each its own button (owner, 2026-11-26); Request is a card below
            actionButton(title: "Buy", icon: "plus") {
                if DebitCardBuy.isOffered { showSwapChoice = true } else { swapCover = .buy }
            }
            actionButton(title: "Sell", icon: "minus") { swapCover = .sell }
        }
    }

    /// A Buy sheet choice, run once the sheet has closed.
    private func choose(_ next: @escaping () -> Void) {
        afterSwapChoice = next
        showSwapChoice = false
    }

    /// Buy Kaspa with Debit Card: a paid order whose kUSDT arrived goes on to Buy Kaspa with that
    /// kUSDT; one still on its way opens on its page; anything else starts a new order.
    private func openDebitCardBuy() {
        DebitCardBuy.open(openSwap: { swapCover = $0 }, openPage: { buyKaspaCover = BuyKaspaOpen(resume: $0) })
    }

    private func actionButton(title: LocalizedStringKey, icon: String, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            perform()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.scaled(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The Chatting Address's QR page, as a card in the list (as KaPay's Wallet tab has it).
    /// A row of the list under the buttons, drawn as the Chatting Address one is.
    private func listCard(_ title: LocalizedStringKey, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            perform()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
        )
    }

    private func chattingAddressSection(_ wallet: Wallet) -> some View {
        NavigationLink {
            ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
        } label: {
            HStack {
                Label("Chatting Address", systemImage: "qrcode")
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
        )
    }

    // MARK: - Loading

    /// Coalesces the bursts `.ownAddressUtxoActivity` arrives in.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }

    /// Pull to refresh (owner's call, 2026-11-20): every address scanned for what it holds, every
    /// time. The balances are read first and the spinner ends there; then Kaspa's Discover (the
    /// spending chain swept for balances and domains, any found put on Manage Addresses) and
    /// kUSDT's (every address through 20 past the last) run side by side, shown under the balance
    /// card, and the balances are read again when they finish.
    private func scanAndRefresh() async {
        await refresh(force: true)
        guard !isScanningAddresses else { return }
        withAnimation { isScanningAddresses = true }
        let account = walletManager.currentWallet?.publicAddress
        Task { @MainActor in
            async let kaspa = walletManager.discoverSpendingAddresses()
            async let tokens: Void = discoverTokens()
            _ = await (kaspa, tokens)
            if walletManager.currentWallet?.publicAddress == account { await refresh(force: true) }
            withAnimation { isScanningAddresses = false }
        }
    }

    private func discoverTokens() async {
        for token in TokenWallet.shared.tokens {
            _ = await TokenWallet.shared.discoverHoldings(of: token) { _, _ in }
        }
    }

    private func refresh(force: Bool) async {
        _ = try? await walletManager.refreshBalance(force: force)
        await loadSpendingTotal()
    }

    private func loadSpendingTotal() async {
        // A read that finishes after an account switch belongs to the old account: dropped.
        let account = walletManager.currentWallet?.publicAddress
        // The whole set, in ONE call - a per-address loop would be dozens of requests on a wallet
        // that has been used, and the node takes the list.
        let all = walletManager.allSpendingAddresses()
        // No list means the addresses couldn't be worked out, not that they hold nothing: a dash.
        guard !all.isEmpty else {
            spendingTotalSompi = nil
            return
        }
        // A failure leaves the previous total in place: a few seconds stale reads better than a
        // figure that vanishes because one request timed out.
        if let utxos = try? await NodePoolService.shared.getUtxosByAddresses(all),
           walletManager.currentWallet?.publicAddress == account {
            spendingTotalSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }

    private func warmReceiveAddress() async {
        guard let address = await walletManager.freshReceiveAddress() else { return }
        ReceiveAddressWarmCache.store(address, for: walletManager.currentWallet?.publicAddress)
        ProfileQRCodeCache.preload(address: address, completion: nil)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
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
}

/// The balance card pages' heights: the swipeable card takes the tallest.
private struct BalanceCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BalanceCardHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BalanceCardHeightKey.self, value: proxy.size.height)
        }
    }
}

/// Loads the expired-names banner (`KachatExpiredNamesModel`) for the signed-in account, and again
/// whenever the .kachat registry changes.
private struct KachatExpiredNamesLoading: ViewModifier {
    let model: KachatExpiredNamesModel
    let address: String?
    @State private var revision = 0

    func body(content: Content) -> some View {
        content
            .task(id: "\(address ?? "")-\(revision)") {
                await model.load()
            }
            .onReceive(KachatNamesRegistry.shared.$revision) { new in
                if revision != new { revision = new }
            }
    }
}

/// What Buy Kaspa with Debit Card opens with: an order still on its way, or a new one.
struct BuyKaspaOpen: Identifiable {
    let id = UUID()
    let resume: CardBuy?
}
