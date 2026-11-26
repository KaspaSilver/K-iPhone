import SwiftUI
import Combine

/// Which dock tab is selected, shared by the real dock (`MainTabView`, which keeps it in step)
/// and the copy drawn over full-screen KaPosts screens (`KaPostsDockCopy`).
@MainActor
final class KaPostsDockRouter: ObservableObject {
    static let shared = KaPostsDockRouter()
    /// The dock slot showing; Kaspa Hub's open section is `HubRouter.openSection`.
    @Published var selectedTab: AppTab = .chats

    /// Whether KaPosts is on screen: its dock slot, or open in Kaspa Hub.
    private(set) lazy var kaPostsOnScreen: AnyPublisher<Bool, Never> =
        $selectedTab.combineLatest(HubRouter.shared.$openSection)
            .map { tab, section in tab == .kaposts || (tab == .hub && section == .kaposts) }
            .removeDuplicates()
            .eraseToAnyPublisher()

    /// A tab tapped on the dock copy: `MainTabView` puts it on screen, as a tap on the real dock.
    func select(_ tab: AppTab) {
        NotificationCenter.default.post(name: .kaPostsSelectDockTab, object: tab)
    }
}

extension Notification.Name {
    /// A tab tapped on the dock copy (`KaPostsDockRouter.select`); the object is the `AppTab`.
    static let kaPostsSelectDockTab = Notification.Name("kaPostsSelectDockTab")
    /// A tap on the dock copy: every KaPosts full-screen screen closes at once, without the
    /// slide, so the tab underneath is what shows.
    static let kaPostsCloseCovers = Notification.Name("kaPostsCloseCovers")
    /// The KaPosts tab tapped again on a dock: the feed jumps to its top.
    static let kaPostsScrollFeedToTop = Notification.Name("kaPostsScrollFeedToTop")
}

/// The dock, drawn again on top of KaPosts' full-screen screens (threads, profiles, the menu's
/// screens, Post Activity). Those are full-screen covers, which iOS draws over the real dock;
/// this copy keeps the dock in reach on every screen.
///
/// It is not part of the screen: the slide driver (`KaPostsSlideDriverView`) puts it in the
/// cover's presentation container, above the sliding screen, so it stays still while screens
/// slide in and out under it, the way the real dock does. Tapping a tab closes every cover and
/// selects that tab (the one you are on just closes them, like tapping the current tab).
/// Hidden while the keyboard is up.
struct KaPostsDockCopy: View {
    @ObservedObject private var router = KaPostsDockRouter.shared
    @ObservedObject private var layout = DockLayout.shared
    @ObservedObject private var connection = ConnectionHealth.shared
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @ObservedObject private var notifCenter = KaPostsNotificationCenter.shared
    @ObservedObject private var publicChatBadge = PublicChatUnreadBadge.shared
    @ObservedObject private var globalNotifCenter = GlobalNotificationCenter.shared

    /// The capsule's height, matching the system dock.
    static let height: CGFloat = 62

    var body: some View {
        DockCopyItemsLayout {
            ForEach(layout.dock) { tab in
                item(tab)
            }
        }
        .padding(4)
        .frame(height: Self.height)
        .background(dockBackground)
    }

    @ViewBuilder
    private var dockBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
    }

    private func item(_ tab: AppTab) -> some View {
        let selected = router.selectedTab == tab
        let badgeText = badgeText(for: tab)
        return Button {
            Haptics.selection()
            NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
            router.select(tab)
        } label: {
            VStack(spacing: 3) {
                tabIcon(tab)
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 10, y: -6)
                        }
                    }
                // the real dock's label weight: semibold read heavier than it (2026-11-26)
                Text(LocalizedStringKey(tab.label))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(selected ? .accentColor : .primary)
            .padding(.horizontal, DockCopyItemsLayout.itemPadding)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(0.1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(tab.label)))
        .accessibilityValue(accessibilityBadge(for: tab))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Kaspa Hub's logo as the real dock draws it, the other tabs' symbols.
    @ViewBuilder
    private func tabIcon(_ tab: AppTab) -> some View {
        if tab == .hub, let logo = KaspaDockIcon.image {
            logo
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: tab.icon)
                .symbolVariant(.fill)
                .font(.system(size: 22, weight: .medium))
                // Settings carries the connection dot, Profile the backup dot, as on the real dock
                .overlay(alignment: .topTrailing) {
                    if tab == .settings || (tab == .profile && backupStatus.isPending(WalletManager.shared.currentWallet?.publicAddress)) {
                        Circle()
                            .fill(tab == .settings ? connection.color : Color.yellow)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: 4, y: -3)
                    }
                }
        }
    }

    /// The real dock's badges (`AppTabBadge`); an empty label is its dot.
    private func badgeText(for tab: AppTab) -> String? {
        AppTabBadge.dockLabel(for: tab)
    }

    private func accessibilityBadge(for tab: AppTab) -> Text {
        let count = AppTabBadge.unreadCount(for: tab)
        return count > 0 ? Text("\(count) unread") : Text("")
    }
}

/// The real dock's spacing (iOS 26's tab bar): a tab whose label needs more than an equal share
/// (Kaspa Hub) gets what it needs, and the others split the rest evenly. Equal fifths put the
/// copy's icons a few points off the real ones, so the dock seemed to shift (owner, 2026-11-26).
struct DockCopyItemsLayout: Layout {
    static let itemPadding: CGFloat = 15

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? widths(total: nil, subviews).reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(total: bounds.width, subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }

    private func widths(total: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let total, !subviews.isEmpty else { return ideal }
        var widths = Array(repeating: total / CGFloat(subviews.count), count: subviews.count)
        // give the wide ones what they need, then share what is left among the rest
        var fixed = Set<Int>()
        while true {
            let flexible = widths.indices.filter { !fixed.contains($0) }
            guard !flexible.isEmpty else { break }
            let left = total - fixed.reduce(0) { $0 + widths[$1] }
            let share = left / CGFloat(flexible.count)
            let grow = flexible.filter { ideal[$0] > share }
            if grow.isEmpty {
                for i in flexible { widths[i] = share }
                break
            }
            for i in grow { widths[i] = min(ideal[i], total * 0.4); fixed.insert(i) }
        }
        return widths
    }
}

/// The fade behind the dock copy over KaPosts' full-screen screens: the screen's background
/// rises from the bottom edge to a little above the dock, so text scrolling under it softens out
/// instead of running through the icons.
struct KaPostsDockFade: View {
    /// How far above the dock's top the fade starts.
    static let rise: CGFloat = 26

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(.systemBackground).opacity(0), location: 0),
                .init(color: Color(.systemBackground).opacity(0.8), location: 0.45),
                .init(color: Color(.systemBackground).opacity(0.94), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
