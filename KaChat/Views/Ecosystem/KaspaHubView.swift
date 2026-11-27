import SwiftUI

// Kaspa Hub, back since 2026-11-20 (KaChat is the all-in-one app again). The dock is fixed
// (owner's call, 2026-11-23: Kaspa Hub, Wallet, KaChat, Profile, Settings, so the connection dot
// on Settings is always there); every other tab is a tile in the Hub's grid, and opens there.

/// What the dock holds and the order of Kaspa Hub's grid, on this device.
@MainActor
final class DockLayout: ObservableObject {
    static let shared = DockLayout()

    private static let dockKey = "kachat_dock_tabs_v2"
    private static let hubKey = "kachat_hub_tabs_v2"

    /// The dock, in order: always Kaspa Hub, at most `AppTab.maxDockItems`.
    @Published private(set) var dock: [AppTab]
    /// Kaspa Hub's grid, in order: every other tab.
    @Published private(set) var hub: [AppTab]

    private init() {
        // The dock is always `AppTab.defaultDock` (Customize Dock was removed on 2026-11-23); an
        // arrangement saved before keeps only its Hub order.
        let storedHub = (UserDefaults.standard.stringArray(forKey: Self.hubKey) ?? []).compactMap(AppTab.init(rawValue:))
        let (dock, hub) = Self.normalized(dock: AppTab.defaultDock, hub: storedHub)
        self.dock = dock
        self.hub = hub
        UserDefaults.standard.removeObject(forKey: Self.dockKey)
    }

    /// A stored arrangement made whole: Kaspa Hub in the dock, no tab twice, at most five in the
    /// dock, and every tab not in the dock in the Hub (a feature added in an update lands at the
    /// end of the Hub).
    private static func normalized(dock: [AppTab], hub: [AppTab]) -> ([AppTab], [AppTab]) {
        var seen = Set<AppTab>()
        var newDock = dock.filter { seen.insert($0).inserted }
        // A pinned tab missing from an older arrangement goes back where the default dock has it
        // (Profile before Settings), not onto the end.
        for pinned in AppTab.pinnedToDock where !newDock.contains(pinned) {
            newDock.insert(pinned, at: min(AppTab.defaultDock.firstIndex(of: pinned) ?? newDock.count, newDock.count))
        }
        while newDock.count > AppTab.maxDockItems,
              let drop = newDock.lastIndex(where: { !AppTab.pinnedToDock.contains($0) }) {
            newDock.remove(at: drop)
        }
        let inDock = Set(newDock)
        var newHub = hub.filter { !inDock.contains($0) && seen.insert($0).inserted }
        for tab in AppTab.allCases where !inDock.contains(tab) && !newHub.contains(tab) { newHub.append(tab) }
        return (newDock, newHub)
    }
}

/// Which Hub section is open. Shared, so a notification tap for a feature that lives in the Hub
/// can open it there. Tapping the Kaspa Hub tab again goes back to the grid.
@MainActor
final class HubRouter: ObservableObject {
    static let shared = HubRouter()
    @Published private(set) var openSection: AppTab?
    private init() {}

    func open(_ tab: AppTab) {
        guard tab != .hub else { return }
        openSection = tab
    }

    func close() {
        guard openSection != nil else { return }
        openSection = nil
    }
}

/// A tab's screen, the same whether it sits in the dock or opens from Kaspa Hub.
struct AppTabContent: View {
    let tab: AppTab

