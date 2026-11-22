import SwiftUI

// Kaspa Hub and Customize Dock, back since 2026-11-20 (KaChat is the all-in-one app again).
// The dock is Kaspa Hub plus up to four tabs the person picks; everything else is a tile in the
// Hub's grid, and opens there. A feature is never in both places at once.

extension Notification.Name {
    /// Opens Customize Dock as a sheet over the tabs (from the Hub's toolbar or Settings). Posted
    /// rather than pushed: a new arrangement rebuilds the whole tab bar, which would throw the
    /// person out of a screen pushed inside one of its tabs.
    static let openCustomizeDock = Notification.Name("KaChatOpenCustomizeDock")
}

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
        let storedDock = (UserDefaults.standard.stringArray(forKey: Self.dockKey) ?? []).compactMap(AppTab.init(rawValue:))
        let storedHub = (UserDefaults.standard.stringArray(forKey: Self.hubKey) ?? []).compactMap(AppTab.init(rawValue:))
        let (dock, hub) = Self.normalized(dock: storedDock.isEmpty ? AppTab.defaultDock : storedDock, hub: storedHub)
        self.dock = dock
        self.hub = hub
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

    func set(dock: [AppTab], hub: [AppTab]) {
        let (newDock, newHub) = Self.normalized(dock: dock, hub: hub)
        guard newDock != self.dock || newHub != self.hub else { return }
        self.dock = newDock
        self.hub = newHub
        UserDefaults.standard.set(newDock.map(\.rawValue), forKey: Self.dockKey)
        UserDefaults.standard.set(newHub.map(\.rawValue), forKey: Self.hubKey)
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
        case .kachatStats:
            KaChatStatsView()
        case .apps:
            NavigationStack {
                // ProfileAppsView sets its own title; only the shared header items are added.
                ProfileAppsView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            ConnectionStatusIndicator()
                        }
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

    /// The sections kept alive when left. Each was checked for what it does while on screen:
    /// KaPost's feed polls only while it shows (`KaPostsDockRouter.kaPostsOnScreen`), and the
    /// chess screens watch the arena through `onScreenPresence`, which counts a hidden section as
    /// gone. The others (Chats, Wallet, Contacts, Settings, Kaspa Websites) still close when left:
    /// an open chat or room marks itself read and polls until its onDisappear, which a hidden
    /// section never gets, and a web page would keep playing.
    private static let keptAlive: Set<AppTab> = [
        .kaposts, .portfolio, .games, .kachatNames, .kachatStats, .coldStorage,
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
            grid
                .hubLayerHidden(open != nil)
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
                if layout.hub.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(layout.hub) { tab in
                            tile(tab)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle(Text(LocalizedStringKey(AppTab.hub.label)))
            // large, like every section, so the bar doesn't change height when one opens
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .openCustomizeDock, object: nil)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Customize Dock"))
                }
            }
        }
    }

    private func tile(_ tab: AppTab) -> some View {
        Button {
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
    }

    /// Every tab is in the dock: nothing left for the grid.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .opacity(0.5)
            Text("Nothing here right now")
                .font(.headline)
            Text("What isn't in your dock shows here. Arrange them in Customize Dock.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
    }
}

/// A tab's icon at a size, as the Hub and Customize Dock draw it. Kaspa Hub is the Kaspa logo.
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

/// Customize Dock: two lists ordered by dragging. Your Dock is the dock itself, in order; Kaspa Hub
/// is always in it (a lock instead of a remove button) and the others carry a red minus that sends
/// them to the Hub. Kaspa Hub lists everything else in its grid order, each with a green plus that
/// moves it into the dock while there's room (five at most). Every move applies at once.
struct CustomizeDockView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var layout = DockLayout.shared

    @State private var dock: [AppTab] = []
    @State private var hub: [AppTab] = []
    /// Not saved before the lists are seeded, which would save an empty dock.
    @State private var loaded = false

    private var dockIsFull: Bool { dock.count >= AppTab.maxDockItems }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(dock) { tab in
                        dockRow(tab)
                    }
                    .onMove { source, destination in
                        Haptics.impact(.light)
                        dock.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    HStack {
                        Text("Your Dock")
                        Spacer()
                        Text(verbatim: "\(dock.count)/\(AppTab.maxDockItems)")
                    }
                } footer: {
                    Text(String(format: AppLocalization.string("%@ always stays in your dock."),
                                AppLocalization.string(AppTab.hub.label)))
                }

                Section {
                    ForEach(hub) { tab in
                        hubRow(tab)
                    }
                    .onMove { source, destination in
                        Haptics.impact(.light)
                        hub.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text(LocalizedStringKey(AppTab.hub.label))
                } footer: {
                    Text(dockIsFull
                         ? AppLocalization.string("Your dock is full. Remove one from it to add one of these.")
                         : String(format: AppLocalization.string("In the order %@ shows them."),
                                  AppLocalization.string(AppTab.hub.label)))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Dock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                dock = layout.dock
                hub = layout.hub
                loaded = true
            }
            // live: the dock under this sheet follows every move
            .onChange(of: dock) { _ in persist() }
            .onChange(of: hub) { _ in persist() }
        }
    }

    private func dockRow(_ tab: AppTab) -> some View {
        HStack(spacing: 14) {
            if AppTab.pinnedToDock.contains(tab) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                    .accessibilityLabel(Text("Always in your dock"))
            } else {
                Button {
                    removeFromDock(tab)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 22))
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(format: AppLocalization.string("Move %@ to %@"),
                                                AppLocalization.string(tab.label), AppLocalization.string(AppTab.hub.label))))
            }
            AppTabIcon(tab: tab, size: 20)
                .frame(width: 28)
            Text(LocalizedStringKey(tab.label))
        }
    }

    private func hubRow(_ tab: AppTab) -> some View {
        HStack(spacing: 14) {
            if !dockIsFull {
                Button {
                    addToDock(tab)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 22))
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(format: AppLocalization.string("Add %@ to your dock"),
                                                AppLocalization.string(tab.label))))
            }
            AppTabIcon(tab: tab, size: 20)
                .frame(width: 28)
            Text(LocalizedStringKey(tab.label))
        }
    }

    /// Red minus: out of the dock, to the top of Kaspa Hub where it can be seen.
    private func removeFromDock(_ tab: AppTab) {
        guard !AppTab.pinnedToDock.contains(tab) else { return }
        Haptics.impact(.light)
        withAnimation(.snappy(duration: 0.22)) {
            dock.removeAll { $0 == tab }
            hub.removeAll { $0 == tab }
            hub.insert(tab, at: 0)
        }
    }

    /// Green plus: into the dock, at its end; drag it to where it should sit.
    private func addToDock(_ tab: AppTab) {
        guard !dockIsFull else { return }
        Haptics.impact(.light)
        withAnimation(.snappy(duration: 0.22)) {
            hub.removeAll { $0 == tab }
            dock.removeAll { $0 == tab }
            dock.append(tab)
        }
    }

    private func persist() {
        guard loaded else { return }
        layout.set(dock: dock, hub: hub)
    }
}

extension View {
    /// `AccountBackupBanner` under the navigation bar of one of the main tabs (KaPay's).
    func accountBackupBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { AccountBackupBanner() }
    }
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
}
