import Combine
import Foundation
import SwiftUI

/// The wallet's half of Profile's bell: Kaspa arriving in one of your own addresses - the
/// chatting address or a spending address (fed by AddressActivityNotifier) - and tokens received.
/// Not group chats (they keep their own unread counts in the Chats tab). Entries are
/// account-scoped, persisted, deduped by id, and capped; opening the list marks everything seen.
@MainActor
final class GlobalNotificationCenter: ObservableObject {
    static let shared = GlobalNotificationCenter()

    struct Entry: Identifiable, Codable, Equatable {
        enum Source: String, Codable {
            /// `kaposts`, `group` and `publicChat` are no longer recorded here (KaPosts activity has
            /// its own center, groups and rooms their own counts): kept only so a feed saved by an
            /// older build still decodes - `reload` drops those rows.
            case kaposts, group, wallet
            case publicChat = "broadcast"
            /// A .kachat name event (`KachatNamesNotifier`). Not in the bell (`inBell`), so these
            /// are refused on record and dropped on load.
            case kachat
            /// A token received (kUSDT); `targetId` is the token's id.
            case token

            var label: String {
                switch self {
                case .kaposts: return "KaPost"
                case .group: return "Group"
                case .publicChat: return "Public Chat"
                case .wallet: return "Wallet"
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

    /// The account `entries` were loaded for. The feed is read and saved under this address, not
    /// whatever wallet is current at write time, so one account's rows never land under another's
    /// key. Empty while no one is signed in: nothing is shown and nothing is saved.
    private var loadedAddress = ""
    private var walletCancellable: AnyCancellable?

    private init() {
        loadedAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        reload()
        // Log Out, sign-in, import and account switches all change `currentWallet`. Reloading only
        // at launch left the last account's rows in the bell, and the next account's first
        // notification saved them under its own key for good (as `KaPostsNotificationCenter`).
        // `@Published` fires before the value is stored, so the new address comes from the sink,
        // not from `WalletManager`.
        walletCancellable = WalletManager.shared.$currentWallet
            .map { $0?.publicAddress ?? "" }
            .removeDuplicates()
            .sink { [weak self] address in
                guard let self, address != self.loadedAddress else { return }
                self.loadedAddress = address
                self.reload()
            }
    }

    // MARK: - Persistence (account-scoped)

    private var entriesKey: String { "globalNotifCenter.entries.\(loadedAddress)" }
    private var seenKey: String { "globalNotifCenter.seenAt.\(loadedAddress)" }

    /// Delete Account: one wallet's feed, from this device (and from the bell, when it is the
    /// one showing, so nothing saves it back).
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.entries.\(walletAddress)")
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.seenAt.\(walletAddress)")
        let center = shared
        if !walletAddress.isEmpty, center.loadedAddress == walletAddress {
            center.entries = []
            center.lastSeenAt = 0
        }
    }

    /// Loads the active wallet's feed (account switches reload by themselves, see `init`).
    func reload() {
        guard !loadedAddress.isEmpty else {
            // signed out: the bell is empty, never the last account's
            entries = []
            lastSeenAt = 0
            return
        }
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            // Wallet rows only (`inBell`). Group mentions carry their own counts in the Chats tab,
            // and KaPosts activity has its own center; anything an older build saved for those is
            // dropped here.
            let kept = decoded.filter { Entry.Source.inBell.contains($0.source) }
            entries = kept
            if kept.count != decoded.count { persist() }
        } else {
            entries = []
        }
        lastSeenAt = (UserDefaults.standard.object(forKey: seenKey) as? NSNumber)?.int64Value ?? 0
    }

    private func persist() {
        guard !loadedAddress.isEmpty else { return }
        if let data = try? JSONEncoder().encode(Array(entries.prefix(maxEntries))) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: - Feed mutations

    func record(id: String, source: Entry.Source, title: String, body: String, timestamp: Int64, targetId: String?) {
        // Only what the bell lists. Refused here rather than merely left uncalled.
        guard Entry.Source.inBell.contains(source) else { return }
        // no one signed in: there is no account to keep it for
        guard !loadedAddress.isEmpty else { return }
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        entries.insert(Entry(id: id, source: source, title: title, body: body, timestamp: timestamp, targetId: targetId), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func markAllSeen() {
        guard !loadedAddress.isEmpty else { return }
        lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: lastSeenAt), forKey: seenKey)
    }

    func clearAll() {
        entries = []
        persist()
    }

    // MARK: - Opening a row

    /// Routes a tapped row to its subject. The sheet has to close first (only one sheet presents
    /// at a time), so the pending target is staged now and the tab switch posted after the
    /// dismissal animation - the same two-step every notification tap uses.
    /// Called by the Notifications list behind Profile's bell (`KaPostsNotificationsView`).
    static func open(_ entry: GlobalNotificationCenter.Entry, dismiss: () -> Void) {
        let target = entry.targetId ?? ""
        switch entry.source {
        case .kaposts, .publicChat, .kachat:
            // Not in the bell; `reload` drops their rows, so there is nothing to open.
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
        KaPostsNotificationsView()
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