    var body: some View {
        switch tab {
        case .chats:
            // Bare ChatListView, no wrappers - a permanent compositing wrapper on the app's main
            // screen was the 4.0 "lag everywhere" regression.
            // Public rooms sit in this list (since 2026-11-21); their service is given here rather
            // than observed at the app's root.
            ChatListView()
                .environmentObject(PublicChatService.shared)
        case .addressBook:
            AddressBookView()
        case .wallet:
            WalletView()
        case .profile:
            // your KaPosts profile (owner's call, 2026-11-21): posts, replies, followers, with Edit
            // Profile, Share Profile and Log Out under the header
            KaPostsView(rootMode: .myProfile)
                .environmentObject(PublicChatService.shared)
        case .settings:
            SettingsView()
        case .hub:
            KaspaHubView()
        case .portfolio:
            PortfolioView()
        case .coldStorage:
            NavigationStack { ColdStorageListView() }
        case .kachatNames:
            KachatMarketView()
        // Given the rooms' service here rather than observed at the app's root, which would
        // re-render every tab for each room message.
        case .kaposts:
            KaPostsPageView()
                .environmentObject(PublicChatService.shared)
        // Chess (from KaPlay): the arena's moves go through the rooms' service, given here too.
        case .games:
            GamesView()
                .environmentObject(PublicChatService.shared)
        case .explorer:
            ExplorerView()
        case .kasshi:
            // kasshi.io in the in-app browser, its X back to the grid. Just the site: no dock
            // (owner, 2026-11-26). The node and chats keep running (`powersDown: false`) so a
            // payment Kasshi asks for goes straight out and chats are current on the way back.
            InAppBrowserScreen(url: URL(string: "https://kasshi.io")!, powersDown: false) {
                HubRouter.shared.close()
            }
            .toolbar(.hidden, for: .tabBar)
        case .apps:
            NavigationStack {
                // ProfileAppsView sets its own title; only the shared header items are added.
                ProfileAppsView()
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            BalanceToolbarLabel()
                        }
                    }
            }
        }
    }
}

/// The Kaspa Hub tab: a grid of everything that isn't in the dock, and the section picked from it.
struct KaspaHubView: View {
    @ObservedObject private var layout = DockLayout.shared
    @ObservedObject private var router = HubRouter.shared

    /// Sections opened since the Hub came up that stay alive (hidden) once left, so coming back
    /// shows them exactly as they were: KaPost's feed, scroll position and pushed screens, as from
    /// a dock slot (audit 2026-11-21 #28). In the order they were first opened.
    @State private var keptSections: [AppTab] = []

    /// The card held down: its half sheet (Copy Link, Open).
    @State private var heldCard: AppTab?
    /// "Link copied", shown over the Hub after Copy Link.
    @State private var toastMessage: String?
    /// Which copy the toast belongs to, so a second copy within its 1.6 s isn't cleared early
    /// by the first one's timer.
    @State private var toastToken = 0

    /// The sections kept alive when left. Each was checked for what it does while on screen:
    /// KaPost's feed polls only while it shows (`KaPostsDockRouter.kaPostsOnScreen`), and the
    /// chess screens watch the arena through `onScreenPresence`, which counts a hidden section as
    /// gone. The others (Chats, Wallet, Contacts, Settings, Kaspa Websites) still close when left:
    /// an open chat or room marks itself read and polls until its onDisappear, which a hidden
    /// section never gets, and a web page would keep playing.
    private static let keptAlive: Set<AppTab> = [
        .kaposts, .portfolio, .games, .kachatNames, .coldStorage, .explorer,
    ]

    /// Three across, so the tiles line up the same way whatever the count.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    /// The section on screen, if it's still one of the Hub's.
    private var openSection: AppTab? {
        guard let open = router.openSection, layout.hub.contains(open) else { return nil }
        return open
    }

    /// The kept sections to draw. The one being opened is in the list from its first frame,
    /// before `keep` stores it, so its identity (and state) never changes between the two.
    private var aliveSections: [AppTab] {
        guard let open = openSection, Self.keptAlive.contains(open), !keptSections.contains(open) else {
            return keptSections
        }
        return keptSections + [open]
    }

