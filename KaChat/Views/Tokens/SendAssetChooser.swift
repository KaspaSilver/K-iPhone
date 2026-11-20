import SwiftUI

/// The Wallet tab's Send (owner's design, 2026-11-19): "What are you sending?" first, Kaspa or a
/// token (kUSDT), each with its balance; a tap goes on to that one's steps in the same sheet
/// (`WithdrawKaspaView` or `TokenSendView`).
struct SendAssetChooser: View {
    /// Every hot address together, as the Wallet tab's balance card shows it; nil until known.
    let kaspaTotal: UInt64?
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tokens = TokenWallet.shared

    private enum Choice: Equatable {
        case kaspa
        case token(WalletToken)
    }

    @State private var choice: Choice?

    var body: some View {
        ZStack {
            switch choice {
            case .none:
                chooser.transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            case .kaspa:
                if let wallet = walletManager.currentWallet {
                    WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi)
                        .transition(.move(edge: .trailing))
                }
            case .token(let token):
                TokenSendView(token: token)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            SendStepHeader(titleText: Text("Send"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "What are you sending?")
                    option(
                        icon: AnyView(
                            Image("KaspaLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                        ),
                        title: "Kaspa",
                        subtitle: KaspaUnit.symbol,
                        amount: kaspaTotal.map(KaspaUnit.amount)
                    ) { pick(.kaspa) }
                    ForEach(tokens.tokens) { token in
                        option(
                            icon: AnyView(TokenIcon(token: token, size: 44)),
                            title: LocalizedStringKey(token.symbol),
                            subtitle: AppLocalization.string("Bridged USDT"),
                            amount: tokens.balance(of: token).map { TokenAmount.amount($0, token: token) },
                            badge: TokenWallet.isSampleData
                        ) { pick(.token(token)) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemBackground))
        .task { await tokens.refreshIfStale() }
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func pick(_ next: Choice) {
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { choice = next }
    }

    private func option(icon: AnyView, title: LocalizedStringKey, subtitle: String, amount: String?,
                        badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if badge { TokenSampleBadge() }
                    }
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: amount ?? "--")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sendKaspaGlass(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

/// A 1:1 chat's Send Dollars (owner's design, 2026-11-20), a step of the chat's + half sheet:
/// "Which stablecoin are you sending?", each dollar token with its balance. Only kUSDT today; built as
/// a list so other stablecoins join it later. A pick goes on to `TokenSendView` with the chat as
/// the recipient. Opening it runs Discover for each one (every address through 20 past the last),
/// so kUSDT that arrived anywhere since is found on the spot.
struct DollarTokenChooser: View {
    let onPick: (WalletToken) -> Void
    let onBack: () -> Void
    @ObservedObject private var tokens = TokenWallet.shared

    private var dollarTokens: [WalletToken] { tokens.tokens.filter(\.isDollarStable) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Send Dollars")
                    .font(.headline)
                Text("Which stablecoin are you sending?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(dollarTokens) { token in
                row(token)
            }

            Button("Back", action: onBack)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Not `.task`: picking closes this sheet, which would cancel the lookups half done. The
        // From step after it waits on the same check.
        // A Discover that ran in the last 5 minutes counts: going back and forth doesn't sweep again.
        .onAppear {
            let list = dollarTokens
            Task { @MainActor in
                for token in list { await TokenWallet.shared.discoverIfStale(of: token, maxAge: 300) }
            }
        }
    }

    private func row(_ token: WalletToken) -> some View {
        let balance = tokens.balance(of: token)
        return Button {
            Haptics.impact(.light)
            onPick(token)
        } label: {
            HStack(spacing: 14) {
                TokenIcon(token: token, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: token.symbol)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if TokenWallet.isSampleData { TokenSampleBadge() }
                    }
                    Text(token.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if tokens.isDiscovering || tokens.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: balance.map { TokenAmount.amount($0, token: token) } ?? "--")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sendKaspaGlass(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}
