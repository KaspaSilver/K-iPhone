import Foundation
import Combine

/// The public rooms' unread count: across the listed rooms with their bell on, which the app icon
/// adds in (`AppTabBadge.appIconCount`; not the dock's KaChat badge), worked out again whenever the rooms change
/// and published only when the number does - so the dock (both the real one and
/// `KaPostsDockCopy`) doesn't redraw for every message that arrives.
@MainActor
final class PublicChatUnreadBadge: ObservableObject {
    static let shared = PublicChatUnreadBadge()

    @Published private(set) var count = 0

    var badgeText: String { count > 99 ? "99+" : "\(count)" }

    private var cancellable: AnyCancellable?

    private init() {
        // objectWillChange fires before the change lands: the debounce counts after it.
        cancellable = PublicChatService.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recount() }
        recount()
    }

    private func recount() {
        // Every room used to count here while the dock counted bell-on rooms only, so muting or
        // unmuting a room with unread messages left this number unchanged and nothing redrew the
        // dock or the app icon's badge (audit 2026-11-24 notifications).
        let rooms = PublicChatService.shared
        let total = rooms.listedChannels.filter(\.notifyEnabled)
            .reduce(0) { $0 + rooms.unreadCount(forChannel: $1.channelName) }
        if total != count { count = total }
    }
}