    var body: some View {
        let open = openSection
        ZStack {
            // no grid with the Hub as a menu (owner, 2026-11-26): the menu is the way in
            grid
                .hubLayerHidden(open != nil || HubPresentation.asMenu)
            // Each section owns the whole screen with its own navigation bar, exactly as it looks
            // from its own dock slot; a hidden one's bar is hidden with it. Not animated: a
            // cross-fade dimmed the bar's balance.
            ForEach(aliveSections) { tab in
                AppTabContent(tab: tab)
                    .hubLayerHidden(tab != open)
                    .environment(\.hubSectionHidden, tab != open)
            }
            if let open, !Self.keptAlive.contains(open) {
                AppTabContent(tab: open)
            }
        }
        // On the Hub itself, not the grid: the grid is hidden while a section is open, and Open
        // in the sheet opens one, so the sheet and its toast would go with it.
        .toast(message: toastMessage)
        .sheet(item: $heldCard) { tab in
            cardActionSheet(for: tab)
        }
        .onAppear { keep(router.openSection) }
        .onChange(of: router.openSection) { section in keep(section) }
        // a section moved into the dock meanwhile must not stay open (or kept) here too
        .onChange(of: layout.hub) { hub in
            if let open = router.openSection, !hub.contains(open) { router.close() }
            keptSections.removeAll { !hub.contains($0) }
        }
        // Short of memory: the hidden sections go; they load again when next opened.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            keptSections.removeAll { $0 != router.openSection }
        }
    }

    private func keep(_ section: AppTab?) {
        guard let section, Self.keptAlive.contains(section), layout.hub.contains(section),
              !keptSections.contains(section) else { return }
        keptSections.append(section)
    }

    private var grid: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(layout.hub) { tab in
                        tile(tab)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle(Text(LocalizedStringKey(AppTab.hub.label)))
            // large, like every section, so the bar doesn't change height when one opens
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
            }
        }
    }

    private func tile(_ tab: AppTab) -> some View {
        Button {
            // A hold that opened the half sheet can also end as a tap on a device; the card
            // opening behind its own sheet isn't what was asked for (as the chat circles guard).
            guard heldCard == nil else { return }
            Haptics.impact(.light)
            router.open(tab)
        } label: {
            // a square from the column, the label laid over it, so every tile is the same size
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 10) {
                        AppTabIcon(tab: tab, size: 26)
                            .frame(height: 30)
                        Text(LocalizedStringKey(tab.label))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 8)
                }
                // the badge the dock would show for it, so moving a tab here never hides one
                .overlay(alignment: .topTrailing) {
                    if let label = AppTabBadge.dockLabel(for: tab) {
                        Text(verbatim: label)
                            .font(.scaled(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, label.isEmpty ? 0 : 5)
                            .frame(minWidth: label.isEmpty ? 12 : 20, minHeight: label.isEmpty ? 12 : 20)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 6, y: -6)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        // Hold: its half sheet, with the card's link to copy (2026-11-25). A Button label needs
        // simultaneousGesture, as the chat circles do.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard tab.linkSlug != nil else { return }
                Haptics.impact(.medium)
                heldCard = tab
            }
        )
        .accessibilityHint(Text("Hold for options"))
    }

    /// A held card's half sheet, as every long-press menu in the app (tiles): Copy Link, whose
    /// `https://kachat.app/hub/<slug>` opens this card in K for whoever taps it, and Open.
    private func cardActionSheet(for tab: AppTab) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                AppTabIcon(tab: tab, size: 18)
                Text(LocalizedStringKey(tab.label))
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ActionSheetTiles {
                ActionSheetRow(title: "Copy Link", subtitle: "A link that opens this card in K.", systemImage: "link") {
                    heldCard = nil
                    guard let url = KaChatInternalLink.hubSectionShareURL(for: tab) else { return }
                    UIPasteboard.general.string = url.absoluteString
                    Haptics.success()
                    toastToken &+= 1
                    let token = toastToken
                    withAnimation(.easeOut(duration: 0.2)) { toastMessage = AppLocalization.string("Link copied") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        // only the latest copy's timer takes the toast down
                        guard token == toastToken else { return }
                        withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
                    }
                }
                ActionSheetRow(title: "Open", subtitle: "Opens this card.", systemImage: "arrow.up.forward.app") {
                    heldCard = nil
                    router.open(tab)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(ActionSheetTileMetrics.sheetHeight(tiles: 2))])
        .presentationDragIndicator(.visible)
    }
}

/// A tab's icon at a size, as the Hub draws it. Kaspa Hub is the Kaspa logo; Usernames is its
/// "@" symbol like every other tab (owner, 2026-11-26: no longer the ".kachat" wordmark).
struct AppTabIcon: View {
    let tab: AppTab
    let size: CGFloat

