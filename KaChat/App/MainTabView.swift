import SwiftUI
import Combine
import UIKit

struct MainTabView: View {
    @State private var selectedTab = 1
    /// A local Core Data store failed to open (see `CoreDataStoreLoader.reportFailure`).
    @State private var storeLoadFailure: String?

    private var storeLoadFailureShown: Binding<Bool> {
        Binding(get: { storeLoadFailure != nil }, set: { if !$0 { storeLoadFailure = nil } })
    }

    private static func storeFailureMessage(from note: Notification) -> String {
        let store = note.userInfo?["store"] as? String ?? "store"
        let detail = note.userInfo?["message"] as? String ?? ""
        let what: String
        switch store {
        case "MessageStore": what = "your message history"
        case "GroupStore": what = "your group chats"
        default: what = "local data"
        }
        return "KaChat couldn't open \(what) on this device. Messages will not be saved until it can. Restarting the app usually fixes this; if it keeps happening, export diagnostics from Settings and contact support.\n\n\(detail)"
    }
    /// Debounces the off-chat-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @State private var showWelcomeGuide = false
    /// Blocking progress while the post-onboarding sync runs.
    @State private var showInitialSyncProgress = false
    @Environment(\.scenePhase) private var scenePhase
    /// Not observed. This view only CALLS into these two (start/stop polling, onboarding holds,
    /// pending routes) and renders nothing from them, but as @EnvironmentObjects every chat
    /// sync step, fetch state, conversation update and balance write re-ran the root TabView -
    /// re-applying every tab item and badge - underneath whatever screen was open.
    private var chatService: ChatService { ChatService.shared }
    private var walletManager: WalletManager { WalletManager.shared }
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The address a tapped "Received" notification opened (its history, in a sheet).
    @State private var ownAddressSheet: OwnAddressSheetTarget?
    // Red dot on the Profile tab while the bell (which lives on the Profile screen)
    // holds unread notifications.
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    /// The dock's tabs, as Customize Dock arranged them (Kaspa Hub always among them).
    @ObservedObject private var layout = DockLayout.shared
    @State private var showCustomizeDock = false

