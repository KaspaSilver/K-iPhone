import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    /// Bumped on every sign-out, so the next account gets new tabs. Without it SwiftUI brought the
    /// old tabs back as they were: on Profile (where Log Out is), without an onAppear to start
    /// polling for the new account.
    @State private var signInSession = 0
    /// The version of the Terms of Use last agreed to on this device (since 2026-11-21, with
    /// KaPosts and Public Chats back: App Store guideline 1.2).
    @AppStorage(KaChatTerms.acceptedVersionKey) private var acceptedTermsVersion = 0

    var body: some View {
        if acceptedTermsVersion >= KaChatTerms.currentVersion {
            accountContent
        } else {
            TermsAcceptanceView { acceptedTermsVersion = KaChatTerms.currentVersion }
        }
    }

    private var accountContent: some View {
        Group {
            if walletManager.isSwitchingAccount && walletManager.currentWallet == nil {
                // Between one account's Log Out and the next one's sign-in: the globe, never
                // the sign-in screen (a failed switch ends here and shows that screen with why).
                LoadingView()
            } else {
                routedContent
            }
        }
        .animation(
            .easeInOut,
            value: walletManager.currentWallet != nil && !walletManager.isAwaitingSeedPhraseConfirmation
        )
        .onChange(of: walletManager.currentWallet == nil) { signedOut in
            if signedOut { signInSession += 1 }
        }
        .onAppear { LaunchTrace.mark("first screen on") }
    }

    @ViewBuilder
    private var routedContent: some View {
        Group {
            switch LaunchRouter.route(
                isWalletMetadataLoading: walletManager.isLoading,
                hasCurrentWallet: walletManager.currentWallet != nil,
                isPendingSeedPhraseConfirmation: walletManager.isAwaitingSeedPhraseConfirmation,
                needsKeyRecovery: walletManager.walletNeedingKeyRecovery != nil
            ) {
            case .loading:
                LoadingView()
            case .mainApp:
                MainTabView()
                    .id(signInSession)
            case .onboarding:
                OnboardingView()
            case .recovery:
                if let wallet = walletManager.walletNeedingKeyRecovery {
                    WalletRecoveryView(wallet: wallet)
                } else {
                    OnboardingView()
                }
            }
        }
    }
}

/// What a cold launch shows while the account loads: the launch screen's K globe (Info.plist's
/// `UILaunchScreen`: `KLogo` at its own 120 pt, centred on `LaunchBackground`), in the same
/// place and size, so the launch screen hands over without a jump. The spinner sits under it.
struct LoadingView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
            Image("KLogo")
                .resizable()
                .frame(width: 120, height: 120)
                .accessibilityLabel(Text(verbatim: "K"))
            ProgressView()
                .offset(y: 100)
                .accessibilityLabel(Text("Loading..."))
        }
        // The launch screen centres the globe on the whole screen, not the safe area.
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(SettingsViewModel())
}