    var body: some View {
        if tab == .hub {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tab.icon)
                .font(.scaled(size: size, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Kaspa Hub's dock icon: the Kaspa logo as a tab bar template, so the bar tints it selected or
/// not like the symbols beside it. The tab bar draws a template by its alpha alone, and the logo's
/// white K is opaque, so the K is cut out of the disc (white pixels made clear) or it would be a
/// plain circle. Made once at the dock's 24-point size: the bar ignores SwiftUI frames.
enum KaspaDockIcon {
    static let image: Image? = {
        guard let source = UIImage(named: "KaspaLogo") else { return nil }
        let side: CGFloat = 24
        let scale: CGFloat = 3
        let pixels = Int(side * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgSource = source.cgImage else { return nil }
        let fit = min(CGFloat(pixels) / max(source.size.width, 1), CGFloat(pixels) / max(source.size.height, 1))
        let w = source.size.width * fit, h = source.size.height * fit
        context.draw(cgSource, in: CGRect(x: (CGFloat(pixels) - w) / 2, y: (CGFloat(pixels) - h) / 2, width: w, height: h))
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        for i in 0..<(pixels * pixels) {
            let r = buffer[i * 4], g = buffer[i * 4 + 1], b = buffer[i * 4 + 2], a = buffer[i * 4 + 3]
            guard a > 0 else { continue }
            // un-premultiplied lightness of the darkest channel: the teal stays, the white K goes
            let lightest = Double(min(r, g, b)) / Double(a)
            let cut = min(max((lightest - 0.75) / 0.2, 0), 1)
            let keep = 1 - cut
            buffer[i * 4] = UInt8(Double(r) * keep)
            buffer[i * 4 + 1] = UInt8(Double(g) * keep)
            buffer[i * 4 + 2] = UInt8(Double(b) * keep)
            buffer[i * 4 + 3] = UInt8(Double(a) * keep)
        }
        guard let cut = context.makeImage() else { return nil }
        let image = UIImage(cgImage: cut, scale: scale, orientation: .up)
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
    }()
}

// MARK: - Sections kept alive in Kaspa Hub

private struct HubSectionHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a Kaspa Hub section that is kept alive but hidden (another section or the grid
    /// is showing). Such a section gets no onDisappear, so anything that should run only while it
    /// shows reads this, usually through `onScreenPresence`.
    var hubSectionHidden: Bool {
        get { self[HubSectionHiddenKey.self] }
        set { self[HubSectionHiddenKey.self] = newValue }
    }
}

extension View {
    /// A Kaspa Hub layer that is kept but not showing: invisible, untouchable and silent to
    /// VoiceOver. Its navigation bar and toolbar are hidden with it.
    fileprivate func hubLayerHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }

    /// `onAppear` / `onDisappear` that also count a kept-alive, hidden Kaspa Hub section as gone:
    /// `appear` runs when the view is on screen and its section shows, `disappear` when either
    /// stops. Always in pairs, never twice in a row.
    func onScreenPresence(appear: @escaping () -> Void, disappear: @escaping () -> Void) -> some View {
        modifier(OnScreenPresence(appear: appear, disappear: disappear))
    }
}

private struct OnScreenPresence: ViewModifier {
    let appear: () -> Void
    let disappear: () -> Void
    @Environment(\.hubSectionHidden) private var hidden

    /// A box, so the appear / disappear callbacks see each other's writes at once.
    private final class Box {
        var inHierarchy = false
        var active = false
    }
    @State private var state = Box()

    func body(content: Content) -> some View {
        content
            .onAppear {
                state.inHierarchy = true
                update(hidden: hidden)
            }
            .onDisappear {
                state.inHierarchy = false
                update(hidden: hidden)
            }
            .onChange(of: hidden) { newValue in update(hidden: newValue) }
    }

    private func update(hidden: Bool) {
        let shouldBeActive = state.inHierarchy && !hidden
        guard shouldBeActive != state.active else { return }
        state.active = shouldBeActive
        if shouldBeActive { appear() } else { disappear() }
    }
}

extension Notification.Name {
    /// Opens a .kachat name's screen (from a notification or a link; KaPay's).
    static let openKachatName = Notification.Name("openKachatName")
    /// Opens a Kaspa Hub card's section (a `kachat.app/hub/<slug>` link); the tab is
    /// `PendingTabRoute.pending`, which also covers a cold start.
    static let openHubSection = Notification.Name("openHubSection")
}

/// A Kaspa Hub card's link (`kachat.app/hub/<slug>`) drawn in a KaPost and its composer, in
/// KaPost's own card style (as `KaPostPaymentRequestCard`): the card's icon, "Kaspa Hub", its name
/// and what it holds, and Open, which opens that section in K. Holding it opens a half sheet of
/// tiles (Copy Link, Open), as every long-press menu in the app. Chats draw the same link as their
/// internal link card (`KaChatInternalLinkCardView`).
struct KaspaHubLinkCard: View {
    let tab: AppTab
    /// False for the composer's preview: drawn the same, but nothing opens or copies, so a tap
    /// there can't leave the post being written (audit 2026-11-25 L1). Not only hit testing:
    /// VoiceOver could still activate a button.
    var interactive: Bool = true

    /// Held: its half sheet.
    @State private var showsActions = false

    var body: some View {
        if interactive {
            Button {
                // A hold that opened the sheet can also end as a tap on a device; don't open the
                // card behind its own sheet (as the chat circles guard).
                guard !showsActions else { return }
                open()
            } label: {
                card
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    Haptics.impact(.medium)
                    showsActions = true
                }
            )
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens it in K."))
            .accessibilityAction(named: Text("Copy Link")) { copyLink() }
            .sheet(isPresented: $showsActions) {
                actionSheet
            }
        } else {
            card
                .accessibilityElement(children: .combine)
        }
    }

    private func open() {
        Haptics.impact(.light)
        KaChatLinkRouter.open(.hubSection(tab))
    }

    private func copyLink() {
        guard let url = KaChatInternalLink.hubSectionShareURL(for: tab) else { return }
        UIPasteboard.general.string = url.absoluteString
        Haptics.success()
    }

    /// The held card's half sheet, as the Hub grid's own (`KaspaHubView.cardActionSheet`).
    private var actionSheet: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                AppTabIcon(tab: tab, size: 18)
                Text(LocalizedStringKey(tab.label))
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ActionSheetTiles {
                ActionSheetRow(title: "Copy Link", subtitle: "A link that opens this card in K.", systemImage: "link") {
                    showsActions = false
                    copyLink()
                }
                ActionSheetRow(title: "Open", subtitle: "Opens this card.", systemImage: "arrow.up.forward.app") {
                    showsActions = false
                    open()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(ActionSheetTileMetrics.sheetHeight(tiles: 2))])
        .presentationDragIndicator(.visible)
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                AppTabIcon(tab: tab, size: 22)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kaspa Hub")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .textCase(.uppercase)
                Text(LocalizedStringKey(tab.label))
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(LocalizedStringKey(tab.hubBlurb))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text("Open")
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor))
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Kaspa Hub as a menu (owner, 2026-11-26)

/// Kaspa Hub as a menu: tapping it on the dock never shows a Hub screen. Its glass menu
/// (`KaspaHubMenu`) rises over whatever tab is on screen; a section picked opens as a Hub section
/// (the Kaspa Hub tab, lit, the dock in view), and tapping Kaspa Hub there brings the menu back.
/// Off returns the Hub to its own tab and grid.
enum HubPresentation {
    static let asMenu = true
}

/// Kaspa Hub's menu (owner, 2026-11-26: "like when you click the + in iMessage"): a glass panel
/// that rises from the dock's left side, about as wide as the first three dock icons and at most
/// half the screen tall, with every section in a scrollable list. A tap anywhere else closes it;
/// a section picked opens as a Hub section, the dock in view with Kaspa Hub lit.
struct KaspaHubMenu: View {
    @Binding var isPresented: Bool
    let onPick: (AppTab) -> Void
    @ObservedObject private var layout = DockLayout.shared

    /// From the bottom of the safe area to just above the dock.
    private static let dockClearance: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if isPresented {
                    // a tap outside, the dock included, closes it
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                    panel(maxHeight: geo.size.height * 0.5)
                        .frame(width: min(geo.size.width * 0.64, 300))
                        .padding(.leading, 16)
                        .padding(.bottom, Self.dockClearance)
                        .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isPresented = false }
    }

    private func panel(maxHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(layout.hub) { tab in
                    Button {
                        Haptics.impact(.light)
                        close()
                        // after the panel's close has started, so the two don't fight
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onPick(tab) }
                    } label: {
                        HStack(spacing: 12) {
                            AppTabIcon(tab: tab, size: 18)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.accentColor.opacity(0.18)))
                            Text(LocalizedStringKey(tab.label))
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let label = AppTabBadge.dockLabel(for: tab) {
                                Text(verbatim: label)
                                    .font(.scaled(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, label.isEmpty ? 0 : 5)
                                    .frame(minWidth: label.isEmpty ? 10 : 18, minHeight: label.isEmpty ? 10 : 18)
                                    .background(Capsule().fill(Color.red))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        // its rows' height (about 48 pt each), at most half the screen, scrolling past that
        .frame(height: min(CGFloat(layout.hub.count) * 48 + 16, maxHeight))
        .background(menuGlass)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private var menuGlass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        }
    }
}
