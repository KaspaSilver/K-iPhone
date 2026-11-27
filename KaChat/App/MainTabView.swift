import SwiftUI
import Combine
import UIKit
import UserNotifications

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
        return "K couldn't open \(what) on this device. Messages will not be saved until it can. Restarting the app usually fixes this; if it keeps happening, export diagnostics from Settings and contact support.\n\n\(detail)"
    }
    /// Debounces the off-chat-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @State private var showWelcomeGuide = false
    /// Kaspa Hub's glass menu over the dock's left side (`KaspaHubMenu`, owner 2026-11-26).
    @State private var showHubMenu = false
    /// The dock tab you were on before a Hub section opened: where its close (Kasshi's X) goes back.
    @State private var tabBeforeHub = AppTab.chats.tag
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
    // Not observed here: nothing in this view read it, so every bell entry redrew the root.
    // The dock's badges follow it through `DockBadgeSync` (audit 2026-11-24 #29).
    /// The dock's tabs, as Customize Dock arranged them (Kaspa Hub always among them).
    @ObservedObject private var layout = DockLayout.shared
    /// The dot on the dock's Settings icon (owner's call, 2026-11-23). Publishes only when the
    /// color changes.
    @ObservedObject private var connection = ConnectionHealth.shared
    /// The yellow dot on the dock's Profile icon while the account's backup is owed.
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @Environment(\.colorScheme) private var colorScheme
    /// Your avatar for the Profile tab's icon (the person glyph until you have one).
    @ObservedObject private var dockAvatar = DockAvatar.shared

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
                            } else if tab == .profile {
                                // your picture, with a yellow dot while the backup is owed
                                Image(uiImage: ProfileDockIcon.image(
                                    avatar: dockAvatar.image,
                                    avatarKey: dockAvatar.shownKey,
                                    backupOwed: backupStatus.isPending(WalletManager.shared.currentWallet?.publicAddress),
                                    selected: selectedTab == tab.tag,
                                    dark: colorScheme == .dark))
                            } else if tab == .settings {
                                // the gear with the connection dot: green connected, red not
                                Image(uiImage: SettingsDockIcon.image(dot: connection.uiColor,
                                                                      selected: selectedTab == tab.tag,
                                                                      dark: colorScheme == .dark))
                            } else if tab == .kachatNames {
                                // the ".kachat" wordmark, small enough to sit between the tabs
                                Image(uiImage: KachatTabIcon.image(side: 24, fontScale: 0.42))
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
        // Kaspa Hub's glass menu, rising from the dock's left side like iMessage's + (owner,
        // 2026-11-26); a section picked opens as a Hub section, the dock in view with Kaspa Hub
        // lit, and Kaspa Hub tapped again brings the menu back
        .overlay {
            KaspaHubMenu(isPresented: $showHubMenu) { tab in
                openHubSection(tab)
            }
        }
        // a section closed (Kasshi's X): back to the tab you came from, never a Hub screen
        .onReceive(HubRouter.shared.$openSection) { section in
            guard section == nil, selectedTab == AppTab.hub.tag else { return }
            handleTabSelectionChange(tabBeforeHub)
        }
        // The dock badges, from whichever tab is showing. Its own modifier: inline, these pushed
        // the body past what the type checker can solve.
        .modifier(DockBadgeSync(selectedTab: selectedTab, dockTabs: layout.dock))
        // KaPosts and Public Chats links, pushes and the KaPosts dock copy (its own modifier, for
        // the type checker).
        .modifier(KaPostsRoutes(show: show))
        // a .kachat registration in flight: its progress half sheet, back up after a relaunch
        // (as KaPay has it; `KachatNamesActions.resume` sets it on activation)
        .modifier(KachatRegistrationPresenter())
        // the tab on screen left the dock: Kaspa Hub, where it now lives
        .onChange(of: layout.dock) { dock in
            installHubTabInterceptor()
            if !dock.contains(where: { $0.tag == selectedTab }) {
                // Kaspa Hub is a menu, with no screen of its own to land on: Chats
                let landing: AppTab = .chats
                selectedTab = landing.tag
                KaPostsDockRouter.shared.selectedTab = landing
            }
        }
        .onAppear {
            LaunchTrace.mark("main tabs on screen")
            installHubTabInterceptor()
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
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(
                onFinished: {
                    showWelcomeGuide = false
                    // Everything the account owns starts syncing now, in the background: no
                    // progress screen and no "You're all set" (owner, 2026-11-26). The app is
                    // usable at once and chats and history fill in as they sync.
                    if chatService.onboardingSyncHeld {
                        chatService.releaseSyncForOnboarding()
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
            if let address { ProfileQRCodeCache.preload(address: address, completion: nil) }
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
        // a Kaspa Hub card's link (`kachat.app/hub/<slug>`): that section, wherever it lives
        .onReceive(NotificationCenter.default.publisher(for: .openHubSection)) { _ in
            guard let tab = PendingTabRoute.pending else { return }
            PendingTabRoute.pending = nil
            // A post or profile open over KaPost (where most card links are tapped) would sit on
            // top of the section, so the tap seemed to do nothing: they close first, as for a
            // room or a bot (audit 2026-11-25 L1).
            NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
            show(tab)
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


    /// Kaspa Hub's dock tap answered before UIKit switches tabs, so nothing flashes. Installed
    /// once the tab bar exists (a moment after the tabs appear) and again whenever the dock is
    /// rebuilt; the binding's own Hub handling stays as the fallback.
    private func installHubTabInterceptor() {
        let interceptor = HubTabInterceptor.shared
        interceptor.hubIndex = { layout.dock.firstIndex(of: .hub) }
        interceptor.onHubTap = { _ = hubTapped() }
        // the tap only opens or closes the menu: caught before the bar, so its glass stays put
        interceptor.catchesTouch = {
            showHubMenu || selectedTab == AppTab.hub.tag || HubRouter.shared.openSection == nil
                // left over a minute ago: this tap is the menu too
                || HubRouter.shared.isStale
        }
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { interceptor.install() }
        }
    }

    /// Kaspa Hub tapped (the dock, or its copy over KaPost's screens). Owner, 2026-11-27: the
    /// section you last picked is what Kaspa Hub shows, as any tab would, and tapping Kaspa Hub
    /// while you're in it brings up the menu to pick another:
    /// - menu up: it closes;
    /// - on another tab, with a section picked before: back to that section, as you left it;
    /// - in the section, or nothing picked yet: the menu;
    /// - the section left over a minute ago (owner, 2026-11-27): it's forgotten, and the menu.
    /// Returns true when it went to the section (the tab bar is then really on the Hub's tab).
    @discardableResult
    private func hubTapped() -> Bool {
        Haptics.impact(.light)
        if showHubMenu {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showHubMenu = false }
            return false
        }
        if selectedTab != AppTab.hub.tag { HubRouter.shared.forgetIfStale() }
        if selectedTab != AppTab.hub.tag, HubRouter.shared.openSection != nil {
            tabBeforeHub = selectedTab
            handleTabSelectionChange(AppTab.hub.tag)
            return true
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { showHubMenu = true }
        return false
    }

    /// Puts `tab` on screen: its dock slot, or Kaspa Hub with it open there.
    private func show(_ tab: AppTab) {
        if tab == .hub {
            // Kaspa Hub (the dock copy over KaPost's screens): as a dock tap, never a Hub screen
            hubTapped()
        } else if layout.dock.contains(tab) {
            showHubMenu = false
            handleTabSelectionChange(tab.tag)
        } else {
            openHubSection(tab)
        }
    }

    /// A Hub section on screen as a Hub section: the Kaspa Hub tab, lit on the dock, with it open.
    /// Not as a tap on Kaspa Hub: from inside the Hub (KaPlay's Share to KaPost) that read as "Hub
    /// tapped again" and closed the section just opened.
    private func openHubSection(_ tab: AppTab) {
        showHubMenu = false
        if selectedTab != AppTab.hub.tag {
            tabBeforeHub = selectedTab
            handleTabSelectionChange(AppTab.hub.tag)
        }
        HubRouter.shared.open(tab)
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                // Kaspa Hub tapped (only if `HubTabInterceptor` missed it): the last section, or
                // the menu over the screen you're on, which stays (`hubTapped`)
                if newValue == AppTab.hub.tag {
                    let stay = selectedTab
                    if !hubTapped() { keepTabBar(on: stay, after: newValue) }
                    return
                }
                // The Hub menu is up and the tab on screen is tapped: that only closes the menu.
                // (A tap on it read as "tapped again", flipping Chats to Public Chats, 2026-11-26.)
                // Another tab tapped goes there, the menu closing with it.
                if showHubMenu, newValue == selectedTab {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showHubMenu = false }
                    return
                }
                handleTabSelectionChange(newValue)
            }
        )
    }

    /// The tab bar moves to a tapped tab before K answers, so a tap K turns down (Kaspa Hub, which
    /// opens its menu instead) left the bar, and the screen, on the Hub's tab while K stayed on the
    /// one you were on: the old Hub grid showed (2026-11-26). The bar is moved there and back, so it
    /// ends on your tab. The Hub tab draws nothing without a section open, so the moment it's
    /// there shows nothing.
    private func keepTabBar(on tab: Int, after refused: Int) {
        guard refused != tab else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { selectedTab = refused }
        DispatchQueue.main.async {
            withTransaction(quiet) { selectedTab = tab }
        }
    }

    private func handleTabSelectionChange(_ newValue: Int) {
        // another tab: the Hub's menu closes
        if newValue != AppTab.hub.tag { showHubMenu = false }
        // the clock for forgetting the Hub's section (`HubRouter.rememberFor`)
        if newValue == AppTab.hub.tag {
            HubRouter.shared.noteEntered()
        } else if selectedTab == AppTab.hub.tag {
            HubRouter.shared.noteLeft()
        }
        // A section the Hub doesn't keep alive (Kasshi, a website) isn't drawn while another tab
        // shows: its page kept running behind it (audit 2026-11-27 L17). Kaspa Hub still goes back
        // to it, opened fresh.
        HubRouter.shared.setHubOnScreen(newValue == AppTab.hub.tag)
        // Chats tapped again: back out of an open chat, or switch Private / Public Chats
        if newValue == selectedTab, newValue == AppTab.chats.tag {
            NotificationCenter.default.post(name: .chatsTabReselected, object: nil)
        }
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
        // A KaPosts or room push or link from a cold start: KaPostsView and the Chats screen
        // consume what is pending once they mount.
        if KaPostsDeepLink.pendingPostTxId != nil
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
        ProfileQRCodeCache.preload(address: address, completion: nil)
    }

}

#Preview {
    MainTabView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(SettingsViewModel())
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
                    ChattingAddressManageView(address: address, showsSendReceive: true)
                case .spending(let entry)?:
                    SpendingAddressTransactionHistoryView(entry: entry, showsSendReceive: true)
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
            // A bot challenge from a post's card (`ChessBotLinks.open`): the Games tab, which opens
            // the bot (`ChessBotLinkRouter`). Covers over KaPosts close first, as for a room.
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
            // Wallet's dot: your usernames in grace (owner, 2026-11-27), loaded here so it shows
            // from any tab - on appear (each sign-in rebuilds the tabs), on every registry change,
            // and when the app comes back.
            .onReceive(KachatExpiredNamesModel.shared.$expired) { _ in sync() }
            .onReceive(KachatNamesRegistry.shared.$revision.removeDuplicates()) { _ in loadExpiredNames() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                loadExpiredNames()
            }
            .onChange(of: selectedTab) { _ in sync() }
            .onChange(of: dockTabs) { _ in sync() }
            .onAppear {
                sync()
                loadExpiredNames()
            }
    }

    private func loadExpiredNames() {
        Task { await KachatExpiredNamesModel.shared.load() }
    }

    /// A sync is already queued: the triggers above often fire together (a room read moves the
    /// rooms' count and the bell at once), and one pass covers them all.
    private static var syncQueued = false

    private func sync() {
        guard !Self.syncQueued else { return }
        Self.syncQueued = true
        DispatchQueue.main.async {
            Self.syncQueued = false
            // One walk of the view tree for the tab bar items (`updateAppBadge` walked it again).
            // The dock as it is when this runs (`dockTabs` is `DockLayout.shared.dock`), since one
            // pass may stand for a call made before the dock changed.
            AppTabBadge.syncDockBadges(dockTabs: DockLayout.shared.dock)
            // The app icon too, as `ChatService.updateAppBadge` counts it (KaPosts' and the rooms'
            // counts change without a chat sync), and only when the number changed: a tab switch
            // changes nothing (audit #35), compared with what this run last put on the icon.
            AppTabBadge.applyIconCount(AppTabBadge.appIconCount)
        }
    }
}

