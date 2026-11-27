import SwiftUI

/// First-run guided walkthrough shown automatically right after onboarding a wallet - whether it
/// was freshly created or imported (see `WalletManager.justCreatedNewWallet`) - and replayable any
/// time from the Profile section. A step-enum-driven single-view wizard rather than a
/// `TabView`/`NavigationStack` push-per-step, since every step here is
/// simple static content plus at most one piece of live state (no per-step async work to gate on).
struct WelcomeGuideView: View {
    let onFinished: () -> Void
    /// EXPLICIT presentation context, set by the presenter - never inferred from persisted
    /// markers. True for every account-onboarding run (MainTabView's cover after a create OR
    /// import, including kill/relaunch re-presents); false only for Profile > Help replays
    /// (ContactsView). Drives skippability end to end: onboarding runs have no Skip button and
    /// no interactive dismissal all the way to Finish; replays keep both.
    var isOnboardingRun: Bool = false

    // MARK: - Onboarding-run pending marker (kill/relaunch re-present)
    //
    // The auto-present trigger (WalletManager.justCreatedNewWallet) is in-memory only, so a
    // killed import/create wizard would never come back on its own. This marker tracks "an
    // onboarding run was presented but not finished". Set only by MainTabView's first-run presentation (never by Help replays, so a
    // replay can neither set nor trigger it), cleared by the guide's Finish button - the only
    // way out of an onboarding run, since those are fully unskippable.
    static let onboardingRunPendingKey = "kachat_onboarding_wizard_pending"

    static var isOnboardingRunPending: Bool {
        UserDefaults.standard.bool(forKey: onboardingRunPendingKey)
    }

    static func markOnboardingRunPending() {
        UserDefaults.standard.set(true, forKey: onboardingRunPendingKey)
    }

    static func clearOnboardingRunPending() {
        UserDefaults.standard.removeObject(forKey: onboardingRunPendingKey)
    }

    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private enum Step: Int, CaseIterable {
        case welcome
        case language
        case currency
        case fees
        // no Fund Your Chatting Address step (owner, 2026-11-26): "5 Kaspa lets you send around
        // 2,500 messages" is on the fees step. No Connect to a Node step either (owner, same
        // day): a newcomer wouldn't know what it means, so K starts on the default node and the
        // choice lives in Settings > Connection Settings > Node.
        case addressExplainer
        /// The guide's final step (owner, 2026-11-26): share the chatting address so people can
        /// reach you.
        case shareAddress
    }

    @State private var step: Step = .welcome
    @State private var toastMessage: String?
    /// The share step's QR of the chatting address.
    @State private var shareQRImage: UIImage?
    @State private var toastToken = UUID()

    private var chattingAddress: String {
        walletManager.currentWallet?.publicAddress ?? ""
    }

