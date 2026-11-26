import UIKit
import UserNotifications

/// How many unseen things a tab is holding, wherever that tab is drawn.
///
/// One source for the dock.
@MainActor
enum AppTabBadge {
    static func unreadCount(for tab: AppTab) -> Int {
        switch tab {
        // Every notification, KaPosts and the wallet's: behind Profile's bell (since 2026-11-21).
        case .profile: return AllNotificationsBadge.count
        // Unread messages across the chats and groups the list shows (not Message Requests or
        // blocked). Public rooms aren't in it (owner, 2026-11-25): their count is on the Chats /
        // Public Chats button beside KaChat's title.
        case .chats:
            return ChatService.shared.chatListUnreadCount + GroupChatService.shared.totalGroupUnreadCount
        // what the tabs inside it hold, so moving one there never hides its badge
        case .hub: return DockLayout.shared.hub.reduce(0) { $0 + unreadCount(for: $1) }
        default: return 0
        }
    }

    /// Unread messages in the public rooms with their bell on: the KaChat title's cycle button
    /// shows it, and the app icon adds it in.
    static var publicRoomUnreadCount: Int { PublicChatUnreadBadge.shared.count }

    /// What this run last put on the app icon. Pushes put their own number on the icon while
    /// the app is in the background, so this is forgotten whenever the app comes to the
    /// foreground (`forgetAppliedIconCount`): the first pass after that always sets the icon.
    /// It used to be compared with the extension's saved count instead, which room and KaPost
    /// pushes didn't move: a room read in the app left the icon at 1 until the next open
    /// (2026-11-26).
    private static var appliedIconCount: Int?

    /// Puts `total` on the app icon (and gives the extension the same count to add to), unless
    /// this run already put exactly that there. `force` sets it whatever was put before.
    static func applyIconCount(_ total: Int, force: Bool = false) {
        if SharedDataManager.getUnreadCount() != total { SharedDataManager.setUnreadCount(total) }
        guard force || appliedIconCount != total else { return }
        appliedIconCount = total
        UNUserNotificationCenter.current().setBadgeCount(total)
    }

    static func forgetAppliedIconCount() { appliedIconCount = nil }

    /// What the app icon shows: chats and groups, bell-on rooms and KaPosts' unseen activity.
    static var appIconCount: Int {
        unreadCount(for: .chats) + publicRoomUnreadCount + max(0, KaPostsNotificationCenter.shared.unseenCount)
    }

    /// Capped in the LABEL, not in the stored count: the real number survives a long absence and
    /// only its rendering is abbreviated. Three characters is as wide as a badge goes before it
    /// starts crowding whatever it sits on.
    static func label(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    /// What the dock shows on `tab`: Profile a red dot while the bell holds anything unread (the
    /// bell itself is a dot, so the dock says the same thing), Chats their unread
    /// message count.
    static func dockLabel(for tab: AppTab) -> String? {
        let count = unreadCount(for: tab)
        guard count > 0 else { return nil }
        if tab == .hub {
            return label(count)
        }
        return label(count)
    }

    /// A badge with no number: UIKit draws a small red dot for an empty badge value.
    static let dot = ""

    /// Puts every dock badge straight on the tab bar items too. SwiftUI applies a tab's `.badge`
    /// when it renders the TabView, and MainTabView deliberately doesn't re-render for new
    /// messages or bell entries, so a badge could lag until the next render; setting the UIKit
    /// items directly makes Profile's dot and the Chats counts change the moment the
    /// counts do, from any tab.
    static func syncDockBadges(dockTabs: [AppTab]) {
        let values = dockTabs.map { dockLabel(for: $0) }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var queue: [UIViewController] = window.rootViewController.map { [$0] } ?? []
                while let controller = queue.popLast() {
                    if let tabs = controller as? UITabBarController, let items = tabs.tabBar.items,
                       items.count == values.count {
                        for (item, value) in zip(items, values) where item.badgeValue != value {
                            item.badgeColor = .systemRed
                            item.badgeValue = value
                        }
                        return
                    }
                    queue.append(contentsOf: controller.children)
                }
            }
        }
    }
}
