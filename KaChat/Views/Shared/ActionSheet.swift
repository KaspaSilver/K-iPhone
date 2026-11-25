import SwiftUI

/// The app's frosted card: the one shared helper every screen draws it with.
func glassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

/// One option in a half-sheet menu: an icon, a title, and a line saying what the option does.
///
/// The app's menus used to be popovers and confirmation dialogs of bare labels, which have room
/// for a verb and nothing else. Every menu that has since become a sheet - Address Actions, the transaction menu below - is built from this,
/// so they read as the same kind of object wherever they appear.
struct ActionSheetRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor
    var isBusy: Bool = false
    var isDisabled: Bool = false
    /// An asset image in place of the SF Symbol - the Kaspa logo on "Pay in Kaspa", which every
    /// menu in the app shows with the logo rather than a stand-in glyph.
    var customIcon: Image? = nil
    let action: () -> Void

    /// Set by `ActionSheetTiles`: draw as a square tile (icon over title) instead of a row.
    @Environment(\.actionSheetTiles) private var asTile

    var body: some View {
        if asTile {
            tile
        } else {
            row
        }
    }

    /// The square form, for long-press menus: the icon and a short title, so a glance says what
    /// each one does. The explanatory line becomes the VoiceOver hint.
    private var tile: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if isBusy {
                        ProgressView()
                    } else if let customIcon {
                        customIcon
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(tint)
                    }
                }
                .frame(height: 30)
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint == .accentColor ? .primary : tint)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .frame(height: ActionSheetTileMetrics.tileHeight)
            .background(glassBackground(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled)
        .accessibilityHint(Text(LocalizedStringKey(subtitle)))
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let customIcon {
                        customIcon
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: systemImage)
                            .font(.scaled(size: 18, weight: .semibold))
                            .foregroundColor(tint)
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    // Looked up, not shown verbatim: `Text(String)` skips Localizable.strings, so
                    // every action sheet read in English in all 18 other languages. A title
                    // with no translation still shows as written.
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(tint == .accentColor ? .primary : tint)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(glassBackground(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled)
    }
}

private struct ActionSheetTilesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether `ActionSheetRow`s draw as square tiles (inside `ActionSheetTiles`).
    var actionSheetTiles: Bool {
        get { self[ActionSheetTilesKey.self] }
        set { self[ActionSheetTilesKey.self] = newValue }
    }
}

/// Lays the `ActionSheetRow`s inside it out as square tiles, three to a row - the look of every
/// long-press menu in the app (messages, chat rows, group and room circles, room rows), so each
/// option reads at a glance instead of as a paragraph.
struct ActionSheetTiles<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let spacing = ActionSheetTileMetrics.spacing
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3), spacing: spacing) {
            content
        }
        .environment(\.actionSheetTiles, true)
    }
}

/// Sizes for `ActionSheetTiles`, and a sheet height to fit them.
enum ActionSheetTileMetrics {
    static let tileHeight: CGFloat = 96
    static let spacing: CGFloat = 12

    /// The grid's height for `count` tiles.
    static func gridHeight(for count: Int) -> CGFloat {
        let rows = CGFloat(max(1, (count + 2) / 3))
        return rows * tileHeight + (rows - 1) * spacing
    }

    /// A tiles sheet's height: its title area, the grid, and the bottom padding.
    static func sheetHeight(tiles count: Int, header: CGFloat = 70) -> CGFloat {
        header + gridHeight(for: count) + 44
    }
}

/// Who reacted to one message, and with what.
///
/// The pill on a bubble shows which emoji are on it and nothing else - not how many of each, and
/// not from whom. Shared by 1:1 and group messages, which each carry their own
/// reaction snapshot type; callers map theirs into `Entry`.
struct ReactionsSheet: View {
    struct Entry: Identifiable {
        let emoji: String
        let reactorAddress: String
        var id: String { "\(emoji)-\(reactorAddress)" }
    }

    let entries: [Entry]
    let myAddress: String
    let displayName: (String) -> String
    /// KNS avatar for a reactor, when one is cached. A face is how you recognise someone in a
    /// list of names you may not have saved.
    var avatarURL: (String) -> String? = { _ in nil }