    /// One step back.
    private func goBack() {
        let target: Step?
        switch step {
        case .welcome: target = nil
        default: target = Step(rawValue: step.rawValue - 1)
        }
        if let target {
            withAnimation(.easeInOut(duration: 0.2)) { step = target }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Skip exists ONLY on replays (Profile > Help). EVERY account-onboarding
                    // run - create or import, fresh or re-presented after a kill - is fully
                    // unskippable: every step must be advanced through to Finish, at which
                    // point the guide simply completes. Decided by the presenter-supplied
                    // context, not by persisted markers (see isOnboardingRun).
                    if !isOnboardingRun {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Skip") { onFinished() }
                        }
                    }
                    // Previous-step navigation lives in the bottom bar next to Next (see
                    // guideBottomBar) - only skipping forward stays forbidden.
                }
        }
        .toast(message: toastMessage)
        // Both presenters use fullScreenCover today (no swipe-down exists), but if the guide is
        // ever hosted in a sheet this keeps drag-to-dismiss off for the whole onboarding run.
        .interactiveDismissDisabled(isOnboardingRun)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            scaffold(
                icon: "hand.wave.fill",
                title: "Welcome to K",
                body: "Let's walk through the basics so you're ready to send your first message.",
                buttonTitle: "Next",
                extra: { EmptyView() }
            ) { step = .language }

        case .language:
            languageStep

        case .currency:
            currencyStep

        case .fees:
            scaffold(
                icon: "network",
                title: "How K Uses Kaspa",
                body: "K lets you send and receive messages on the Kaspa network itself. Kaspa is required to pay fees when sending your messages. The fee you pay goes to miners which secure the network. 5 Kaspa lets you send around 2,500 messages.",
                buttonTitle: "Next",
                extra: { changeChattingAddressLink }
            ) { step = .addressExplainer }

        case .addressExplainer:
            addressExplainerStep

        case .shareAddress:
            shareAddressStep
        }
    }

    // MARK: - Shared step scaffold

    /// Every fixed-content step's body goes through here. On a tall screen the two zero-length
    /// Spacers absorb the slack and the content sits vertically centred exactly as it did when
    /// this was a plain VStack; on a short one (iPhone SE at 375x667, or any device at a large
    /// Dynamic Type size) the content simply exceeds `minHeight`, the Spacers collapse and the
    /// step scrolls instead of overflowing its container and being clipped top and bottom.
    ///
    /// Deliberately NOT applied to the language / currency / Adult-Child steps: those already
    /// host their own inner ScrollView for the option list, which is the flexible element that
    /// absorbs the squeeze there - nesting a second vertical scroll view around it would fight
    /// with it for the drag gesture.
    ///
    /// The Previous/Next bar stays OUTSIDE this container so it remains fixed at the bottom.
    private func centeringScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Built ONCE here, outside the GeometryReader: its closure is @escaping, so calling a
        // non-escaping parameter inside it does not compile. Capturing the finished view is
        // also the more correct shape - the builder runs once per body pass rather than on
        // every geometry change.
        let built = content()
        return GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    built
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    @ViewBuilder
    private func scaffold(
        icon: String,
        title: String,
        body: String,
        buttonTitle: String,
        @ViewBuilder extra: () -> some View,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            centeringScroll {
                VStack(spacing: 20) {
                    Image(systemName: icon)
                        .font(.scaled(size: 56))
                        .foregroundColor(.accentColor)
                    Text(LocalizedStringKey(title))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text(LocalizedStringKey(body))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    extra()
                }
                .padding(.vertical, 24)
            }
            guideBottomBar(title: buttonTitle, action: action)
        }
    }

    // MARK: - Shared bottom bar (Previous + Next)

    /// The fixed two-button bar every step ends with: Previous on the left, Next (or Finish)
    /// on the right, always in the exact same position so the guide can be tapped through
    /// without chasing buttons. Previous goes back one step (Language returns to Welcome -
    /// backing INTO the answered Adult/Child step stays forbidden, see goBack()); on the
    /// Welcome step it renders disabled and dimmed rather than vanishing, so Next never moves.
    private func guideBottomBar(title: String = "Next", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button {
                goBack()
            } label: {
                Text("Previous")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(step == .welcome)
            .opacity(step == .welcome ? 0.35 : 1)

            Button(action: action) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// The guide is done: the one-shot import marker (the fees step's "Change Chatting Address"
    /// option) has served its purpose, and a completed onboarding run must not re-present on the
    /// next launch.
    private func finishGuide() {
        walletManager.justImportedWallet = false
        Self.clearOnboardingRunPending()
        onFinished()
    }

    // MARK: - Language step

    /// Picking a language here applies immediately, live, like the currency step below it - the
    /// whole app re-renders in the new language right away via `.environment(\.locale, ...)` in
    /// `KaChatApp.swift`, so the rest of this guide continues normally in the newly-picked
    /// language with no restart and no need to re-launch the guide from the top.
    private var languageStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe")
                .font(.scaled(size: 56))
                .foregroundColor(.accentColor)
            Text("Choose Your Language")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Select the language you'd like to use in K.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        languageRow(language)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }

            guideBottomBar { step = .currency }
        }
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = settingsViewModel.settings.language == language
        return Button {
            guard !isSelected else { return }
            settingsViewModel.settings.language = language
            settingsViewModel.saveSettings()
            settingsViewModel.applyLanguagePreference(language)
        } label: {
            HStack {
                Text(language.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Currency step

    /// Only affects the KAS price shown on the Send screens (see `KasPriceModel`) - unlike language, this takes effect immediately with no restart, so
    /// there's no restart alert here and the guide simply continues to Fees on tap.
    private var currencyStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "dollarsign.circle")
                .font(.scaled(size: 56))
                .foregroundColor(.accentColor)
            Text("Choose Your Currency")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Select the currency you'd like prices displayed in.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AppCurrency.allCases, id: \.self) { currency in
                        currencyRow(currency)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }

            guideBottomBar { step = .fees }
        }
    }

    private func currencyRow(_ currency: AppCurrency) -> some View {
        let isSelected = settingsViewModel.settings.currency == currency
        return Button {
            guard !isSelected else { return }
            settingsViewModel.settings.currency = currency
            settingsViewModel.saveSettings()
        } label: {
            HStack {
                Text(currency.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Change Chatting Address (imports only)

    /// INITIAL IMPORT ONBOARDING RUNS ONLY, never Help replays: gated on the presenter-supplied
    /// onboarding context AND the import-only marker (justImportedWallet is never set by the create
    /// flow, is in-memory only so it cannot survive a relaunch into a later replay, and is cleared
    /// on Finish). An imported seed may hold its real identity - a username, a funded chatting
    /// balance - at a nonzero derivation index. Pushes the scanner INSIDE the wizard's
    /// NavigationStack. It lived on the Fund Your Chatting Address step until that step left
    /// (owner, 2026-11-26).
    @ViewBuilder
    private var changeChattingAddressLink: some View {
        if isOnboardingRun, walletManager.justImportedWallet {
            NavigationLink {
                ChattingAddressPickerView()
            } label: {
                Label("Change Chatting Address", systemImage: "person.text.rectangle")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: - Address explainer step

    /// The tallest fixed-content step in the guide (title + illustration + two captioned address
    /// cards). On an iPhone SE it does not fit the space above the Previous/Next bar, so it goes
    /// through `centeringScroll` - unchanged and centred on roomy screens, scrollable instead of
    /// clipped on short ones.
    private var addressExplainerStep: some View {
        VStack(spacing: 0) {
            centeringScroll {
                VStack(spacing: 20) {
                    Text("Your Chatting Address")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text("Think of it like your phone number on K.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        addressMockRow(
                            icon: "bubble.left.and.bubble.right.fill",
                            title: "How People Reach You",
                            address: chattingAddress,
                            caption: "Share this address and people can message you. Only you can read what they send."
                        )
                        // a username makes the address easy to find (owner, 2026-11-26)
                        addressMockRow(
                            icon: "at",
                            title: "Get a Username",
                            address: "",
                            caption: "Claim a username, like @alice, so people can find and message you without your long address. Get one in Kaspa Hub > Usernames."
                        )
                        addressMockRow(
                            icon: "paperplane.fill",
                            title: "Paying for Messages",
                            address: "",
                            caption: "Each message you send takes a tiny amount of Kaspa from this address. 1 Kaspa covers about 500 messages."
                        )
                        addressMockRow(
                            icon: "eye.fill",
                            title: "What Others Can See",
                            address: "",
                            caption: "Anyone can see this address and its balance on the Kaspa network, but they can't read your messages. Use it only for chatting and usernames."
                        )
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 24)
            }
            guideBottomBar { step = .shareAddress }
        }
    }

    // MARK: - Share step

    /// The chatting address to share: its QR, the address, Share (Messages, Mail...) and Copy
    /// Share Link, as Profile's Share Profile has them (the same kachat.app link).
    private var shareAddressStep: some View {
        let shareURL = KaChatInternalLink.profileShareURL(for: chattingAddress)
        return scaffold(
            icon: "square.and.arrow.up",
            title: "Share Your Chatting Address",
            body: "Send it to someone so they can find and message you on K.",
            buttonTitle: "Finish",
            extra: {
                VStack(spacing: 14) {
                    Group {
                        if let shareQRImage {
                            Image(uiImage: shareQRImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))

                    Text(verbatim: chattingAddress.wrappingAnywhere)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)

                    if let shareURL {
                        HStack(spacing: 12) {
                            ShareLink(item: shareURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            Button {
                                UIPasteboard.general.string = shareURL.absoluteString
                                Haptics.success()
                                showToast(AppLocalization.string("Share link copied."))
                            } label: {
                                Label("Copy Share Link", systemImage: "link")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .onAppear {
                    shareQRImage = ProfileQRCodeCache.cachedImage(for: chattingAddress)
                    ProfileQRCodeCache.preload(address: chattingAddress) { image in
                        if let image { shareQRImage = image }
                    }
                }
            },
            action: { finishGuide() }
        )
    }

    private func addressMockRow(icon: String, title: String, address: String, caption: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                if !address.isEmpty {
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(LocalizedStringKey(caption))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Toast

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
}
