import SwiftUI
import UIKit
import Combine

/// Moves whenever a name a group row or bubble shows could read differently: a contact renamed
/// (the contacts list), an Address Book name, or Settings' Show .kachat Endings. The group memos
/// (`GroupChatRow.previewText`, `GroupMessageBubbleRow.displayContent`) put it in their keys
/// beside `identityRevision`, so a rename shows at once instead of when the row's text changes
/// (audit 2026-11-24 #10).
@MainActor
final class GroupDisplayNamesRevision {
    static let shared = GroupDisplayNamesRevision()

    private(set) var value = 0
    private var showsEnding = KachatNameLabel.showsEnding
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        ContactsManager.shared.$contacts
            .dropFirst()
            .sink { [weak self] _ in self?.value &+= 1 }
            .store(in: &cancellables)
        AddressBookManager.shared.$entries
            .dropFirst()
            .sink { [weak self] _ in self?.value &+= 1 }
            .store(in: &cancellables)
        // Any UserDefaults write posts this; only a flip of Show .kachat Endings counts.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let now = KachatNameLabel.showsEnding
                guard now != self.showsEnding else { return }
                self.showsEnding = now
                self.value &+= 1
            }
            .store(in: &cancellables)
    }
}

/// A memo key's stamp of the text itself: an edit keeps the message id, and often its length
/// ("teh" -> "the"), so the id and byte count alone kept the old text (audit 2026-11-24 #10).
/// Text up to 16 KB (every editable message) is hashed whole. Past that it's a photo or voice
/// part, which can't be edited, and hashing tens of KB on every draw is what the memo is for
/// avoiding, so its ends stand in for it.
func groupMemoContentStamp(_ text: String) -> String {
    let count = text.utf8.count
    guard count > 16_384 else { return "\(count):\(text.hashValue)" }
    let utf8 = text.utf8
    var hasher = Hasher()
    hasher.combine(count)
    for byte in utf8.prefix(256) { hasher.combine(byte) }
    for byte in utf8.suffix(256) { hasher.combine(byte) }
    return "\(count):\(hasher.finalize())"
}

/// `.navigationDestination(item:)` (iOS 17+), for the same race-free pop as
/// `ChatDetailNavigationDestination` in ChatListView.swift; iOS 16 falls back to `isPresented:`.
struct GroupChatDetailNavigationDestination: ViewModifier {
    @Binding var selectedGroup: GroupChat?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedGroup) { group in
                GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedGroup != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedGroup = nil
                    }
                }
            )) {
                if let group = selectedGroup {
                    GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                } else {
                    EmptyView()
                }
            }
        }
    }
}