    /// One emoji and everyone who used it. A named type, not a tuple: an array of labelled
    /// tuples built by a chained map/sorted is expensive for the type checker to infer.
    private struct EmojiGroup: Identifiable {
        let emoji: String
        let reactors: [Entry]
        var id: String { emoji }
    }

    private var grouped: [EmojiGroup] {
        let byEmoji: [String: [Entry]] = Dictionary(grouping: entries, by: { $0.emoji })
        let groups: [EmojiGroup] = byEmoji.map { EmojiGroup(emoji: $0.key, reactors: $0.value) }
        return groups.sorted { $0.reactors.count > $1.reactors.count }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped) { group in
                    Section {
                        ForEach(group.reactors) { entry in
                            let name = entry.reactorAddress == myAddress
                                ? "You"
                                : displayName(entry.reactorAddress)
                            HStack(spacing: 10) {
                                KNSAvatarView(
                                    avatarURLString: avatarURL(entry.reactorAddress),
                                    fallbackText: name,
                                    size: 28,
                                    contactAddress: entry.reactorAddress
                                )
                                Text(name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(group.emoji).font(.title3)
                            Text(group.reactors.count == 1 ? "1 person" : "\(group.reactors.count) people")
                        }
                    }
                }
            }
            .navigationTitle(entries.count == 1 ? "1 Reaction" : "\(entries.count) Reactions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Identifiable wrapper so a plain txId can drive `.sheet(item:)`.
/// The options button at the top right of every address page (the chatting address and each
/// spending address). Opens `AddressActionsSheet`.
struct AddressOptionsButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: 32)
                .background(Circle().fill(.regularMaterial))
        }
        .accessibilityLabel(Text("Address Actions"))
    }
}

/// The same half sheet on every address page. A row that opens another screen closes this
/// sheet first and opens it from `onDismiss`, as a sheet presented while another is still
/// closing can be dropped.
struct AddressActionsSheet: View {
    /// A quantum address keeps its key hidden until it spends, so it has none to show.
    var showsPublicKey = true
    let explorerURL: URL?
    /// Nil where the app doesn't hold the key (Cold Storage).
    var onViewPrivateKey: (() -> Void)? = nil
    let onViewPublicKey: () -> Void
    let onViewInExplorer: (URL) -> Void

