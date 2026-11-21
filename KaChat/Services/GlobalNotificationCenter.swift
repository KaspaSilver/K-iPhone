import Foundation
import SwiftUI

/// The bell on the Profile screen holds Kaspa arriving in one of your own addresses - the
/// chatting address or a spending address (fed by AddressActivityNotifier). .kachat name news
/// left with the .kachat market on 2026-10-24.
/// Not group chats (they keep their own unread counts in the Chats tab). Entries are account-scoped, persisted, deduped by id, and capped; opening the
/// list marks everything seen.
@MainActor
final class GlobalNotificationCenter: ObservableObject {
    static let shared = GlobalNotificationCenter()

    struct Entry: Identifiable, Codable, Equatable {
        enum Source: String, Codable {
            /// RETIRED with KaPosts and Public Chats (2026-10-24): kept only so a feed saved by
            /// an older build still decodes - `reload` drops those rows.
            case kaposts, group, wallet
            case publicChat = "broadcast"
            /// RETIRED with the .kachat market (2026-10-24): a .kachat name event.
            case kachat
            /// A token received (kUSDT); `targetId` is the token's id.
            case token

            var label: String {
                switch self {
                case .kaposts: return "KaPost"
                case .group: return "Group"
                case .publicChat: return "Public Chat"
                case .wallet: return "KaPay"
                case .kachat: return ".kachat"
                case .token: return "Tokens"
                }
            }

            var icon: String {
                switch self {
                case .kaposts: return "megaphone"
                case .group: return "person.3"
                case .publicChat: return "dot.radiowaves.left.and.right"
                case .wallet: return "arrow.down.circle"
                case .kachat: return "at"
                case .token: return "dollarsign.circle"
                }
            }

            /// What the Profile bell lists.
            static let inBell: Set<Source> = [.wallet, .token]
        }

        let id: String
        let source: Source
        let title: String
        let body: String
        let timestamp: Int64 // ms
        /// group id / address / name - what tapping the row should open.
        let targetId: String?
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastSeenAt: Int64 = 0

    private let maxEntries = 100

    var unreadCount: Int {
        entries.filter { $0.timestamp > lastSeenAt }.count
    }

    private init() {
        reload()
    }

    // MARK: - Persistence (account-scoped)

    private var walletAddress: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }
    private var entriesKey: String { "globalNotifCenter.entries.\(walletAddress)" }
    private var seenKey: String { "globalNotifCenter.seenAt.\(walletAddress)" }

    /// Delete Account: one wallet's feed, from this device.
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.entries.\(walletAddress)")
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.seenAt.\(walletAddress)")
    }

    /// Call on account switch (and at init) to load the active wallet's feed.
    func reload() {
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            // Wallet rows only. Group mentions carry their own counts in the Chats tab, and
            // KaPosts, Public Chats and the .kachat market are gone; anything an older build
            // saved for those is dropped here.
            let kept = decoded.filter { Entry.Source.inBell.contains($0.source) }
            entries = kept
            if kept.count != decoded.count { persist() }
        } else {
            entries = []
        }
        lastSeenAt = (UserDefaults.standard.object(forKey: seenKey) as? NSNumber)?.int64Value ?? 0
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(maxEntries))) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: - Feed mutations

    func record(id: String, source: Entry.Source, title: String, body: String, timestamp: Int64, targetId: String?) {
        // Only what the bell lists. Refused here rather than merely left uncalled.
        guard Entry.Source.inBell.contains(source) else { return }
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        entries.insert(Entry(id: id, source: source, title: title, body: body, timestamp: timestamp, targetId: targetId), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func markAllSeen() {
        lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: lastSeenAt), forKey: seenKey)
    }

    func clearAll() {
        entries = []
        persist()
    }

    // MARK: - Group @mentions (called from GroupChatService on incoming messages)

    /// Records a center entry (the OS banner stays GroupChatService's business) when `text`
    /// @mentions one of the current wallet's own KNS domains.
    /// Group chats carry their own unread counts and mention handling in the Chats tab, so
    /// mentions no longer go through the bell. Kept as a no-op for the call site; rows an
    /// older build recorded are dropped on load (see `reload`).
    func recordGroupMentionIfNeeded(groupId: String, groupName: String, senderAddress: String, text: String, txId: String?, timestampMs: Int64) {}
}