    /// The dock's TabView on its own, so `body` stays small enough for the type checker.
    private var dockTabView: some View {
        TabView(selection: tabSelection) {
            ForEach(layout.dock) { tab in
                AppTabContent(tab: tab)
                    .tabItem {
                        // one Label whose image varies (no structural if): conditional tab item
                        // content churns the tab bar's identity
                        Label {
                            Text(LocalizedStringKey(tab.label))
                        } icon: {
                            if tab == .hub, let logo = KaspaDockIcon.image {
                                logo
                            } else {
                                Image(systemName: tab.icon)
                            }
                        }
                    }
                    // Wallet shows a dot for unread notifications, Chats its unread count, Kaspa
                    // Hub what the tabs inside it hold.
                    .badge(dockBadge(for: tab))
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
        // a new arrangement gets a fresh tab bar, so every icon matches its tab
        .id(layout.dock)
    }

    var body: some View {
        dockTabView
        // The dock badges, from whichever tab is showing. Its own modifier: inline, these pushed
        // the body past what the type checker can solve.
        .modifier(DockBadgeSync(selectedTab: selectedTab, dockTabs: layout.dock))
        // KaPosts and Public Chats links, pushes and the KaPosts dock copy (its own modifier, for
        // the type checker).
        .modifier(KaPostsRoutes(show: show))
        .onReceive(NotificationCenter.default.publisher(for: .openCustomizeDock)) { _ in
            showCustomizeDock = true
        }
        .sheet(isPresented: $showCustomizeDock) {
            CustomizeDockView()
        }
        // the tab on screen left the dock: Kaspa Hub, where it now lives
        .onChange(of: layout.dock) { dock in
            if !dock.contains(where: { $0.tag == selectedTab }) {
                selectedTab = AppTab.hub.tag
                KaPostsDockRouter.shared.selectedTab = .hub
            }
        }
        .onAppear {
            LaunchTrace.mark("main tabs on screen")
            // A hold with no guide to release it would strand the account: the branches below
            // that DON'T present a guide lift it explicitly, and this covers every other path in.
            if chatService.onboardingSyncHeld && !showWelcomeGuide && !walletManager.justCreatedNewWallet {
                chatService.releaseSyncForOnboarding()
            }
            chatService.startPolling()
            // kUSDT is checked while the app is open, so a token that arrives is announced
            TokenWallet.shared.startPolling()
            // The rooms' stored messages, so the Public Chats badge counts before the list opens.
            PublicChatService.shared.primeChannelSummaries()
            preloadProfileResources()
            // A notification tapped from a cold start routed before this view existed - replay
            // its tab switch now that there's something to switch.
            consumePendingNotificationRoute()
            if walletManager.justCreatedNewWallet {
                walletManager.justCreatedNewWallet = false
                // Persisted BEFORE presenting: justCreatedNewWallet is in-memory only, so an
                // app kill mid-wizard would otherwise never bring the guide back - the pending
                // marker makes the next launch re-present it, for a create or an import alike.
                WelcomeGuideView.markOnboardingRunPending()
                showWelcomeGuide = true
            } else if WelcomeGuideView.isOnboardingRunPending {
                // Onboarding run interrupted: re-present the full guide from the top, still as
                // an unskippable onboarding run.
                showWelcomeGuide = true
            } else {
                // No setup guide is coming, so nothing is waiting on it - lift any hold rather
                // than leaving the account permanently unsynced.
                chatService.releaseSyncForOnboarding()
            }
        }
        .fullScreenCover(isPresented: $showInitialSyncProgress) {
            InitialSyncProgressModal(onDismiss: { showInitialSyncProgress = false })
        }
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(
                onFinished: {
                    showWelcomeGuide = false
                    // Everything the account owns starts syncing now, behind a sheet - a
                    // half-synced chat list invites taps on chats whose history has not landed.
                    if chatService.onboardingSyncHeld {
                        chatService.releaseSyncForOnboarding()
                        showInitialSyncProgress = true
                    }
                },
                // MainTabView only ever presents the guide for account onboarding (fresh
                // create/import or a kill/relaunch re-present) - Help replays live in
                // ContactsView, which leaves this false. Onboarding runs are fully unskippable.
                isOnboardingRun: true
            )
        }
        // The one thing here that reacts to the wallet: a switch of address. Subscribed to that
        // alone, rather than observing all of WalletManager for it. Uses the address the
        // publisher delivers: @Published emits before the property changes, so reading
        // `currentWallet` here would still see the previous wallet.
        .onReceive(
            WalletManager.shared.$currentWallet
                .map { $0?.publicAddress }
                .removeDuplicates()
                .dropFirst()
        ) { address in
            if let address { ProfileView.preloadQRCode(for: address) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            PendingTabRoute.pending = nil
            show(.chats)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProfile)) { _ in
            // Spending-address receipts: Wallet, which shows the addresses and balances.
            PendingTabRoute.pending = nil
            show(.wallet)
        }
        // Its own modifier: added to this chain inline, it pushed the body past what the type
        // checker can solve in reasonable time.
        .modifier(OwnAddressSheetPresenter(target: $ownAddressSheet, onRequest: takeOwnAddressRoute))
        // A payment request tapped or pasted anywhere: Send Kaspa with it filled in.
        .modifier(PaymentRequestSheetPresenter())
        // a .kachat name (Claim a Name, a name notification): the names tab, wherever it lives
        .onReceive(NotificationCenter.default.publisher(for: .openKachatName)) { _ in
            PendingTabRoute.pending = nil
            show(.kachatNames)
        }
        // a notification naming no post: Profile, whose bell opens the Notifications screen
        .onReceive(NotificationCenter.default.publisher(for: .openAllNotifications)) { _ in
            show(.profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { _ in
            PendingTabRoute.pending = nil
            show(.chats)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localStoreLoadFailed)) { note in
            storeLoadFailure = Self.storeFailureMessage(from: note)
        }
        .alert("Storage problem", isPresented: storeLoadFailureShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storeLoadFailure ?? "")
        }
    }

    /// The unread COUNT on the tabs that own one, and nothing on the rest.
    ///
    /// A bare dot said only "something happened". The number is the difference between
    /// deciding to look now and deciding to look later, and the dock is where that decision
    /// gets made - a badge with a space in it was the dot, and the space was the whole design.
    private func dockBadge(for tab: AppTab) -> Text? {
        AppTabBadge.dockLabel(for: tab).map { Text(verbatim: $0) }
    }


    /// Puts `tab` on screen: its dock slot, or Kaspa Hub with it open there.
    private func show(_ tab: AppTab) {
        if layout.dock.contains(tab) {
            handleTabSelectionChange(tab.tag)
        } else {
            HubRouter.shared.open(tab)
            handleTabSelectionChange(AppTab.hub.tag)
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                handleTabSelectionChange(newValue)
            }
        )
    }

