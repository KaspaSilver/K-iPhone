import SwiftUI

/// Buy Kaspa with Debit Card (owner, 2026-11-26): the Wallet tab's card under Your Usernames, then
/// one flow in K: which address the kUSDT lands on, Trestly's buy page (`trestly.io/buy`: Stripe
/// sells USDC into K's Ethereum address, and Trestly's bridge turns it into kUSDT on that
/// address), then Swap, set to kUSDT for KAS with what landed. Mainnet only: Trestly sells by card
/// on mainnet. `CardBuyTracker` follows the order after the page closes, so the card shows where it
/// is and offers Swap to Kaspa once the kUSDT is in.
struct BuyKaspaCard: View {
    let onOpen: (CardBuy?) -> Void
    let onSwap: (CardBuy) -> Void
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var tracker = CardBuyTracker.shared

    /// Trestly sells by card on mainnet only.
    static var isOffered: Bool { AppSettings.load().networkType == .mainnet }

    /// The order to show: only one that was paid (one never paid is dropped once Buy Kaspa closes,
    /// and never shows here, even before that check runs). A refused one shows too.
    private var shown: CardBuy? {
        guard let buy = tracker.buy, buy.paidSeen == true || buy.stage == .rejected else { return nil }
        return buy
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.impact(.light)
                // an order still on its way opens on its page; anything else starts a new one
                // a paid order still on its way opens on its page; anything else starts a new one
                if let buy = shown, !buy.isFinished { onOpen(buy) } else { onOpen(nil) }
            } label: {
                // a Label with the logo at icon size, as Your Usernames and Chatting Address are drawn,
                // so the card is the same height as theirs
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Buy Kaspa with Debit Card")
                                .foregroundColor(.primary)
                            if let buy = shown {
                                Text(verbatim: BuyKaspaStatus.line(buy))
                                    .font(.caption)
                                    .foregroundColor(buy.stage == .rejected || buy.stage == .expired ? .orange : .secondary)
                                    .lineLimit(2)
                            }
                        }
                    } icon: {
                        Image("KaspaLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let buy = shown, buy.isFinished || buy.stage == .signAgain {
                HStack(spacing: 10) {
                    if buy.stage == .arrived {
                        Button {
                            Haptics.impact(.light)
                            onSwap(buy)
                        } label: {
                            Label("Swap to Kaspa", systemImage: "arrow.left.arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 16)
                                .frame(height: 38)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    if buy.isFinished {
                        Button {
                            tracker.clear()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.regularMaterial))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Dismiss"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(glassBackground(cornerRadius: 18))
        .task(id: walletManager.currentWallet?.publicAddress) {
            tracker.ensurePolling()
        }
    }
}

/// What a purchase's stage reads as, on the card and over the page.
enum BuyKaspaStatus {
    static func line(_ buy: CardBuy) -> String {
        switch buy.stage {
        case .waitingPayment:
            return AppLocalization.string("Waiting for your payment")
        case .paid:
            return AppLocalization.string("Paid. Your USDC is on its way.")
        case .bridging:
            return AppLocalization.string("Bridging to Kaspa as kUSDT, usually about 20 minutes")
        case .arrived:
            let amount = buy.mintedUnits.map { TokenAmount.amount($0, token: .kusdt) } ?? WalletToken.kusdt.symbol
            return String(format: AppLocalization.string("%@ arrived. Swap it for Kaspa."), amount)
        case .signAgain:
            return AppLocalization.string("Open to sign the bridge again")
        case .rejected:
            return AppLocalization.string("Stripe refused this purchase. Nothing was taken.")
        case .refunded:
            return AppLocalization.string("The bridge couldn't run, so the USDC was returned. Open to bridge it again.")
        case .expired:
            return AppLocalization.string("Not paid. Nothing was taken.")
        }
    }
}

/// The flow, full screen from the Wallet tab: the address step, the page, then Swap.
struct BuyKaspaView: View {
    let resume: CardBuy?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = CardBuyTracker.shared

    private enum Step: Equatable {
        case address
        case page(TrestlyTarget, session: String?)
        case swap
    }

    @State private var step: Step
    /// Fresh Address (owner, 2026-11-26: "so kUSDT lands in a fresh address") or the Chatting Address.
    @State private var useFresh = true
    /// The next unused regular address (`TokenWallet.freshReceiveAddress`), revealed on Continue.
    @State private var fresh: FreshAddress?
    /// K's Ethereum address for this account; nil when its words aren't on this phone.
    @State private var ethereumAddress: String?
    @State private var checkedWords = false

    init(resume: CardBuy?) {
        self.resume = resume
        _step = State(initialValue: resume.map { .page($0.target, session: $0.session) } ?? .address)
    }

    var body: some View {
        ZStack {
            switch step {
            case .address:
                addressStep
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            case .page(let target, let session):
                if let ethereumAddress {
                    CardBuyBrowserView(target: target, session: session, ethereumAddress: ethereumAddress,
                                       onClose: { dismiss() }, onSwap: { swap($0) })
                        .transition(.move(edge: .trailing))
                } else if checkedWords {
                    noWords
                } else {
                    ProgressView()
                }
            case .swap:
                SwapView()
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            tracker.screenOpen = true
            if !checkedWords {
                ethereumAddress = EthereumAccount.address()
                checkedWords = true
            }
            if fresh == nil, let next = TokenWallet.shared.freshReceiveAddress() {
                fresh = FreshAddress(index: next.index, address: next.address)
            }
        }
        .onDisappear { tracker.screenOpen = false }
    }

    private func swap(_ buy: CardBuy) {
        guard let units = buy.mintedUnits else { return }
        SwapService.shared.prepareKusdtSell(from: buy.target, units: units)
        tracker.clear()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = .swap }
    }

    private struct FreshAddress {
        let index: Int
        let address: String
    }

    private var canContinue: Bool {
        ethereumAddress != nil && (!useFresh || fresh != nil)
    }

    private var addressStep: some View {
        SendStepScreen(title: Text("Buy Kaspa"), onCancel: { dismiss() }, continueTitle: "Continue",
                       canContinue: canContinue) {
            let target: TrestlyTarget
            if useFresh {
                guard let fresh else { return }
                target = TrestlyTarget(label: String(format: AppLocalization.string("Address #%lld"),
                                                     WalletManager.addressNumber(forIndex: fresh.index)),
                                       address: fresh.address, spendingIndex: fresh.index)
                // not put on Manage Addresses' list yet: only once an order to it is paid
                // (`CardBuyTracker`), so opening Buy Kaspa and leaving doesn't use up an address
            } else {
                guard let address = WalletManager.shared.currentWallet?.publicAddress else { return }
                target = TrestlyTarget(label: AppLocalization.string("Chatting Address"), address: address, spendingIndex: nil)
            }
            TokenWallet.shared.noteReceiveAddressShown(target.address)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = .page(target, session: nil) }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Where should your kUSDT land?")
                    HStack(spacing: 10) {
                        SelectablePill(title: "Fresh Address", selected: useFresh) {
                            useFresh = true
                        }
                        SelectablePill(title: "Chatting Address", selected: !useFresh) {
                            useFresh = false
                        }
                    }
                    if useFresh {
                        addressCard(title: fresh.map {
                            String(format: AppLocalization.string("Address #%lld"), WalletManager.addressNumber(forIndex: $0.index))
                        } ?? AppLocalization.string("Fresh Address"), address: fresh?.address,
                                    note: "A new address that has never been used, so this purchase stays apart from your username and chats.")
                    } else if let wallet = WalletManager.shared.currentWallet {
                        addressCard(title: AppLocalization.string("Chatting Address"), address: wallet.publicAddress,
                                    note: "The address people message and pay you on.")
                    }
                    if checkedWords && ethereumAddress == nil {
                        Text("K needs this account's recovery words on this phone to buy with a card.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Stripe sells to buyers in the US and the EU. The card fee and network fees show on the next page, before you pay.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    private func addressCard(title: String, address: String?, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
            if let address {
                Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(note)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 16))
    }

    private var noWords: some View {
        VStack(spacing: 16) {
            Text("K needs this account's recovery words on this phone to buy with a card.")
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(.headline)
        }
        .padding(24)
    }
}

/// Trestly's buy page inside K: Close, the site, which address the kUSDT lands on, the page with
/// K's Kaspa side (`TrestlyProvider`, for that address) and Ethereum side
/// (`CardBuyEthereumProvider`), and once the order is paid, where it is, with Swap to Kaspa when
/// the kUSDT is in.
struct CardBuyBrowserView: View {
    let target: TrestlyTarget
    let session: String?
    let onClose: () -> Void
    let onSwap: (CardBuy) -> Void
    @StateObject private var provider: TrestlyProvider
    @StateObject private var ethereum: CardBuyEthereumProvider
    @ObservedObject private var tracker = CardBuyTracker.shared
    @State private var isLoading = true
    @StateObject private var reloader = WebPageReloader()

    init(target: TrestlyTarget, session: String?, ethereumAddress: String,
         onClose: @escaping () -> Void, onSwap: @escaping (CardBuy) -> Void) {
        self.target = target
        self.session = session
        self.onClose = onClose
        self.onSwap = onSwap
        let site = TrestlyBrowserView.siteURL
        _provider = StateObject(wrappedValue: TrestlyProvider(target: target, siteURL: site))
        _ethereum = StateObject(wrappedValue: CardBuyEthereumProvider(target: target, siteURL: site, address: ethereumAddress))
    }

    /// `/buy`, or an order already on its way (`/buy?session=`), which the page shows as it goes.
    private var url: URL {
        let buy = TrestlyBrowserView.siteURL.appendingPathComponent("buy")
        guard let session, var components = URLComponents(url: buy, resolvingAgainstBaseURL: false) else { return buy }
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url ?? buy
    }

    /// The order this page made, once it's paid (before that the page itself is the whole story).
    private var followed: CardBuy? {
        guard let buy = tracker.buy, buy.address == target.address, buy.paidSeen == true else { return nil }
        return buy
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text(verbatim: TrestlyBrowserView.siteURL.host ?? "trestly.io")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(.secondary)
                Spacer(minLength: 0)
                WebPageRefreshButton(isLoading: isLoading, size: 40, tint: .accentColor) { reloader.reload() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)

            HStack(spacing: 8) {
                Image("KaspaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text(verbatim: String(format: AppLocalization.string("kUSDT lands on: %@"), target.label))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(verbatim: "\(target.address.prefix(14))...\(target.address.suffix(6))")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))

            TrestlyWebView(url: url, provider: provider, ethereum: ethereum, reloader: reloader, isLoading: $isLoading)
                // the web view moves its own page for the keyboard; SwiftUI shrinking it as well made
                // the page jump on every tap in Stripe's card and code fields, so Paste, AutoFill and
                // a texted code couldn't land (owner, 2026-11-26)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            if let buy = followed {
                statusBar(buy)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: followed?.stage)
        .toast(message: provider.banner)
        .sheet(item: $ethereum.pending) { request in
            CardBuySignSheet(request: request) { approved in
                ethereum.pending = nil
                request.respond(approved)
            }
            .onDisappear { request.respond(false) }
        }
        .sheet(item: $provider.approval) { request in
            TrestlyApprovalSheet(request: request) { approved in
                provider.approval = nil
                request.respond(approved)
            }
            .onDisappear { request.respond(false) }
        }
        .onDisappear {
            provider.close()
            ethereum.close()
        }
    }

    private func statusBar(_ buy: CardBuy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if buy.stage == .arrived {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if !buy.isFinished {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: BuyKaspaStatus.line(buy))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if buy.stage == .arrived {
                Button {
                    Haptics.impact(.light)
                    onSwap(buy)
                } label: {
                    Label("Swap to Kaspa", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            } else if !buy.isFinished {
                Text("You can close this. K keeps following your order on the Wallet tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.bar)
    }
}

/// The one Ethereum signature Buy Kaspa asks for: the USDC permit that lets Trestly's bridge move
/// the USDC to Kaspa. Shown only once `PermitRequest.parse` has checked it.
struct CardBuySignSheet: View {
    let request: PermitRequest
    let onAnswer: (Bool) -> Void

    var body: some View {
        SendStepScreen(title: Text("Approve the Bridge"), onCancel: { onAnswer(false) },
                       continueTitle: "Approve", canContinue: true) {
            onAnswer(true)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "signature")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        Text("One signature lets Trestly's bridge take up to this much USDC from K's Ethereum address and deposit it to Kaspa as kUSDT. No ETH is needed, and no Kaspa leaves your wallet.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sendKaspaGlass(cornerRadius: 16))

                    VStack(spacing: 0) {
                        row("Up to") { Text(verbatim: request.amountText).font(.subheadline.monospacedDigit().weight(.semibold)) }
                        Divider()
                        row("kUSDT lands on") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: request.target.label)
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: "\(request.target.address.prefix(14))...\(request.target.address.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                        Divider()
                        row("Ends") {
                            Text(request.deadline, style: .time)
                                .font(.subheadline)
                        }
                        Divider()
                        row("Bridge") {
                            Text(verbatim: "\(request.spender.prefix(8))...\(request.spender.suffix(6))")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(sendKaspaGlass(cornerRadius: 16))

                    Text("K's Ethereum address comes from this account's words, as any Ethereum wallet would make it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled(false)
    }

    private func row<Value: View>(_ title: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            value()
        }
        .padding(.vertical, 12)
    }
}