/// One group in the chat list: photo, name, the latest message (or reaction) and the unread count.
struct GroupChatRow: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager

    /// Messages are stored oldest-first (loaded sorted, then appended), so the newest is the
    /// last element. This used to be a `max` scan of the whole array - evaluated several times
    /// per row body, on every one of the service's frequent publishes during a sync.
    private var lastMessage: GroupMessage? {
        groupChatService.groupMessages[group.id]?.last
    }

    /// The last message's preview line, worked out once per message: for a photo or voice part
    /// the content is a JSON envelope of tens of KB that `previewText` used to decode on every
    /// draw of the row while the list scrolled. Names that land later move `identityRevision`.
    private static let previewMemo: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    private func previewText(for message: GroupMessage) -> String {
        let key = "\(group.id)|\(message.id.uuidString)|\(groupMemoContentStamp(message.content))|\(group.members.count)|\(KachatNamesRegistry.shared.identityRevision)|\(GroupDisplayNamesRevision.shared.value)" as NSString
        if let cached = Self.previewMemo.object(forKey: key) { return cached as String }
        // a membership line ("<address> joined the group") reads as it does in the thread
        let text = message.senderAddress == GroupChatService.systemSender
            ? GroupSystemLine.display(message.content, name: resolveDisplayName(for:))
            : GroupMentionCodec.decodeForDisplay(LinkSafePreview.apply(to: MessageReplyCodec.previewText(for: message.content)),
                                                 members: group.members, resolveDisplayName: resolveDisplayName(for:))
        Self.previewMemo.setObject(text as NSString, forKey: key)
        return text
    }

    /// Group mirror of ConversationRow.reactionPreviewText: a reaction newer than the last
    /// message becomes the row's preview ("Alice reacted to a message") - reactions never
    /// become messages (they render as a corner pill), so without this the row would keep
    /// showing an older message as if nothing happened. `nil` when the newest activity is a
    /// regular message.
    private var reactionPreviewText: String? {
        guard let byTarget = groupChatService.reactionsByGroupId[group.id], !byTarget.isEmpty else { return nil }
        // Pick the newest reaction purely from the reaction snapshots, then resolve its target
        // once. Resolving inside the loop meant a linear search of the group's whole message
        // array for every reaction target that briefly held the lead.
        var newestSnapshot: (snapshot: GroupStore.ReactionSnapshot, targetTxId: String)?
        for (targetTxId, snapshots) in byTarget {
            guard let candidate = snapshots.max(by: { $0.blockTime < $1.blockTime }) else { continue }
            if newestSnapshot == nil || candidate.blockTime > newestSnapshot!.snapshot.blockTime {
                newestSnapshot = (candidate, targetTxId)
            }
        }
        guard let newestSnapshot else { return nil }
        let newest = (
            snapshot: newestSnapshot.snapshot,
            targetIsMine: groupChatService.groupMessages[group.id]?
                .first(where: { $0.txId == newestSnapshot.targetTxId })?.isOutgoing == true
        )
        // Same rule as 1:1 (ConversationRow.reactionPreviewText): chain time on both sides, a
        // message not in a block yet or within a second of the reaction wins.
        if let lastMessage {
            guard lastMessage.blockTime > 0 else { return nil }
            let lastMs = max(Int64(lastMessage.blockTime), Int64(lastMessage.timestamp.timeIntervalSince1970 * 1000))
            if lastMs + 1000 >= Int64(newest.snapshot.blockTime) { return nil }
        }
        // Shown as Text(String), which skips the lookup: localized here (audit 2026-11-24 #33).
        if newest.snapshot.reactorAddress == walletManager.currentWallet?.publicAddress {
            return AppLocalization.string(newest.targetIsMine ? "You reacted to your message" : "You reacted to a message")
        }
        let name = resolveDisplayName(for: newest.snapshot.reactorAddress)
        return String(format: AppLocalization.string(newest.targetIsMine ? "%@ reacted to your message" : "%@ reacted to a message"), name)
    }

    /// Same resolution as `GroupChatDetailView.displayName(for:)`.
    private func resolveDisplayName(for address: String) -> String {
        // The app's one rule (ContactsManager.displayName): your name for them, else their
        // .kachat name on testnet (KNS elsewhere), else the short address.
        contactsManager.displayName(for: address)
    }

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(group: group, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    // Silenced: no banner from this group, mentioned or not.
                    if groupChatService.silentNotifications(for: group.id) {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Silenced")
                    }

                    Spacer()

                    if let lastMessage {
                        Text(formatDate(lastMessage.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let reactionPreview = reactionPreviewText {
                        Text(reactionPreview)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if let lastMessage {
                        Text(previewText(for: lastMessage))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(group.members.count) member\(pluralS(group.members.count))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    let unreadCount = groupChatService.unreadCount(for: group)
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return SharedFormatting.chatTime.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return SharedFormatting.chatDay.string(from: date)
        }
    }
}

/// A group's photo in a circle, or the group symbol when it has none - its chat list row and
/// its pinned circle.
struct GroupAvatar: View {
    let group: GroupChat
    let size: CGFloat
    @EnvironmentObject var groupChatService: GroupChatService

    /// Decoded group photos, keyed on the group id, the pixel size, the hex length and the payload's tail:
    /// hex-decoding and then JPEG-decoding the photo on every body pass made each row pay for
    /// the whole image on every list refresh. A photo change always changes the hex payload
    /// (and almost always its length), so a stale entry could only survive a same-length
    /// replacement whose final bytes also match - and hashing only the tail keeps the key
    /// itself cheap for a payload that can run to hundreds of kilobytes.
    private static let groupPhotoCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Group ids whose photo didn't decode, under the same key, so a bad one isn't retried per pass.
    private static let failedGroupPhotos = NSCache<NSString, NSNumber>()

    /// An admin-set group photo (`gctl_photo`, anyone in the group can set the bytes), decoded
    /// through `ImageDownsampler` at `maxPixelSize`, never at full size: a few KB can declare a
    /// gigabyte of pixels. Shared with the group's title chip and info header.
    static func decodedGroupPhoto(groupId: String, hex: String, maxPixelSize: Int) -> UIImage? {
        // utf8.count, not count: a character count walks the whole photo's hex on every draw
        let cacheKey = "\(groupId)|\(maxPixelSize)|\(hex.utf8.count)|\(hex.suffix(256).hashValue)" as NSString
        if let cached = groupPhotoCache.object(forKey: cacheKey) {
            return cached
        }
        guard failedGroupPhotos.object(forKey: cacheKey) == nil else { return nil }
        guard let data = Data(hexString: hex),
              let image = ImageDownsampler.image(from: data, maxPixelSize: maxPixelSize) else {
            failedGroupPhotos.setObject(NSNumber(value: true), forKey: cacheKey)
            return nil
        }
        groupPhotoCache.setObject(image, forKey: cacheKey)
        return image
    }

    private var groupPhotoImage: UIImage? {
        guard let hex = groupChatService.groupPhotos[group.id] else { return nil }
        return Self.decodedGroupPhoto(groupId: group.id, hex: hex, maxPixelSize: Int((size * 3).rounded(.up)))
    }

    var body: some View {
        if let img = groupPhotoImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.3.fill")
                        .font(.scaled(size: size * 0.36))
                        .foregroundColor(.accentColor)
                )
        }
    }
}