    private func handleTabSelectionChange(_ newValue: Int) {
        // Kaspa Hub tapped again: back to its grid, the way out of a section opened there
        if newValue == selectedTab, newValue == AppTab.hub.tag { HubRouter.shared.close() }
        // KaPosts tapped again (or after another tab): the feed back to its top, as in KaPost
        if newValue == AppTab.kaposts.tag {
            NotificationCenter.default.post(name: .kaPostsScrollFeedToTop, object: nil)
        }
        selectedTab = newValue
        KaPostsDockRouter.shared.selectedTab = AppTab.allCases.first { $0.tag == newValue } ?? .hub

        // Off-chat-tab power saving, DEBOUNCED so rapidly flipping tabs can't thrash start/stop
        // (which was restarting the initial sync and freezing the UI). Only the settled tab - after
        // a short quiet period - pauses or resumes the node pool's aggressive discovery/probe loops
        // and the fallback message-poll timer. The pool + UTXO subscription stay live, so sending,
        // on-demand balance/history and push keep working; only background scanning stops.
        tabWorkTask?.cancel()
        tabWorkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            // Chats wants live traffic (in its dock slot, or open in Kaspa Hub).
            let chatsOnScreen = newValue == AppTab.chats.tag
                || (newValue == AppTab.hub.tag && HubRouter.shared.openSection == .chats)
            if chatsOnScreen {
                await NodePoolService.shared.resumeDiscovery()
                chatService.startPolling()
            } else {
                await NodePoolService.shared.pauseDiscovery()
                chatService.stopPollingTimerOnly()
            }
        }
    }

    // MARK: - Notification routing

    /// Cold-start replay of a notification tap's tab switch: the tap's NotificationCenter post
    /// is delivered before this view exists (the app is still on the loading/onboarding route),
    /// so its tab switch is lost while the pending target survives. The destination screens
    /// consume the target itself; this only puts the user on the tab that mounts them.
    /// Opens the address a tapped "Received" notification named, over whatever tab is showing.
    private func takeOwnAddressRoute() {
        guard let address = OwnAddressRoute.pending else { return }
        OwnAddressRoute.pending = nil
        ownAddressSheet = OwnAddressSheetTarget(address: address)
    }

    private func consumePendingNotificationRoute() {
        if OwnAddressRoute.pending != nil {
            takeOwnAddressRoute()
            return
        }
        if let tab = PendingTabRoute.pending {
            PendingTabRoute.pending = nil
            show(tab)
            return
        }
        // A KaPosts or room push or link from a cold start: KaPostsView and PublicChatListView
        // consume what is pending once they mount.
        if KaPostsDeepLink.pendingPostTxId != nil || KaPostsDeepLink.pendingOpenNotifications
            || KaPostsDeepLink.pendingOpenScheduled || KaPostsDeepLink.pendingComposeText != nil
            || KaPostsDeepLink.pendingProfileAddress != nil {
            show(.kaposts)
            return
        }
        if PublicChatService.shared.pendingPublicChatNavigation != nil {
            show(.chats)
            return
        }
        // A bot challenge tapped before the tabs were up: GamesView takes it once it mounts.
        if ChessBotLinkRouter.shared.challenge != nil {
            show(.games)
            return
        }
        if NotificationsRoute.pending {
            show(.profile)
            return
        }
        if GroupChatService.shared.pendingGroupNavigation != nil ||
            GroupChatService.shared.pendingGroupListNavigation {
            show(.chats)
        } else if chatService.pendingChatNavigation != nil ||
            chatService.pendingProfileAddress != nil {
            show(.chats)
        }
    }

    private func preloadProfileResources() {
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        ProfileView.preloadQRCode(for: address)
    }

}