    /// Fits however many rows are showing. Present with `fittedSheetDetents(height)`, so the
    /// rows aren't cut off at large text sizes.
    var height: CGFloat {
        let rows = (onViewPrivateKey == nil ? 0 : 1) + (showsPublicKey ? 1 : 0) + (explorerURL == nil ? 0 : 1)
        return 90 + CGFloat(rows) * 80
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Address Actions")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            VStack(spacing: 12) {
                if let onViewPrivateKey {
                    ActionSheetRow(
                        title: "View Private Key",
                        subtitle: "The key that spends this address. Never share it.",
                        systemImage: "key.fill",
                        action: onViewPrivateKey
                    )
                }
                if showsPublicKey {
                    ActionSheetRow(
                        title: "View Public Key",
                        subtitle: "The public half of this address, for anyone who asks for it.",
                        systemImage: "number",
                        action: onViewPublicKey
                    )
                }
                if let explorerURL {
                    ActionSheetRow(
                        title: "View in Explorer",
                        subtitle: "Opens this address on your chosen block explorer.",
                        systemImage: "globe"
                    ) {
                        onViewInExplorer(explorerURL)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 20)
    }
}

struct ReactionsSheetTarget: Identifiable {
    let txId: String
    var id: String { txId }
}

/// So the transaction menu can be presented with `.sheet(item:)`. A txid is already the identity
/// of a transaction, and the property is computed, so it stays out of the Codable synthesis.
extension KaspaFullTransactionResponse: Identifiable {
    var id: String { transactionId }
}

/// What to do with a transaction you tapped in an address history: look at it, or record it.
///
/// Shared by cold storage history, the spending-address histories and the chatting address, all
/// three of which used to raise their own identical confirmation dialog.
struct TransactionActionsSheet: View {
    let transaction: KaspaFullTransactionResponse
    /// The address the history was viewed under, which is what decides whether this reads as
    /// money in or money out.
    let address: String
    let onOpenExplorer: () -> Void
    /// Nil candidate means the transaction has no side involving `address` we can price, so
    /// there is nothing to record and the option is not offered.
    var onAddToPortfolio: ((PortfolioCandidateTransaction) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var candidate: PortfolioCandidateTransaction? {
        PortfolioCandidateTransaction(transaction: transaction, address: address)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Transaction")
                    .font(.headline)
                if let candidate {
                    Text(summary(candidate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(transaction.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 8)

            ActionSheetRow(
                title: "Open in Explorer",
                subtitle: "Opens this transaction on the block explorer.",
                systemImage: "safari"
            ) {
                dismiss()
                onOpenExplorer()
            }

            if let candidate, let onAddToPortfolio {
                ActionSheetRow(
                    title: "Add to Portfolio",
                    subtitle: "Records it as a buy or a sell in a portfolio of your choosing.",
                    systemImage: "chart.pie.fill"
                ) {
                    dismiss()
                    onAddToPortfolio(candidate)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .fittedSheetDetents(candidate == nil || onAddToPortfolio == nil ? 250 : 320)
        .presentationDragIndicator(.visible)
    }

    private func summary(_ candidate: PortfolioCandidateTransaction) -> String {
        let format = AppLocalization.string(candidate.isOutgoing ? "Sent %@ on %@" : "Received %@ on %@")
        return String(
            format: format,
            locale: AppLocalization.locale,
            PortfolioFormat.kas(candidate.amountKas),
            candidate.timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale))
        )
    }
}


/// A URL made Identifiable so `.sheet(item:)` can present on it - `URL` itself is not.
struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
    init(_ url: URL) { self.url = url }
}

/// What to do with a link someone sent: the half-sheet form of the old confirmation dialog.
///
/// A dialog of bare labels could show the verb and nothing else, and put the URL in small print
/// above the buttons. As a sheet the link itself gets room to be read - which matters, because
/// deciding whether to open a link IS reading it.
struct LinkActionsSheet: View {
    let url: URL
    let onOpen: () -> Void
    let onCopy: () -> Void
    /// Nil where replying makes no sense (a message that has no thread to reply in).
    var onReply: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(url.absoluteString)
                .font(.footnote.weight(.medium))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: "Open Link",
                subtitle: "Opens in your browser.",
                systemImage: "safari"
            ) { dismiss(); onOpen() }

            ActionSheetRow(
                title: "Copy Link",
                subtitle: "Copies the address to your clipboard.",
                systemImage: "doc.on.doc"
            ) { dismiss(); onCopy() }

            if let onReply {
                ActionSheetRow(
                    title: "Reply",
                    subtitle: "Reply to this message instead.",
                    systemImage: "arrowshape.turn.up.left"
                ) { dismiss(); onReply() }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(onReply == nil ? 260 : 330)])
    }
}


/// Repost as-is, or quote it with your own words - the half-sheet form of the old dialog.
struct RepostActionsSheet: View {
    let onRepost: () -> Void
    let onQuote: () -> Void
    /// Set when the post is already reposted, so the first row offers to take it back.
    var isReposted: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(isReposted ? "Reposted" : "Repost")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: isReposted ? "Undo Repost" : "Repost",
                subtitle: isReposted
                    ? "Removes it from your profile."
                    : "Shares it to your followers as-is.",
                systemImage: isReposted ? "arrow.uturn.backward" : "arrow.2.squarepath",
                tint: isReposted ? .red : .accentColor
            ) { dismiss(); onRepost() }

            ActionSheetRow(
                title: "Quote",
                subtitle: "Adds your own words above it.",
                systemImage: "quote.bubble"
            ) { dismiss(); onQuote() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
    }
}


