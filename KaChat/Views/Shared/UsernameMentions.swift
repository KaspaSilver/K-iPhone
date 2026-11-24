import SwiftUI

// @mentions by .kachat username (owner, 2026-11-24): in group chats, public chats and KaPost you
// can @ someone only if they have a username. One set of rules for all three:
// - group chats keep their wire format: the mention goes out as `@<address>` (GroupMentionCodec),
//   so it survives a rename, and shows as the member's current @username;
// - public chats and KaPost are public text: the mention is the plain `@username` (KaPost also signs
//   the mentioned keys, `mentionedPubkeys(in:)`);
// - a token is only a mention when it is a valid username (`a-z 0-9 -`, 1-32, an optional
//   `.kachat` ending); `@word` that can't be a username stays text.

enum UsernameMention {
    /// `@alice` / `@alice.kachat` after a start of text, a space or an opening bracket or quote.
    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"(^|[\s(\[{<"'])@([A-Za-z0-9-]{1,32})(\.kachat)?(?![A-Za-z0-9-])"#,
        options: [.caseInsensitive]
    )

    struct Token {
        /// Where `@name` (with any ending) sits in the text.
        let range: NSRange
        /// The bare username, lowercased.
        let name: String
    }

    /// Every username-shaped @token in `text`. Cheap when there's no "@".
    static func tokens(in text: String) -> [Token] {
        guard text.contains("@"), let regex = tokenRegex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let nameRange = match.range(at: 2)
            let name = ns.substring(with: nameRange).lowercased()
            guard KachatNames.Codec.isValid(name) else { return nil }
            let start = nameRange.location - 1  // the "@"
            let end = match.range(at: 3).location != NSNotFound ? NSMaxRange(match.range(at: 3)) : NSMaxRange(nameRange)
            return Token(range: NSRange(location: start, length: end - start), name: name)
        }
    }

    /// The username someone is @'d by, as the app shows names (with or without the ending): nil
    /// when they have none, so they can't be mentioned.
    @MainActor
    static func handle(for address: String) -> String? {
        guard let label = KachatNamesRegistry.shared.cachedIdentity(for: address)?.label,
              KachatNames.Codec.isValid(KachatNames.Codec.normalize(label)) else { return nil }
        return KachatNameLabel.display(KachatNames.Codec.normalize(label))
    }

    /// The bare username of the signed-in account, if it has one.
    @MainActor
    static var myName: String? {
        guard let me = WalletManager.shared.currentWallet?.publicAddress,
              let label = KachatNamesRegistry.shared.cachedIdentity(for: me)?.label else { return nil }
        return KachatNames.Codec.normalize(label)
    }

    /// Whether public text @'s the signed-in account by its username.
    @MainActor
    static func mentionsMe(_ text: String) -> Bool {
        guard let me = myName else { return false }
        return tokens(in: text).contains { $0.name == me }
    }

    /// The @token being typed at the end of `text` ("" right after the "@"), or nil.
    static func typedQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let before = text[text.startIndex..<at].last
        guard before == nil || before!.isWhitespace || "([{<\"'".contains(before!) else { return nil }
        let query = String(text[text.index(after: at)...])
        guard query.count <= 32, query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return query.lowercased()
    }

    /// Opens the profile of whoever `name` belongs to (KaPost's profile sheet). Unknown names do
    /// nothing.
    @MainActor
    static func openProfile(name: String) {
        Task { @MainActor in
            guard let resolution = NameServicesClient.primary(of: await NameServicesClient.shared.resolveEverywhere(name), typed: name),
                  let address = resolution.address else { return }
            KaPostsDeepLink.pendingProfileAddress = address
            NotificationCenter.default.post(name: .openKaPostsProfile, object: nil)
        }
    }
}

extension UsernameMention {
    /// The URL scheme a mention run links to; `UsernameMention.handle(url:)` opens it.
    static let linkScheme = "kachat-username"

    /// Public text (a room message) with each @username styled and tappable (opens the
    /// profile through `linkScheme`). nil when the text mentions nobody, so plain text stays plain.
    static func attributed(_ text: String, isOutgoing: Bool) -> AttributedString? {
        let found = tokens(in: text)
        guard !found.isEmpty else { return nil }
        let ns = text as NSString
        var out = AttributedString()
        var cursor = 0
        for token in found {
            if token.range.location > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            }
            var mention = AttributedString(ns.substring(with: token.range))
            mention.font = .body.weight(.semibold)
            mention.foregroundColor = isOutgoing ? .white : .accentColor
            mention.link = URL(string: "\(linkScheme)://\(token.name)")
            out += mention
            cursor = NSMaxRange(token.range)
        }
        if cursor < ns.length {
            out += AttributedString(ns.substring(from: cursor))
        }
        return out
    }

    /// Opens a `linkScheme` URL's profile; false for any other URL.
    @MainActor
    static func handle(url: URL) -> Bool {
        guard url.scheme == linkScheme, let name = url.host, KachatNames.Codec.isValid(name) else { return false }
        openProfile(name: name)
        return true
    }
}

/// Someone who can be @'d: their address and the username the @ inserts.
struct MentionCandidate: Identifiable, Hashable {
    let address: String
    let handle: String
    var id: String { address.lowercased() }
}

/// The list of people to @ above a composer: tap one to insert their username.
struct MentionSuggestionList: View {
    let candidates: [MentionCandidate]
    let onPick: (MentionCandidate) -> Void

    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 4

    var body: some View {
        if !candidates.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        Button {
                            Haptics.selection()
                            onPick(candidate)
                        } label: {
                            HStack(spacing: 10) {
                                KNSAvatarView(avatarURLString: nil, fallbackText: candidate.handle, size: 28,
                                              contactAddress: candidate.address)
                                Text(verbatim: "@\(candidate.handle)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "@\(candidate.handle)"))
                        if candidate.id != candidates.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(min(candidates.count, Self.visibleRows)))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}