#Preview {
    MainTabView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(SettingsViewModel())
}


// MARK: - Initial sync progress

/// Blocking progress shown once the setup wizard finishes, while the account's first full sync
/// runs. Nothing syncs during the wizard (see `ChatService.holdSyncForOnboarding`), so this is
/// where all of that work actually happens - and a half-populated chat list invites taps on
/// chats whose history has not arrived yet.
///
/// It is deliberately escapable. A sync can stall on a slow indexer or a bad network, and a
/// modal with no way out would be worse than an incomplete chat list, so "Continue anyway"
/// appears once it has been running a while.
private struct InitialSyncProgressModal: View {
    let onDismiss: () -> Void
    @EnvironmentObject var chatService: ChatService
    @State private var canSkip = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                if chatService.initialSyncPhase == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(.green)
                    Text("You're all set")
                        .font(.headline)
                    Text("Your chats and history are up to date.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                } else {
                    ProgressView().controlSize(.large)
                    Text("Setting up your account")
                        .font(.headline)
                    Text(AppLocalization.string(chatService.initialSyncPhase?.label ?? "Starting"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Downloading everything this account has on chain. It only takes this long once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if canSkip {
                        Button("Continue anyway", action: onDismiss)
                            .font(.subheadline)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
        .task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            canSkip = true
        }
    }
}

struct OwnAddressSheetTarget: Identifiable {
    let address: String
    var id: String { address }
}

/// One of your own addresses, opened from a tapped "Received" notification on its History tab:
/// the chatting address or a spending address, each on the same screen you'd reach it through
/// (Profile, Manage Addresses).
struct OwnAddressHistorySheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager

    private enum Resolved {
        case chatting
        case spending(SpendingAddressEntry)
        /// One of your spending addresses whose balance couldn't be read: shown as 0 it said the
        /// address was empty and turned its Send off.
        case balanceUnavailable
        case unknown
    }

    @State private var resolved: Resolved?

    var body: some View {
        NavigationStack {
            Group {
                switch resolved {
                case nil:
                    ProgressView()
                case .chatting?:
                    ChattingAddressManageView(address: address)
                case .spending(let entry)?:
                    SpendingAddressTransactionHistoryView(entry: entry)
                case .balanceUnavailable?:
                    VStack(spacing: 12) {
                        Text("Couldn't load this address's balance.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            resolved = nil
                            Task { resolved = await resolve() }
                        }
                    }
                    .padding()
                case .unknown?:
                    Text("This address isn't in this wallet any more.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { resolved = await resolve() }
    }

    /// Which of your addresses it is, with its balance for the screen's header.
    private func resolve() async -> Resolved {
        let target = address.lowercased()
        if walletManager.currentWallet?.publicAddress.lowercased() == target { return .chatting }
        var spending = walletManager.spendingAddresses(inRange: 0..<(max(0, walletManager.maxSpendingAddressIndex) + 1))
        if walletManager.maxQuantumAddressIndex >= 0 {
            let base = WalletManager.quantumIndexBase
            spending.merge(walletManager.spendingAddresses(inRange: base..<(base + walletManager.maxQuantumAddressIndex + 1))) { a, _ in a }
        }
        if let match = spending.first(where: { $0.value.lowercased() == target }) {
            // A failed read says nothing about the balance: left unknown, never shown as 0.
            guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address]) else {
                return .balanceUnavailable
            }
            let balance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            return .spending(SpendingAddressEntry(
                index: match.key,
                address: match.value,
                balanceSompi: balance,
                isCurrent: match.key == walletManager.currentSpendingAddressIndex
            ))
        }
        return .unknown
    }
}

/// Presents a tapped "Received" notification's address (`OwnAddressHistorySheet`) over the tabs.
private struct OwnAddressSheetPresenter: ViewModifier {
    @Binding var target: OwnAddressSheetTarget?
    let onRequest: () -> Void
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openOwnAddress)) { _ in
                onRequest()
            }
            .sheet(item: $target) { target in
                OwnAddressHistorySheet(address: target.address)
                    .environmentObject(ChatService.shared)
                    .environmentObject(settingsViewModel)
                    .environmentObject(WalletManager.shared)
                    .environmentObject(ContactsManager.shared)
            }
    }
}