/// Closing the composer with something written: keep it, or throw it away.
///
/// A sheet rather than a confirmation dialog so each choice can say what happens to the post -
/// "Save Draft" and "Discard" as bare verbs leave you to work out where a saved one goes.
struct ComposerCloseOptionsSheet: View {
    let onSaveDraft: () -> Void
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Save this post?")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: "Save Draft",
                subtitle: "Keep it in Drafts to finish later.",
                systemImage: "square.and.arrow.down"
            ) { dismiss(); onSaveDraft() }

            ActionSheetRow(
                title: "Discard",
                subtitle: "Throw this away.",
                systemImage: "trash",
                tint: .red
            ) { dismiss(); onDiscard() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
    }
}

/// A yes/no confirmation, in a half sheet.
///
/// The app's confirmations were `.confirmationDialog`s - a stack of bare verbs with the reason
/// squeezed into a small grey line above them. As a sheet the consequence gets a full row of its
/// own next to the action it belongs to, which is what someone about to log out or delete
/// something is actually reading for.
struct ConfirmActionSheet: View {
    let title: String
    let confirmTitle: String
    /// What actually happens if they go ahead - the row's second line.
    let confirmSubtitle: String
    var confirmSystemImage: String = "checkmark.circle"
    var isDestructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(AppLocalization.string(title))
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: confirmTitle,
                subtitle: confirmSubtitle,
                systemImage: confirmSystemImage,
                tint: isDestructive ? .red : .accentColor
            ) { dismiss(); onConfirm() }

            ActionSheetRow(
                title: "Cancel",
                subtitle: "Leave everything as it is.",
                systemImage: "xmark"
            ) { dismiss() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

/// A transaction id made Identifiable, for `.sheet(item:)` presentations keyed on one message.
struct IdentifiedTxId: Identifiable {
    let id: String
}

/// The warning before an account is deleted, from Settings or the sign-in screen. Nothing can
/// bring the account back without its seed phrase (and passphrase), so it says that first.
struct DeleteAccountSheet: View {
    /// What goes: the Delete row's second line.
    let confirmSubtitle: String
    /// Settings only: a signed-out account on the sign-in screen has no seed phrase open to show.
    var onViewSeedPhrase: (() -> Void)? = nil
    /// This account hasn't finished the backup steps: the warning says so. Deleting stays possible
    /// (an empty account someone doesn't want shouldn't have to be backed up first).
    var notBackedUp = false
    /// Settings only: into the backup steps, in place of the seed phrase row.
    var onBackUp: (() -> Void)? = nil
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.scaled(size: 34, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.top, 24)

                Text("Delete Account")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if notBackedUp {
                    Text("This account isn't backed up. If you delete it now, it and its funds can never be recovered.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    if onBackUp == nil {
                        Text("To back it up first, sign in to it and tap the backup banner under the balance.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Text("Make sure your 12 or 24 words are backed up, and your passphrase too if you have one. They are the only way to recover this account and its funds.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                if notBackedUp, let onBackUp {
                    ActionSheetRow(
                        title: "Back Up Account",
                        subtitle: "Write down your 12 or 24 words before you delete.",
                        systemImage: "exclamationmark.shield",
                        action: onBackUp
                    )
                } else if let onViewSeedPhrase {
                    ActionSheetRow(
                        title: "View 12 or 24 Words and Passphrase",
                        subtitle: "The passphrase shows too, if this account has one.",
                        systemImage: "key",
                        action: onViewSeedPhrase
                    )
                }

                ActionSheetRow(
                    title: "Delete Account",
                    subtitle: confirmSubtitle,
                    systemImage: "trash",
                    tint: .red
                ) { dismiss(); onConfirm() }

                ActionSheetRow(
                    title: "Cancel",
                    subtitle: "Leave everything as it is.",
                    systemImage: "xmark"
                ) { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Sent confirmation

/// A completed Kaspa send. Identifiable on the txid so it can drive a `.sheet(item:)` directly.
struct SentTransaction: Identifiable, Equatable {
    let txId: String
    /// Amount in sompi. nil omits the amount line - a consolidation has no meaningful "to whom"
    /// or "how much" to report.
    var amountSompi: UInt64?
    /// Who it went to: a contact's name, a KNS domain, an address. nil omits the line.
    var recipient: String?

    var id: String { txId }
}

// MARK: - Message long-press menu

/// One row of a message's long-press menu: an icon, a title, and a line saying what it does.
struct MessageAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    // The rows every kind of bubble shares, worded once so a Reply reads the same on a photo,
    // a voice note and a line of text.
    static func reply(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Reply", subtitle: "Quotes this message above your reply.", systemImage: "arrowshape.turn.up.left", action: action)
    }
    static func edit(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Edit", subtitle: "Changes the text. Everyone sees the new version.", systemImage: "pencil", action: action)
    }
    static func deleteForEveryone(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Delete for Everyone", subtitle: "Removes it from this room for everyone using K.", systemImage: "trash", tint: .red, action: action)
    }
    static func copyMessage(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Copy Message", subtitle: "Copies the text to your clipboard.", systemImage: "doc.on.doc", action: action)
    }
    static func copyLink(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Copy Link", subtitle: "Copies the address to your clipboard.", systemImage: "link", action: action)
    }
    static func explorer(_ url: URL) -> MessageAction {
        MessageAction(title: "View in Explorer", subtitle: "Opens this transaction in the block explorer.", systemImage: "safari") {
            UIApplication.shared.open(url)
        }
    }
    static func reactions(count: Int, _ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: String(format: AppLocalization.string("Reactions (%lld)"), count), subtitle: "Who reacted, and with what.", systemImage: "heart", action: action)
    }
    static func retry(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Retry Send", subtitle: "Sends this message again.", systemImage: "arrow.clockwise", action: action)
    }
    static func select(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Select", subtitle: "Pick several messages at once.", systemImage: "checkmark.circle", action: action)
    }
    // KaPosts and Public Chats rooms (from KaPost, 2026-11-21)
    static func report(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Report", subtitle: "Report abusive or objectionable content. Opens an email with this message attached.", systemImage: "flag", action: action)
    }
    static func openLink(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Open Link", subtitle: "Opens it in your browser.", systemImage: "safari", action: action)
    }
    static func translate(into language: String, _ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Translate", subtitle: "Shows this message in \(language).", systemImage: "character.bubble", action: action)
    }
    static func showOriginal(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Show Original", subtitle: "Back to the text as it was sent.", systemImage: "arrow.uturn.backward", action: action)
    }
    static func showTranslation(_ action: @escaping () -> Void) -> MessageAction {
        MessageAction(title: "Show Translation", subtitle: "The translated text again.", systemImage: "character.bubble", action: action)
    }
}

/// A message's long-press menu, as a half sheet: what the message is at the top, then a row
/// per action. The same object as every other menu in the app; the system context menu was
/// the one hold-out, with its bare verbs and its lifted, blurred preview.
struct MessageActionsRequest: Identifiable {
    let id = UUID()
    let title: String
    let preview: String?
    let actions: [MessageAction]
}

struct MessageActionsSheet: View {
    let request: MessageActionsRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(AppLocalization.string(request.title))
                    .font(.headline)
                if let preview = request.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                ActionSheetTiles {
                    ForEach(request.actions) { action in
                        ActionSheetRow(
                            title: action.title,
                            subtitle: action.subtitle,
                            systemImage: action.systemImage,
                            tint: action.tint
                        ) {
                            dismiss()
                            // A beat after the sheet is away, so an action that presents a
                            // sheet of its own (reactions, saving audio) is not presenting
                            // over one that is still dismissing.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { action.action() }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }

    private var height: CGFloat {
        let header: CGFloat = request.preview == nil ? 76 : 116
        return min(UIScreen.main.bounds.height * 0.85, header + ActionSheetTileMetrics.gridHeight(for: request.actions.count) + 40)
    }
}

/// The moment a link under the finger opened its own sheet - a bubble's message menu stands
/// down for it, so a long press on a link is one sheet, not two.
@MainActor
enum LinkLongPress {
    static var lastFiredAt: Date = .distantPast
}

private struct MessageActionsModifier: ViewModifier {
    let title: String
    let preview: String?
    let actions: () -> [MessageAction]
    @State private var request: MessageActionsRequest?

    func body(content: Content) -> some View {
        content
            // Half a second: longer than the link long-press inside a text bubble (0.45s), so
            // on a link that one wins and this never fires.
            .onLongPressGesture(minimumDuration: 0.5) {
                guard Date().timeIntervalSince(LinkLongPress.lastFiredAt) > 0.8 else { return }
                let built = actions()
                guard !built.isEmpty else { return }
                Haptics.impact(.medium)
                request = MessageActionsRequest(title: title, preview: preview, actions: built)
            }
            .sheet(item: $request) { MessageActionsSheet(request: $0) }
    }
}

extension View {
    /// The message's long-press menu as a half sheet, in place of `.contextMenu`. `actions`
    /// is built at the press, so it sees the message as it is then.
    func messageActions(title: String, preview: String? = nil, actions: @escaping () -> [MessageAction]) -> some View {
        modifier(MessageActionsModifier(title: title, preview: preview, actions: actions))
    }
}

// MARK: - Coin list failure

/// In place of an empty coin list when the node could not be asked. An outage used to render
/// as "no coins", which is the wrong thing to believe.
struct UtxoLoadFailureRow: View {
    let detail: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load the coins at this address", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.red)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Try Again", action: retry)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Type that follows the user's text size

extension Font {
    /// A fixed point size, scaled by the user's Dynamic Type setting the way the system text
    /// styles are. 173 places in the views set a point size directly and stayed that size
    /// however large the person set their text; this keeps the design's proportions and
    /// grows with the setting.
    static func scaled(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: design)
    }
}

// MARK: - Delivery status

/// The state of an outgoing message, said in words next to its glyph: "Sending", "Sent",
/// "Failed · Tap to retry". The glyph alone was a colour-coded dot that VoiceOver read as
/// nothing and a colour-blind reader could not tell apart. `retry` makes the failed state a
/// button.
/// The line under a message: its time, and - for your own messages - the delivery status right
/// after it ("10:57  ✓ Sent"). Every chat shows this under every message; it replaced the
/// swipe-left-to-reveal times (5.2).
struct MessageTimeLine<Status: View>: View {
    let date: Date
    /// In a long feed, a message from another day says which ("Yesterday,
    /// 9:41 AM", "Sep 28, 9:41 AM"). Threads keep the bare time under their day separators.
    var showsDay: Bool = false
    @ViewBuilder var status: () -> Status

    var body: some View {
        HStack(spacing: 6) {
            status()
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var text: String {
        let time = SharedFormatting.chatTime.string(from: date)
        guard showsDay, !Calendar.current.isDateInToday(date) else { return time }
        let day = Calendar.current.isDateInYesterday(date)
            ? AppLocalization.string("Yesterday")
            : SharedFormatting.chatDay.string(from: date)
        return "\(day), \(time)"
    }
}

struct DeliveryStatusLabel: View {
    enum Status {
        /// `unconfirmed`: our send whose outcome is unknown. It may have landed, so no Retry.
        case pending, sent, failed, warning, unconfirmed

        init(_ status: ChatMessage.DeliveryStatus, isOutgoing: Bool) {
            switch status {
            case .sent: self = .sent
            case .pending: self = .pending
            case .failed: self = .failed
            case .warning: self = isOutgoing ? .unconfirmed : .warning
            }
        }
    }

    let status: Status
    var retry: (() -> Void)? = nil
    /// The chat list's smaller, secondary rendering.
    var compact: Bool = false

    var body: some View {
        if status == .failed, let retry {
            Button(action: retry) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("Failed to send. Tap to retry.")
        } else {
            content.accessibilityLabel(Text(LocalizedStringKey(accessibilityText)))
        }
    }

    private var content: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(LocalizedStringKey(text))
        }
        .font(.caption2)
        .foregroundColor(color)
    }

    private var icon: String {
        switch status {
        case .sent: return compact ? "checkmark" : "checkmark.circle.fill"
        case .pending: return "clock"
        case .failed: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .unconfirmed: return "questionmark.circle"
        }
    }

    private var text: String {
        switch status {
        case .sent: return "Sent"
        case .pending: return "Sending"
        case .failed: return retry == nil ? "Failed" : "Failed · Tap to retry"
        case .warning: return "Needs attention"
        case .unconfirmed: return "Not confirmed"
        }
    }

    private var color: Color {
        switch status {
        case .sent: return compact ? .secondary : .green
        case .pending: return .secondary
        case .failed: return .red
        case .warning, .unconfirmed: return .orange
        }
    }

    private var accessibilityText: String {
        switch status {
        case .sent: return "Sent"
        case .pending: return "Sending"
        case .failed: return "Failed to send"
        case .warning: return "Needs attention"
        case .unconfirmed: return "Not confirmed yet. It may still go through."
        }
    }
}

// MARK: - Chat header tap band

/// The header row over a 1:1 or group thread: the avatar-over-name chip, centred
/// in a full-width band. Taps over the chip - and a margin either side of it - open the info
/// screen; taps on the dead space further out jump to the first message.
///
/// The chip's own Button is not enough. The row is pulled up into the navigation bar's row,
/// so the avatar sits inside the bar, and taps there reached the band behind the chip instead
/// of the chip - tapping the avatar jumped to the top of the thread. The band now decides by
/// where the tap landed, so wherever a tap on the chip ends up, it opens the info screen.
///
/// The band alone still missed the avatar's top half: that part is drawn inside the navigation
/// bar, and the bar takes the touch before anything underneath sees it. An invisible principal
/// item fills the bar's middle, over the avatar, and opens the info screen too.
private struct ChatHeaderTapBand: ViewModifier {
    let onChip: () -> Void
    let onBand: () -> Void
    @State private var chipWidth: CGFloat = 0

    /// Extra reach either side of the chip, so a tap just off the pill still counts.
    private let chipMargin: CGFloat = 40
    /// Pressed through the bar's tap area (the photo's half): the chip dims there too.
    @State private var barPressed = false

    func body(content: Content) -> some View {
        content
            .opacity(barPressed ? 0.6 : 1)
            .scaleEffect(barPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: barPressed)
            .background(
                GeometryReader { chip in
                    Color.clear.preference(key: ChatHeaderChipWidthKey.self, value: chip.size.width)
                }
            )
            .onPreferenceChange(ChatHeaderChipWidthKey.self) { chipWidth = $0 }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // The photo half of the chip sits inside the navigation bar, which takes the
                    // touches there: this catches them. A press (not just a tap) so the chip
                    // answers the moment a finger lands, and a small slide still counts
                    // (2026-11-24: "hard to click, sometimes no click happens").
                    Color.clear
                        .frame(width: max(chipWidth, 120) + chipMargin * 2, height: 44)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in if !barPressed { barPressed = true } }
                                .onEnded { value in
                                    barPressed = false
                                    if abs(value.translation.width) < 30, abs(value.translation.height) < 30 {
                                        Haptics.selection()
                                        onChip()
                                    }
                                }
                        )
                        // the chip below already says what this does
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            // A BACKGROUND, not a ZStack layer: `Color.clear` in a ZStack is flexible in both
            // axes and would size the whole inset to the proposed height, swallowing the screen.
            // As a background it takes exactly the row's frame.
            .background(
                GeometryReader { band in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { tap in
                                let reach = chipWidth / 2 + chipMargin
                                if abs(tap.location.x - band.size.width / 2) <= reach {
                                    Haptics.selection()
                                    onChip()
                                } else {
                                    onBand()
                                }
                            }
                        )
                        .accessibilityLabel(Text("Go to the first message"))
                        .accessibilityAddTraits(.isButton)
                }
            )
    }
}

private struct ChatHeaderChipWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Centres a chat header chip in a full-width tap band - see `ChatHeaderTapBand`.
    func chatHeaderTapBand(onChip: @escaping () -> Void, onBand: @escaping () -> Void) -> some View {
        modifier(ChatHeaderTapBand(onChip: onChip, onBand: onBand))
    }
}

// MARK: - Fixed list header

/// A dock tab's title, and its list's search field, drawn above the list so neither scrolls away. The
/// system's large title collapsed into the navigation bar on a scroll, where the balance (the
/// toolbar's principal item) took its place, so it came back from another tab with no title. The
/// screen sets `.navigationBarTitleDisplayMode(.inline)` and keeps a principal item, so the bar
/// doesn't show the title a second time.
struct PinnedListHeader: View {
    let title: LocalizedStringKey
    /// Nil on a screen with nothing to search (Settings).
    var search: Binding<String>? = nil
    var prompt: LocalizedStringKey = ""
    var showsSearch = true
    /// Beside the title (Chats' Chats / Public Chats cycle button).
    var accessory: AnyView? = nil

    @FocusState private var searchFocused: Bool

    var body: some View {
        // no backup card here: it's on Profile only (owner's call, 2026-11-23)
        titleAndSearch
    }

    private var titleAndSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let accessory {
                    accessory
                    Spacer(minLength: 0)
                }
            }
            if showsSearch, let search {
                HStack(spacing: 10) {
                    searchField(search)
                    if searchFocused {
                        Button("Cancel") {
                            search.wrappedValue = ""
                            searchFocused = false
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchField(_ search: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(prompt, text: search)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.wrappedValue.isEmpty {
                Button {
                    search.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

// MARK: - Page cycle bar

/// The app's switch between pages inside a screen (an address's History / UTXOs / Domains, a Cold
/// Storage account, Stats): the cycle button (`CycleCapsuleButton`), leading, each tap fading to
/// the next page. It replaced the underline tabs (owner, 2026-11-24), as KaPost's feeds, Chess's
/// pages and the leaderboards have it.
struct PageCycleBar<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack {
            CycleCapsuleButton(
                options: tabs.map(\.tab),
                selection: $selection,
                title: { tab in tabs.first { $0.tab == tab }?.title ?? "" },
                hint: "Switches to the next page"
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

/// Renaming something, in a half sheet.
///
/// A system alert with a text field is the platform's default for this, and it is the wrong
/// shape: it steals the whole screen for one word, and its field is a cramped afterthought. This
/// is the same sheet every other cold-storage action already uses.
struct RenameSheet: View {
    let title: String
    var subtitle: String?
    var fieldLabel: String = "Name"
    @Binding var text: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            TextField(LocalizedStringKey(fieldLabel), text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .padding(14)
                .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Save", action: save)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(trimmed.isEmpty ? 0.4 : 1))
                    )
                    .disabled(trimmed.isEmpty)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fittedSheetDetents(260)
        .presentationDragIndicator(.visible)
        // A turn later: the field does not exist yet on the tap that presented this.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Cycle button

/// One see-through capsule with an accent border that steps through a few choices: each tap fades
/// to the next (and round again), and the dots say which one it is. KaPost's feeds (owner's call,
/// 2026-11-23) and the leaderboards' This Month / All Time (2026-11-24) use it in place of tabs or
/// a segmented picker.
struct CycleCapsuleButton<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    /// The localization key shown for a choice.
    let title: (Value) -> String
    let hint: LocalizedStringKey

    var body: some View {
        Button {
            Haptics.selection()
            guard !options.isEmpty else { return }
            let next = options[((options.firstIndex(of: selection) ?? 0) + 1) % options.count]
            withAnimation(.easeInOut(duration: 0.25)) { selection = next }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.bold))
                Text(LocalizedStringKey(title(selection)))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .id(selection)
                    .transition(.opacity)
                if options.count <= 6 {
                    HStack(spacing: 3) {
                        ForEach(options, id: \.self) { option in
                            Circle()
                                .fill(Color.accentColor.opacity(option == selection ? 1 : 0.3))
                                .frame(width: 5, height: 5)
                        }
                    }
                } else {
                    // too many for dots: where it is, as "3/14"
                    Text(verbatim: "\((options.firstIndex(of: selection) ?? 0) + 1)/\(options.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .opacity(0.7)
                        .fixedSize()
                }
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(title(selection))))
        .accessibilityHint(Text(hint))
    }
}

extension ChessLeaderboardPeriod {
    /// The cycle button's label ("This month" / "All time", the chess boards' existing keys).
    var cycleTitle: String {
        switch self {
        case .month: return "This month"
        case .allTime: return "All time"
        }
    }
}

/// A chat header chip's press: it dims and shrinks a little under the finger and taps lightly,
/// so a tap that landed is felt at once (the plain style showed nothing).
struct ChatHeaderChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