// MARK: - Kaspa Hub's tap, caught before UIKit selects the tab

/// Kaspa Hub on the dock opens its glass menu instead of being selected (owner, 2026-11-26).
/// SwiftUI's TabView hears of a tap only after UIKit has switched tabs, so turning it down there
/// flashed the empty Hub tab, and on iOS 26 the dock's glass slid to Kaspa Hub and back. Two
/// layers, so neither happens:
/// - a touch on Kaspa Hub that would only open or close the menu (`catchesTouch`) is taken by a
///   tap recognizer on the tab bar before any of the bar's own handling sees it, so the glass
///   never moves (owner, 2026-11-27);
/// - any other Hub tap reaches UIKit's `shouldSelect` (both the iOS 18 `UITab` form and the
///   older one), which runs `onHubTap` and keeps UIKit on the tab you're on; `onHubTap` itself
///   moves to the saved section.
/// Every other delegate call goes on to SwiftUI's own delegate untouched.
@MainActor
final class HubTabInterceptor: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
    static let shared = HubTabInterceptor()

    /// Which of the dock's tabs is Kaspa Hub's, by position.
    var hubIndex: () -> Int? = { nil }
    /// Whether a Hub tap now would only show or hide the menu (no section to go back to).
    var catchesTouch: () -> Bool = { false }
    var onHubTap: () -> Void = {}

    private weak var original: UITabBarControllerDelegate?
    private weak var installedOn: UITabBarController?
    private var recognizer: UITapGestureRecognizer?

    /// A sign-out: the closures holding the last session's tab view go (audit 2026-11-27 L22);
    /// the next session's tabs install their own.
    func reset() {
        hubIndex = { nil }
        catchesTouch = { false }
        onHubTap = {}
    }

    /// Puts the interceptor on the dock's tab bar controller, once it exists. Safe to call again.
    func install() {
        guard let tabs = Self.findTabBarController() else { return }
        if tabs.delegate !== self {
            original = tabs.delegate
            tabs.delegate = self
        }
        if installedOn !== tabs || recognizer?.view !== tabs.tabBar {
            if let old = recognizer { old.view?.removeGestureRecognizer(old) }
            let tap = UITapGestureRecognizer(target: self, action: #selector(caughtTap(_:)))
            tap.delegate = self
            tap.cancelsTouchesInView = true
            tap.delaysTouchesBegan = true
            tabs.tabBar.addGestureRecognizer(tap)
            recognizer = tap
        }
        installedOn = tabs
    }

    // MARK: The touch layer

    @objc private func caughtTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        onHubTap()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === recognizer, catchesTouch(),
              let bar = installedOn?.tabBar, let frame = hubItemFrame(in: bar) else { return false }
        return frame.contains(touch.location(in: bar))
    }

    /// The bar's own recognizers (the iOS 26 glass among them) wait for this one, so a touch it
    /// takes never reaches them.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === recognizer, let bar = installedOn?.tabBar,
              let view = other.view else { return false }
        return view.isDescendant(of: bar)
    }

    /// Kaspa Hub's button on the bar: the bar's buttons, left to right, one per tab. Nil (and so
    /// nothing caught) when they can't be told apart.
    private func hubItemFrame(in bar: UITabBar) -> CGRect? {
        guard let index = hubIndex(), let count = bar.items?.count, count > 0 else { return nil }
        var buttons: [UIView] = []
        var queue: [UIView] = [bar]
        while let view = queue.popLast() {
            if view !== bar, view is UIControl, !view.isHidden, view.alpha > 0.01,
               view.bounds.width > 1, view.bounds.height > 1 {
                buttons.append(view)
                continue
            }
            queue.append(contentsOf: view.subviews)
        }
        // iOS 26 draws each button twice (the dock and the glass's copy over it): one per place
        var frames: [CGRect] = []
        for frame in buttons.map({ $0.convert($0.bounds, to: bar) }).sorted(by: { $0.midX < $1.midX }) {
            if let last = frames.last, abs(last.midX - frame.midX) < 8 {
                frames[frames.count - 1] = last.union(frame)
            } else {
                frames.append(frame)
            }
        }
        guard frames.count == count, index < count else { return nil }
        let layoutIndex = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? count - 1 - index : index
        return frames[layoutIndex]
    }

    // MARK: The selection layer

    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if let hub = hubIndex(), tabBarController.tabs.firstIndex(where: { $0 === tab }) == hub {
            onHubTap()
            return false
        }
        if let original, original.responds(to: #selector(UITabBarControllerDelegate.tabBarController(_:shouldSelectTab:))) {
            return original.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
        }
        if let controller = tab.viewController {
            return original?.tabBarController?(tabBarController, shouldSelect: controller) ?? true
        }
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          shouldSelect viewController: UIViewController) -> Bool {
        if let hub = hubIndex(),
           let index = tabBarController.viewControllers?.firstIndex(of: viewController),
           index == hub {
            onHubTap()
            return false
        }
        return original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
    }

    // Everything else goes to SwiftUI's delegate as before.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    private static func findTabBarController() -> UITabBarController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var queue: [UIViewController] = window.rootViewController.map { [$0] } ?? []
                while let controller = queue.popLast() {
                    if let tabs = controller as? UITabBarController { return tabs }
                    queue.append(contentsOf: controller.children)
                }
            }
        }
        return nil
    }
}