/// KaPosts and Public Chats routes (from KaPost's dock, 2026-11-21): a post, profile or
/// notification opens the KaPosts tab, a room the Public Chats tab, a bot challenge Games,
/// wherever they live; and a
/// tab tapped on the dock copy over KaPosts' full-screen screens (`KaPostsDockCopy`) is shown
/// as a tap on the real dock.
private struct KaPostsRoutes: ViewModifier {
    let show: (AppTab) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openKaPost)) { _ in
                show(.kaposts)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openKaPostsProfile)) { _ in
                show(.kaposts)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openPublicChat)) { _ in
                // A thread or profile open over KaPosts would sit on top of the room: they close
                // first, as for a tap on the dock copy.
                NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
                show(.chats)
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaPostsSelectDockTab)) { note in
                guard let tab = note.object as? AppTab else { return }
                show(tab)
            }
            // A bot challenge from a post's card (`ChessBotLinks.open`): KaPlay, which opens Chess
            // and the bot (`ChessBotLinkRouter`). Covers over KaPosts close first, as for a room.
            .onReceive(NotificationCenter.default.publisher(for: .openGames)) { _ in
                NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
                show(.games)
            }
    }
}

/// Keeps the dock badges in step (`AppTabBadge.syncDockBadges`): Profile's dot when the bell's
/// feed changes (new messages sync them from `ChatService.updateAppBadge`), the tab changes, and on appear - set after the render that
/// triggered it, so it lands on the bar SwiftUI just updated.
private struct DockBadgeSync: ViewModifier {
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    let selectedTab: Int
    let dockTabs: [AppTab]

    func body(content: Content) -> some View {
        content
            .onReceive(notifCenter.objectWillChange) { _ in sync() }
            // KaPosts' unseen activity and the rooms' unread count
            .onReceive(KaPostsNotificationCenter.shared.$unseenCount) { _ in sync() }
            .onReceive(PublicChatUnreadBadge.shared.$count) { _ in sync() }
            .onChange(of: selectedTab) { _ in sync() }
            .onChange(of: dockTabs) { _ in sync() }
            .onAppear { sync() }
    }

    private func sync() {
        let tabs = dockTabs
        DispatchQueue.main.async {
            AppTabBadge.syncDockBadges(dockTabs: tabs)
            // the app icon too: KaPosts' and the rooms' counts change without a chat sync
            ChatService.shared.updateAppBadge()
        }
    }
}