/// Notifications: newest-first feed of all sources, source-tagged rows, Clear all.
/// Opening it marks everything seen (clears the Wallet tab's dot). The Wallet tab pushes it as
/// its own screen (`isPushed`, a large "Notifications" title, as KaPay has it, 2026-11-20);
/// elsewhere it's a sheet with Done.
struct GlobalNotificationListView: View {
    var isPushed = false
    @ObservedObject private var center = GlobalNotificationCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if isPushed {
            list
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
            Group {
                if center.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No notifications yet")
                            .font(.headline)
                        Text("Kaspa arriving in your addresses shows up here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(center.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.source.icon)
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                if !entry.body.isEmpty {
                                    Text(entry.body)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    Text(entry.source.label)
                                    Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000)
                                        .formatted(.relative(presentation: .named)))
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        // Every row deep-opens its subject through the same pending-deep-link
                        // flow the OS notification taps use: wallet rows the address.
                        .contentShape(Rectangle())
                        .onTapGesture { Self.open(entry) { dismiss() } }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(isPushed ? .large : .inline)
            .toolbar {
                if !isPushed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear All") { center.clearAll() }
                        .disabled(center.entries.isEmpty)
                }
            }
            .onAppear { center.markAllSeen() }
    }

    /// Routes a tapped row to its subject. The sheet has to close first (only one sheet presents
    /// at a time), so the pending target is staged now and the tab switch posted after the
    /// dismissal animation - the same two-step every notification tap uses.
    /// Static so the all-in-one Notifications list (Profile's bell) opens wallet rows the same way.
    static func open(_ entry: GlobalNotificationCenter.Entry, dismiss: () -> Void) {
        let target = entry.targetId ?? ""
        switch entry.source {
        case .kaposts, .publicChat, .kachat:
            // Retired sources; `reload` drops their rows, so there is nothing to open.
            return
        case .group:
            guard !target.isEmpty else { return }
            GroupChatService.shared.pendingGroupNavigation = target
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(
                    name: .openGroup,
                    object: nil,
                    userInfo: ["groupId": target]
                )
            }
        case .wallet:
            // A receipt opens the history of the address that got the Kaspa (chatting or
            // spending - MainTabView works out which), as a tapped banner does. Entries recorded
            // before receipts carried their address fall back to Wallet.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if !target.isEmpty {
                    OwnAddressRoute.pending = target
                    NotificationCenter.default.post(name: .openOwnAddress, object: nil)
                } else {
                    NotificationCenter.default.post(name: .openProfile, object: nil)
                }
            }
        case .token:
            // the token's Manage screen, on the Wallet tab
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                TokenRoute.pending = target.isEmpty ? WalletToken.kusdt.id : target
                NotificationCenter.default.post(name: .openProfile, object: nil)
                NotificationCenter.default.post(name: .openToken, object: nil)
            }
        }
    }
}

// MARK: - Every notification, behind Profile's bell (owner's call, 2026-11-21)

/// A tapped notification that opens the Notifications screen (a KaPosts push naming no post), for
/// Profile's bell to take. Survives a cold start, where the post has no observer yet.
enum NotificationsRoute {
    static var pending = false
}

extension Notification.Name {
    /// Opens the Notifications screen behind Profile's bell.
    static let openAllNotifications = Notification.Name("KaChatOpenAllNotifications")
}

/// Profile's bell: the unseen count across KaPosts activity and the wallet's notifications.
struct AllNotificationsBadge {
    @MainActor static var count: Int {
        KaPostsNotificationCenter.shared.unseenCount + GlobalNotificationCenter.shared.unreadCount
    }
}

/// Every notification in one list (owner's calls, 2026-11-21): KaPosts activity (likes, replies,
/// follows, tips...) and the wallet's (Kaspa and kUSDT received), newest first, no switch between
/// them. A sheet from Profile's bell: no back arrow and no settings gear; swipe down or Done closes it.
struct AllNotificationsView: View {
    var body: some View {
        KaPostsNotificationsView(allInOne: true)
            // seeing the list is seeing them, both kinds
            .onAppear {
                KaPostsNotificationCenter.shared.markAllSeen()
                GlobalNotificationCenter.shared.markAllSeen()
            }
    }
}

/// The bell itself: top right on Profile, with a red count while anything is unseen.
struct AllNotificationsBell: View {
    let action: () -> Void
    @ObservedObject private var kaPostsCenter = KaPostsNotificationCenter.shared
    @ObservedObject private var walletCenter = GlobalNotificationCenter.shared

    var body: some View {
        let count = kaPostsCenter.unseenCount + walletCenter.unreadCount
        Button(action: action) {
            Image(systemName: count > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(count > 0 ? .palette : .monochrome)
                .foregroundStyle(count > 0 ? Color.red : Color.accentColor, Color.accentColor)
        }
        .accessibilityLabel(Text("Notifications"))
        .accessibilityValue(count > 0 ? Text(verbatim: "\(count)") : Text(verbatim: ""))
    }
}
