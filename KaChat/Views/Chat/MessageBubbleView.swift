import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(YbridOpus)
import YbridOpus
#endif

private let kaspaBubbleColor = OutgoingBubble.color

struct MessageBubbleView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    let message: ChatMessage
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: ((ChatMessage) -> Void)?
    /// Retries the local user's failed reaction on this message (nil disables the reaction Retry).
    var onRetryReaction: ((MessageStore.ReactionSnapshot) -> Void)? = nil
    /// Opens the list of who reacted. Offered from the long-press menu only when there are
    /// reactions to show.
    var onShowReactions: (() -> Void)? = nil
    let onAcceptHandshake: (() -> Void)?
    let onDeclineHandshake: (() -> Void)?
    /// Parsed reply envelope, if `message.content` is a reply.
    let replyQuote: MessageReplyContent?
    let replySenderDisplayName: String?
    let onReply: (() -> Void)?
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action entirely (matches `onReply`'s nil-disables convention).
    let onSelect: (() -> Void)?
    /// This message's current reactions (one per reactor), for the pill shown on its corner.
    var reactions: [MessageStore.ReactionSnapshot] = []
    /// The local wallet's address, used to find *my* reaction among `reactions` so the pill can show
    /// my reaction's status (pending → nothing, sent → green check, failed → red error + Retry).
    var myReactorAddress: String = ""
    /// Sends/toggles a reaction on this message - nil disables the double-tap quick-reaction bar
    /// entirely (matches how `onReply` being nil already disables reply everywhere it's checked).
    let onReact: ((String) -> Void)?
    /// Asks the SCREEN to open the full emoji picker for this message - see
    /// `QuickReactionBarView.onMore` for why the bar cannot present it itself.
    var onMoreReactions: (() -> Void)? = nil
    /// The text shown is an edit of what was sent (the parent already swapped `content`); a
    /// small "edited" sits under the bubble. `onEdit` opens the composer on this message's
    /// text - offered on the local user's own text bubbles only (nil elsewhere).
    var isEdited: Bool = false
    var onEdit: (() -> Void)? = nil
    /// Shared across every bubble in the conversation (not per-bubble `@State`) so the list's own
    /// tap-anywhere-to-dismiss gesture can close whichever bubble's bar is open from outside this
    /// view entirely - see `ChatDetailView`'s `activeQuickReactionMessageId`.
    @Binding var activeQuickReactionMessageId: UUID?
    private var showQuickReactionBar: Bool {
        activeQuickReactionMessageId == message.id
    }
    /// Tapping the reply quote (if any) jumps to and highlights the original message - nil
    /// when `replyQuote` is nil, since there's nothing to jump to.
    let onJumpToReply: (() -> Void)?
    /// Sender's KNS avatar (or nil for plain initials).
    let avatarURLString: String?
    let avatarDisplayName: String
    /// Parsed chess envelope, if `message.content` is one - mirrors `replyQuote`. `chessSummary`
    /// is the current game state (nil only if `chessEnvelope` is nil), always reflecting the
    /// *latest* message for that game, not necessarily this one - see `isLatestChessMessage`.
    let chessEnvelope: ChessEnvelope?
    let chessSummary: ChessGameSummary?
    /// True only for the most recent chess message belonging to its game - that one renders as
    /// the live status card; earlier moves in the same game render as a compact log line instead.
    var isLatestChessMessage: Bool = false
    /// Non-nil only for an incoming, not-yet-responded-to invite.
    let onRespondToChessInvite: ((Bool) -> Void)?
    let onOpenChessGame: (() -> Void)?
    /// Tapping a payment card opens its details (View in Explorer, Copy Transaction ID). nil where
    /// the host has no such sheet - the card then only takes the double-tap to react.
    let onOpenPayment: (() -> Void)?
    /// When true, an incoming photo from this contact stays hidden - see
    /// `ContactsManager.photosUnlockDate`.
    var photosBlocked: Bool = false
    /// When false, incoming link previews from this contact render as a "Tap to load preview"
    /// placeholder instead of auto-fetching - driven by `ContactsManager.isAcceptedContact(_:)`
    /// (the same accepted/established predicate the stranger photo gating builds on). The local
    /// user's own outgoing links always auto-load.
    var linkPreviewsAutoLoad: Bool = true
    /// Set on the row that stands for a whole long voice note (its earliest part): the bubble
    /// plays every part present as one recording. `message` then carries the note's combined
    /// delivery status.
    var voiceParts: VoiceNotePartsInput? = nil
    /// Set on the row that stands for a whole multi-part photo (its earliest part).
    var photoParts: PhotoPartsInput? = nil
    @State private var showFullText = false
    /// Long-pressing a link surfaces this instead of the bubble's message sheet:
    /// `LinkifiedMessageTextView`'s own long-press recognizer fires first on a link and marks
    /// the moment (`LinkLongPress`), and the bubble's `messageActions` stands down for it.
    @State private var linkMenuURL: URL?

    init(
        message: ChatMessage,
        onCopy: ((String, ToastStyle) -> Void)? = nil,
        onRetry: ((ChatMessage) -> Void)? = nil,
        onRetryReaction: ((MessageStore.ReactionSnapshot) -> Void)? = nil,
        onAcceptHandshake: (() -> Void)? = nil,
        onDeclineHandshake: (() -> Void)? = nil,
        replyQuote: MessageReplyContent? = nil,
        replySenderDisplayName: String? = nil,
        onReply: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil,
        reactions: [MessageStore.ReactionSnapshot] = [],
        myReactorAddress: String = "",
        onShowReactions: (() -> Void)? = nil,
        onReact: ((String) -> Void)? = nil,
        onMoreReactions: (() -> Void)? = nil,
        isEdited: Bool = false,
        onEdit: (() -> Void)? = nil,
        activeQuickReactionMessageId: Binding<UUID?> = .constant(nil),
        onJumpToReply: (() -> Void)? = nil,
        avatarURLString: String? = nil,
        avatarDisplayName: String = "",
        photosBlocked: Bool = false,
        linkPreviewsAutoLoad: Bool = true,
        chessEnvelope: ChessEnvelope? = nil,
        chessSummary: ChessGameSummary? = nil,
        isLatestChessMessage: Bool = false,
        onRespondToChessInvite: ((Bool) -> Void)? = nil,
        onOpenChessGame: (() -> Void)? = nil,
        onOpenPayment: (() -> Void)? = nil,
        voiceParts: VoiceNotePartsInput? = nil,
        photoParts: PhotoPartsInput? = nil
    ) {
        self.voiceParts = voiceParts
        self.photoParts = photoParts
        self.message = message
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onRetryReaction = onRetryReaction
        self.onAcceptHandshake = onAcceptHandshake
        self.onDeclineHandshake = onDeclineHandshake
        self.replyQuote = replyQuote
        self.replySenderDisplayName = replySenderDisplayName
        self.onReply = onReply
        self.onSelect = onSelect
        self.reactions = reactions
        self.myReactorAddress = myReactorAddress
        self.onShowReactions = onShowReactions
        self.onReact = onReact
        self.onMoreReactions = onMoreReactions
        self.isEdited = isEdited
        self.onEdit = onEdit
        self._activeQuickReactionMessageId = activeQuickReactionMessageId
        self.onJumpToReply = onJumpToReply
        self.avatarURLString = avatarURLString
        self.avatarDisplayName = avatarDisplayName
        self.photosBlocked = photosBlocked
        self.linkPreviewsAutoLoad = linkPreviewsAutoLoad
        self.chessEnvelope = chessEnvelope
        self.chessSummary = chessSummary
        self.isLatestChessMessage = isLatestChessMessage
        self.onRespondToChessInvite = onRespondToChessInvite
        self.onOpenChessGame = onOpenChessGame
        self.onOpenPayment = onOpenPayment
    }

    /// The reply's own text, or the raw content when this isn't a reply.
    private var displayText: String {
        replyQuote?.text ?? message.readableContent
    }

    /// A link into KaChat itself (a shared profile or payment request) inside this
    /// message, if any. Cached inside `KaChatInternalLink.match`, like the http-link helpers it
    /// sits next to, since this is evaluated from `body` on every visible row.
    private var internalLink: KaChatInternalLink.Match? {
        KaChatInternalLink.match(in: displayText)
    }


    var body: some View {
        messageContent(media: mediaFile, isSingleEmojiOnly: isSingleEmojiOnlyMessage(displayText))
    }

    private var avatarView: some View {
        // contactAddress: the sender's .kachat avatar (yours on your own messages), with their
        // Contacts-app photo as the fallback.
        KNSAvatarView(
            avatarURLString: avatarURLString,
            fallbackText: avatarDisplayName,
            size: 32,
            contactAddress: message.senderAddress
        )
    }

    @ViewBuilder
    private func messageContent(media: MediaFile?, isSingleEmojiOnly: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !message.isOutgoing {
                avatarView
            } else {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Sits directly above the bubble in normal layout flow (like `replyQuoteView`
                // below) rather than as an `.overlay` with a manual offset - an offset popup that
                // sticks out above its row gets cropped by the ScrollView's own clipping, which is
                // exactly what made the emoji row render as sliced-off fragments before.
                if showQuickReactionBar, let onReact {
                    QuickReactionBarView(
                        emojis: settingsViewModel.settings.effectiveQuickReactionEmojis,
                        onReact: { emoji in
                            onReact(emoji)
                            activeQuickReactionMessageId = nil
                        },
                        onReply: {
                            onReply?()
                            activeQuickReactionMessageId = nil
                        },
                        onMore: {
                            // Close the bar and hand off in one go: the screen owns the picker,
                            // so it survives this bar going away.
                            activeQuickReactionMessageId = nil
                            onMoreReactions?()
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
                }

                // Message type indicator for special messages
                if shouldShowMessageTypeIndicator {
                    messageTypeIndicator
                }

                // Incoming handshake request with Accept/Decline actions
                if message.messageType == .handshake && !message.isOutgoing && onAcceptHandshake != nil {
                    handshakeRequestBubble
                } else if let chessEnvelope {
                    chessBubble(chessEnvelope)
                } else {
                    if let replyQuote {
                        replyQuoteView(replyQuote)
                    }

                    // Grouped separately from `replyQuote` above so the reaction pill's overlay
                    // (attached to just this Group) anchors to the actual bubble's own corner -
                    // attaching it to the whole VStack instead would size/position it against
                    // whichever sibling is widest, which for a reply is usually the quote banner,
                    // not the (often much narrower) bubble underneath it.
                    Group {
                        if let photoParts {
                            // A multi-part photo: the joined image once every part is here,
                            // else a placeholder counting them in.
                            if let joined = photoParts.joinedMedia {
                                LazyImageBubble(
                                    media: joined,
                                    txId: message.txId,
                                    shouldShowRetry: shouldShowRetry,
                                    photosBlocked: photosBlocked && !message.isOutgoing,
                                    senderDisplayName: avatarDisplayName,
                                    onCopy: onCopy,
                                    onRetry: { onRetry?(message) },
                                    onReply: onReply,
                                    onDoubleTap: onReact != nil ? { activeQuickReactionMessageId = message.id } : nil,
                                    onSelect: onSelect,
                                    imageCacheKey: photoParts.imageCacheKey
                                )
                            } else {
                                PhotoPartsPlaceholderBubble(
                                    input: photoParts,
                                    isOutgoing: message.isOutgoing,
                                    onRetry: shouldShowRetry ? { onRetry?(message) } : nil,
                                    onReply: onReply,
                                    onSelect: onSelect
                                )
                                .simultaneousGesture(TapGesture(count: 2).onEnded { activeQuickReactionMessageId = message.id })
                            }
                        } else if let media, media.isImage {
                            // Double-tap opens the quick-reaction bar (co-located inside
                            // LazyImageBubble with its single-tap-to-preview gesture so SwiftUI can
                            // disambiguate the two correctly) rather than here, unlike the audio/text
                            // cases below.
                            LazyImageBubble(
                                media: media,
                                txId: message.txId,
                                shouldShowRetry: shouldShowRetry,
                                photosBlocked: photosBlocked && !message.isOutgoing,
                                senderDisplayName: avatarDisplayName,
                                onCopy: onCopy,
                                onRetry: { onRetry?(message) },
                                onReply: onReply,
                                onDoubleTap: onReact != nil ? { activeQuickReactionMessageId = message.id } : nil,
                                onSelect: onSelect
                            )
                        } else if let voiceParts, !voiceParts.parts.isEmpty {
                            LazyMultipartAudioBubble(
                                input: voiceParts,
                                isOutgoing: message.isOutgoing,
                                txId: message.txId,
                                onRetry: shouldShowRetry ? { onRetry?(message) } : nil,
                                onReply: onReply,
                                onSelect: onSelect
                            )
                            .simultaneousGesture(TapGesture(count: 2).onEnded { activeQuickReactionMessageId = message.id })
                        } else if let media, media.isAudio, let data = media.fileData(cacheKey: message.txId) {
                            LazyAudioBubble(
                                data: data,
                                mimeType: media.mimeType,
                                isOutgoing: message.isOutgoing,
                                fileName: media.name,
                                txId: message.txId,
                                onCopy: onCopy,
                                onRetry: shouldShowRetry ? { onRetry?(message) } : nil,
                                onReply: onReply,
                                onSelect: onSelect
                            )
                            .simultaneousGesture(TapGesture(count: 2).onEnded { activeQuickReactionMessageId = message.id })
                        } else if let internalLink {
                            // A link back into KaChat (a shared profile or payment request) is
                            // claimed here BEFORE the generic link branch below - the
                            // universal-link form is a perfectly ordinary https URL, so without
                            // this it would be scraped over the network like a stranger's link.
                            //
                            // The card is the WHOLE message, even when the link arrived with
                            // text around it. The full text is still what Copy, reply and
                            // forward carry.
                            KaChatInternalLinkCardView(
                                match: internalLink,
                                txId: message.txId,
                                onSelect: onSelect,
                                onDoubleTap: onReact != nil ? { activeQuickReactionMessageId = message.id } : nil
                            )
                        } else if internalLink == nil, let linkURL = MessageTextRenderPlan.firstHTTPLink(in: displayText), MessageTextRenderPlan.isEntirelyLink(displayText) {
                            // Message is nothing but a link - the preview card replaces the plain-text
                            // bubble entirely (matches iMessage) instead of showing both. `fallbackText`
                            // keeps the raw link visible/tappable if no preview data is ever found,
                            // rather than the message rendering as nothing at all.
                            LinkPreviewCardView(url: linkURL, txId: message.txId, fallbackText: displayText, onSelect: onSelect, onDoubleTap: onReact != nil ? { activeQuickReactionMessageId = message.id } : nil, isOutgoing: message.isOutgoing, autoFetch: linkPreviewsAutoLoad || message.isOutgoing, photosBlocked: photosBlocked && !message.isOutgoing, blockedSenderName: avatarDisplayName)
                        } else if message.messageType == .payment, let paymentParts = paymentCardParts {
                            // Rich Apple-Pay-in-iMessage style card replacing the plain
                            // "Sent/Received X KAS" text bubble. Unparseable/legacy payment
                            // content falls through to the classic text bubble below (which
                            // then also keeps its "Payment" capsule - see
                            // shouldShowMessageTypeIndicator).
                            paymentCardBubble(paymentParts)
                                .modifier(PaymentCardTaps(
                                    onOpen: onOpenPayment,
                                    onDoubleTap: { activeQuickReactionMessageId = message.id }
                                ))
                        } else {
                            messageTextBubble(isSingleEmojiOnly: isSingleEmojiOnly)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { activeQuickReactionMessageId = message.id })
                        }
                    }
                    .overlay(alignment: message.isOutgoing ? .bottomLeading : .bottomTrailing) {
                        if !reactions.isEmpty {
                            ReactionPillView(emojis: reactions.map { $0.emoji }, localReactionStatus: pillReactionStatus)
                                .offset(y: 10)
                        }
                    }
                    // The reaction pill is an overlay (no layout footprint) offset ~10pt below the
                    // bubble, so reserve that space when reactions exist - otherwise the pill overlaps
                    // the next message below it.
                    .padding(.bottom, reactions.isEmpty ? 0 : 16)

                    // Only the plain-text-bubble case (no media, and not itself entirely a link,
                    // both handled inside the Group above) gets this extra preview card below it.
                    // An internal KaChat link wins over an external one in the same message, so
                    // a profile mentioned alongside other text still previews natively.
                    if media == nil,
                       internalLink == nil,
                       !MessageTextRenderPlan.isEntirelyLink(displayText),
                       let linkURL = MessageTextRenderPlan.firstHTTPLink(in: displayText) {
                        LinkPreviewCardView(url: linkURL, txId: message.txId, onSelect: onSelect, onDoubleTap: onReact != nil ? { activeQuickReactionMessageId = message.id } : nil, isOutgoing: message.isOutgoing, autoFetch: linkPreviewsAutoLoad || message.isOutgoing, photosBlocked: photosBlocked && !message.isOutgoing, blockedSenderName: avatarDisplayName)
                    }
                }

                // The time under every message, and for your own the delivery status after it:
                // "Sending" / "Sent" / "Failed · Tap to retry" - the failed label is itself the
                // retry button (DeliveryStatusLabel), so no second "Retry" beside it.
                MessageTimeLine(date: message.timestamp) {
                    if shouldShowStatusIcon {
                        statusIcon
                    }
                }

                if isEdited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // A reaction (not the message) that failed to send: red "Retry" under the message,
                // paired with the red error icon shown on the reaction pill itself.
                if let localReaction, localReaction.deliveryStatus == .failed {
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.red)
                        .contentShape(Rectangle())
                        .onTapGesture { onRetryReaction?(localReaction) }
                }
            }

            if message.isOutgoing {
                avatarView
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    private var shouldShowResolvingOverlay: Bool {
        message.messageType == .payment && message.deliveryStatus == .pending
    }

    private var shouldShowMessageTypeIndicator: Bool {
        // Payments render as the rich payment card, which carries its own identity - the
        // orange "Payment" capsule only remains for odd/legacy content the card can't parse.
        if message.messageType == .payment { return paymentCardParts == nil }
        return message.messageType != .contextual || isKNSTransferMessage
    }

    private var isKNSTransferMessage: Bool {
        guard message.messageType == .contextual else { return false }
        // A KNS transfer status message is always a short fixed phrase ("Sent alice.kas
        // domain") - bail out on UTF-8 byte length before the `trimmingCharacters`/`lowercased`
        // normalization below, which otherwise runs unguarded on every bubble's `body`
        // evaluation, including photo messages whose `content` is their multi-KB-to-multi-MB
        // base64 JSON payload (photos are also sent as `.contextual`, so they hit this path too).
        guard message.content.utf8.count <= 256 else { return false }
        let normalized = message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if matchesSinglePlaceholderFormat(
            normalizedContent: normalized,
            localizedTemplate: AppLocalization.string("Sent %@ domain")
        ) {
            return true
        }
        if matchesSinglePlaceholderFormat(
            normalizedContent: normalized,
            localizedTemplate: AppLocalization.string("Received %@ domain")
        ) {
            return true
        }

        let localizedOutgoingFallback = AppLocalization.string("Sent domain transfer")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let localizedIncomingFallback = AppLocalization.string("Received domain transfer")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == localizedOutgoingFallback || normalized == localizedIncomingFallback {
            return true
        }

        // Backward compatibility for already-stored English messages.
        if normalized.hasPrefix("sent ") && normalized.contains(".kas domain") {
            return true
        }
        if normalized.hasPrefix("received ") && normalized.contains(".kas domain") {
            return true
        }
        if normalized == "sent domain transfer" || normalized == "received domain transfer" {
            return true
        }
        return false
    }

    private func matchesSinglePlaceholderFormat(
        normalizedContent: String,
        localizedTemplate: String
    ) -> Bool {
        let normalizedTemplate = localizedTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let placeholderRange = normalizedTemplate.range(of: "%@") else {
            return false
        }

        let prefix = String(normalizedTemplate[..<placeholderRange.lowerBound])
        let suffix = String(normalizedTemplate[placeholderRange.upperBound...])
        guard normalizedContent.hasPrefix(prefix),
              normalizedContent.hasSuffix(suffix) else {
            return false
        }

        let domainStart = normalizedContent.index(normalizedContent.startIndex, offsetBy: prefix.count)
        let domainEnd = normalizedContent.index(normalizedContent.endIndex, offsetBy: -suffix.count)
        guard domainStart <= domainEnd else { return false }
        let domainPart = normalizedContent[domainStart..<domainEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return !domainPart.isEmpty
    }

    private var shouldShowRetry: Bool {
        guard message.isOutgoing, message.deliveryStatus == .failed else { return false }
        if let chessEnvelope, !chessRetryStillFits(chessEnvelope) { return false }
        switch message.messageType {
        case .contextual, .audio, .handshake:
            return true
        case .payment:
            return false
        }
    }

    /// A failed chess action is left off the board (see `ChessGameService.summarize`), so the
    /// game carries on without it - and retrying it later would replay it into a game that has
    /// moved on: a failed move retried after you played a different one lands on your board and
    /// the opponent's in different orders, splitting the two boards. Retry is offered only
    /// while the action still fits: a move while it is still your turn, an accept while the
    /// game still waits for one, a resignation or invite while the game is not over.
    private func chessRetryStillFits(_ envelope: ChessEnvelope) -> Bool {
        guard let summary = chessSummary else { return true }
        switch envelope {
        case .move:
            return summary.status == .inProgress && summary.board.sideToMove == summary.viewerColor
        case .response:
            return summary.status == .pendingResponse
        case .resign, .invite:
            return !summary.status.isGameOver
        }
    }

    private var shouldShowStatusIcon: Bool {
        message.isOutgoing || message.deliveryStatus == .warning
    }

    /// The local user's own reaction on this message, if any - drives the pill's status icon
    /// (pending → none, sent → green check, failed → red error) and the Retry affordance.
    private var localReaction: MessageStore.ReactionSnapshot? {
        reactions.first { $0.reactorAddress == myReactorAddress }
    }

    /// Status to show on the reaction pill. Same as `localReaction`'s status, except the green
    /// "sent" checkmark is dropped once the reaction is older than 10 minutes - it's a recent
    /// confirmation, not a permanent badge (pending/failed are always shown).
    private var pillReactionStatus: ChatMessage.DeliveryStatus? {
        guard let localReaction else { return nil }
        guard localReaction.deliveryStatus == .sent else { return localReaction.deliveryStatus }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - localReaction.blockTime
        return ageMs < 600_000 ? .sent : nil
    }

    private func messageTextBubble(isSingleEmojiOnly: Bool) -> some View {
        messageTextContent(isSingleEmojiOnly: isSingleEmojiOnly)
            .padding(.horizontal, isSingleEmojiOnly ? 0 : 12)
            .padding(.vertical, isSingleEmojiOnly ? 0 : 8)
            .background(isSingleEmojiOnly ? Color.clear : (message.isOutgoing ? kaspaBubbleColor : Color(.systemGray5)))
            .clipShape(RoundedRectangle(cornerRadius: isSingleEmojiOnly ? 0 : 16))
            .overlay {
                if !isSingleEmojiOnly && shouldShowResolvingOverlay {
                    ShimmerOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                }
            }
            .messageActions(title: "Message", preview: displayText) {
                var actions: [MessageAction] = [
                    .copyMessage { handleCopy(displayText, toast: "Message copied to clipboard.") }
                ]
                if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: message.txId) {
                    actions.append(.explorer(url))
                }
                // The pill on the bubble shows WHICH emoji are on it; it has no room to say how
                // many or from whom. This does.
                if !reactions.isEmpty, let onShowReactions {
                    actions.append(.reactions(count: reactions.count, onShowReactions))
                }
                if let onEdit { actions.append(.edit(onEdit)) }
                if let onReply { actions.append(.reply(onReply)) }
                if shouldShowRetry { actions.append(.retry { onRetry?(message) }) }
                if let onSelect { actions.append(.select(onSelect)) }
                return actions
            }
            .tint(.accentColor)
            // A half sheet rather than a confirmation dialog: the dialog could only show a verb
            // per button and squeezed the URL into small print above them, and deciding whether
            // to open a link IS reading it.
            .sheet(item: Binding(get: { linkMenuURL.map(IdentifiedURL.init) }, set: { if $0 == nil { linkMenuURL = nil } })) { wrapper in
                LinkActionsSheet(
                    url: wrapper.url,
                    onOpen: {
                        // Internal KaChat links open the target screen in-app - see the same
                        // branch in `LinkifiedMessageTextView.Coordinator.handleTap`.
                        if let internalLink = KaChatInternalLink.parse(wrapper.url) {
                            KaChatLinkRouter.open(internalLink, fromChat: true)
                        } else {
                            KaChatLinkRouter.openAnywhere(wrapper.url, fromChat: true)
                        }
                    },
                    onCopy: { handleCopy(wrapper.url.absoluteString, toast: "Link copied to clipboard.") },
                    onReply: onReply
                )
            }
    }

    private func replyQuoteView(_ reply: MessageReplyContent) -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            Text(replySenderDisplayName ?? Contact.generateDefaultAlias(from: reply.replyToSender))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Text(reply.replyToPreview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(message.isOutgoing ? .trailing : .leading)
        }
        .padding(8)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 240, alignment: message.isOutgoing ? .trailing : .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onJumpToReply?()
        }
    }

    /// Above this, a message renders as a truncated, tap-to-expand preview instead of laying out
    /// the full text inline - matches iMessage's behavior for very long messages, and specifically
    /// guards against a huge wall of text (e.g. raw base64 that ended up as plain message content
    /// instead of being recognized as a file/image envelope) making the whole chat scroll janky,
    /// since SwiftUI's `Text`/`fixedSize` layout cost for a single giant string is what actually
    /// causes the lag, not the message itself being "long" in a normal-prose sense.
    private static let inlineTextTruncationThreshold = 2_000
    private static let truncatedPreviewLength = 500

    @ViewBuilder
    private func messageTextContent(isSingleEmojiOnly: Bool) -> some View {
        // Cheap proxy for "is this too long" - String.utf8.count is O(1) for native Swift
        // strings, unlike .count (grapheme-cluster counting), which is a full O(n) scan and
        // would itself cost real time on a huge string.
        if displayText.utf8.count > Self.inlineTextTruncationThreshold {
            truncatedMessageContent
        } else if MessageTextRenderPlan.prefersUIKitTextView(displayText) {
            LinkifiedMessageTextView(
                text: displayText,
                isOutgoing: message.isOutgoing,
                isSingleEmojiOnly: isSingleEmojiOnly,
                onLinkLongPress: { url in
                    linkMenuURL = url
                },
                onLinkDoubleTap: onReact != nil ? { activeQuickReactionMessageId = message.id } : {}
            )
        } else {
            Text(displayText)
                .font(isSingleEmojiOnly ? .system(size: UIFont.preferredFont(forTextStyle: .body).pointSize * 5.0) : .body)
                .foregroundStyle(isSingleEmojiOnly ? Color.primary : (message.isOutgoing ? Color.white : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var truncatedMessageContent: some View {
        Button {
            // See LazyImageBubble.setShowImagePreview's doc comment - same risk (a modal-
            // presenting boolean flipped from inside a scrollable, gesture-heavy message row),
            // same defensive fix.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showFullText = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(displayText.prefix(Self.truncatedPreviewLength)) + "…")
                    .font(.body)
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Show More")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.85) : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFullText) {
            FullMessageTextView(text: displayText) {
                handleCopy(displayText, toast: "Message copied to clipboard.")
            }
        }
    }

    private var statusIcon: some View {
        let status = DeliveryStatusLabel.Status(message.deliveryStatus, isOutgoing: message.isOutgoing)
        let retry: (() -> Void)? = (message.isOutgoing && message.deliveryStatus == .failed)
            ? onRetry.map { handler in { handler(message) } }
            : nil
        return DeliveryStatusLabel(status: status, retry: retry)
    }

    private var handshakeRequestBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.wave.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Contact has requested permission to communicate")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            HStack(spacing: 12) {
                Button {
                    onAcceptHandshake?()
                } label: {
                    Text("Accept")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(kaspaBubbleColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    onDeclineHandshake?()
                } label: {
                    Text("Decline")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .foregroundColor(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 300)
    }

    @ViewBuilder
    private func chessBubble(_ envelope: ChessEnvelope) -> some View {
        switch envelope {
        case .invite(let content):
            chessInviteBubble(content)
        case .response, .move, .resign:
            if isLatestChessMessage, let chessSummary {
                chessLiveCard(chessSummary)
            } else {
                chessLogEntry(envelope)
            }
        }
    }

    private func chessInviteBubble(_ content: ChessInviteContent) -> some View {
        let showsResponseButtons = !message.isOutgoing
            && onRespondToChessInvite != nil
            && chessSummary?.status == .pendingResponse
        // "3 | 2"-style chip when the invite carries a time control; nil (no chip) for casual
        // games and every invite from a legacy client.
        let timeControlLabel: String? = ChessTimeControl.fromInvite(content)?.label
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("♟️")
                    .font(.title3)
                Text(message.isOutgoing ? "Chess game invite sent" : "Invited you to a game of chess")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            if let timeControlLabel {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(timeControlLabel)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }

            if showsResponseButtons {
                HStack(spacing: 12) {
                    Button {
                        onRespondToChessInvite?(true)
                    } label: {
                        Text("Accept")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(kaspaBubbleColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onRespondToChessInvite?(false)
                    } label: {
                        Text("Decline")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray5))
                            .foregroundColor(.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            } else if let chessSummary {
                Text(chessSummary.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 300)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !showsResponseButtons else { return }
            onOpenChessGame?()
        }
        .chessExplorerMenu(txId: message.txId, settingsViewModel: settingsViewModel, onRetry: shouldShowRetry ? { onRetry?(message) } : nil)
    }

    private func chessLiveCard(_ summary: ChessGameSummary) -> some View {
        // The status row is pinned to the board's width: its Spacer must push the timer chip
        // to the board's right edge, not stretch the whole card to the bubble's max width
        // (which left a wide dark void beside the board).
        let boardSize: CGFloat = 160
        return VStack(alignment: .leading, spacing: 8) {
            ChessBoardThumbnail(board: summary.board, size: boardSize)
            HStack(spacing: 6) {
                Text(summary.statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(summary.status.isGameOver ? .secondary : .primary)
                if let timeControl = summary.timeControl {
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                        Text(timeControl.label)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                }
            }
            .frame(width: boardSize)
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenChessGame?()
        }
        .chessExplorerMenu(txId: message.txId, settingsViewModel: settingsViewModel, onRetry: shouldShowRetry ? { onRetry?(message) } : nil)
    }

    private func chessLogEntry(_ envelope: ChessEnvelope) -> some View {
        // A plain Unicode glyph character embedded in text renders in the ambient text color
        // (see the see-through-white-pieces fix on ChessPiece.glyph), so it can't convey white
        // vs black on its own - a move's piece is rendered via a real `ChessPieceGlyphView`
        // (fill/outline colored by `piece.color`) placed next to the text instead.
        let record = chessMoveRecord(for: envelope)
        return HStack(spacing: 4) {
            if let record {
                ChessPieceGlyphView(piece: ChessPiece(type: record.pieceType, color: record.color), fontSize: 14)
            }
            Text(chessLogText(envelope))
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenChessGame?()
        }
        .chessExplorerMenu(txId: message.txId, settingsViewModel: settingsViewModel, onRetry: shouldShowRetry ? { onRetry?(message) } : nil)
    }

    private func chessMoveRecord(for envelope: ChessEnvelope) -> ChessMoveRecord? {
        guard case .move = envelope else { return nil }
        return chessSummary?.moveHistory.first { $0.messageTxId == message.txId }
    }

    private func chessLogText(_ envelope: ChessEnvelope) -> String {
        switch envelope {
        case .move(let content):
            let promotionSuffix = content.promotion.map { " (\($0.uppercased()))" } ?? ""
            return "\(content.from) → \(content.to)\(promotionSuffix)"
        // Shown as a String, so translated here (audit 2026-11-24 #40).
        case .resign(let content):
            return AppLocalization.string(content.reason == "timeout" ? "Lost on time" : "Resigned")
        case .response(let content):
            return AppLocalization.string(content.accepted ? "Accepted the game" : "Declined the game")
        case .invite:
            return AppLocalization.string("Chess invite")
        }
    }

    // MARK: - Payment card

    /// Amount + optional note pulled out of a payment message's display text ("Sent 0.2 KAS",
    /// "Received 0.2 KAS — thanks!" and their localized equivalents). Both regular detected
    /// payments and pool payment_notice bubbles produce this exact shape (ChatService formats
    /// them from the same "Sent/Received %@ KAS" templates), so one parser covers both paths.
    struct PaymentCardParts {
        let amountText: String
        let note: String?
        /// A token payment ("Sent 12.50 kUSDT", Send Dollars): its icon and symbol stand in for
        /// Kaspa's. Nil for a Kaspa payment.
        var token: WalletToken? = nil

        /// "12.50 kUSDT" or "2.5 KAS".
        var amountWithUnit: String { "\(amountText) \(token?.symbol ?? KaspaUnit.symbol)" }
    }

    /// nil when the content doesn't look like a standard payment phrase (foreign/legacy data) -
    /// the bubble then falls back to the classic text rendering with its "Payment" capsule.
    private var paymentCardParts: PaymentCardParts? {
        Self.paymentCardParts(for: message)
    }

    /// The same parse for a host showing a payment's details (see `ChatDetailView`).
    static func paymentCardParts(for message: ChatMessage) -> PaymentCardParts? {
        guard message.messageType == .payment else { return nil }
        guard message.content.utf8.count <= 512 else { return nil }
        // Note separator matches the "Sent %@ KAS — %@" template family.
        let pieces = message.content.components(separatedBy: " — ")
        let head = pieces[0]
        let noteRaw = pieces.count > 1 ? pieces.dropFirst().joined(separator: " — ") : nil
        guard let amountToken = head
            .components(separatedBy: .whitespaces)
            .first(where: { Double($0.replacingOccurrences(of: ",", with: ".")) != nil }) else {
            return nil
        }
        let note = noteRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = head.components(separatedBy: .whitespaces)
        let token = WalletToken.all.first { words.contains($0.symbol) }
        return PaymentCardParts(amountText: amountToken, note: (note?.isEmpty == false) ? note : nil, token: token)
    }

    /// Apple-Pay-in-iMessage style payment card: KaspaLogo leading, the amount large and bold,
    /// a smaller Sent/Received line, optional note. Direction is carried by the fill - outgoing
    /// uses a richer teal gradient (anchored on the app's own-bubble kaspaBubbleColor), incoming
    /// stays neutral glass with teal accents. Same pending shimmer, context menu items, and
    /// double-tap-to-react behavior as the text bubble it replaces; reaction pill/status/time
    /// layout are untouched since the card sits in the exact same slot of messageContent.
    private func paymentCardBubble(_ parts: PaymentCardParts) -> some View {
        let outgoing = message.isOutgoing
        return HStack(spacing: 12) {
            Group {
                if let token = parts.token {
                    TokenIcon(token: token, size: 46)
                } else {
                    Image("KaspaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .padding(6)
                        .background(
                            // Outgoing rides a teal gradient — a translucent white circle left the teal
                            // logo nearly invisible (teal on teal). Solid white gives the brand mark its
                            // natural contrast; incoming keeps the subtle accent tint on neutral glass.
                            Circle().fill(outgoing ? Color.white : Color.accentColor.opacity(0.12))
                        )
                }
            }
            .shadow(color: outgoing ? Color.black.opacity(0.12) : .clear, radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                PaymentCardHeading(txId: message.txId, outgoing: outgoing, canBeTip: parts.token == nil)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(outgoing ? Color.white.opacity(0.85) : .secondary)
                Text(verbatim: parts.amountWithUnit)
                    .font(.title3.weight(.bold))
                    .foregroundColor(outgoing ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let note = parts.note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(outgoing ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 170, alignment: .leading)
        .background {
            if outgoing {
                LinearGradient(
                    colors: [kaspaBubbleColor, kaspaBubbleColor.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(outgoing ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
        .overlay {
            if shouldShowResolvingOverlay {
                ShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .messageActions(title: "Payment", preview: displayText) {
            var actions: [MessageAction] = [
                .copyMessage { handleCopy(displayText, toast: "Message copied to clipboard.") }
            ]
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: message.txId) {
                actions.append(.explorer(url))
            }
            if let onReply { actions.append(.reply(onReply)) }
            if let onSelect { actions.append(.select(onSelect)) }
            return actions
        }
        .tint(.accentColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(displayText))
    }

    @ViewBuilder
    private var messageTypeIndicator: some View {
        switch message.messageType {
        case .handshake:
            // An acceptance and a fresh request are both handshakes on the wire; only the capsule
            // tells them apart, and calling an acceptance a "request" read as the exchange not
            // having completed at all.
            let isAcceptance = displayText.contains("[Request accepted]")
            HStack(spacing: 4) {
                Image(systemName: isAcceptance ? "checkmark.seal.fill" : "hand.wave.fill")
                    .font(.caption2)
                Text(isAcceptance ? "Handshake completed" : "Request to communicate")
                    .font(.caption2)
            }
            .foregroundColor(isAcceptance ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(.systemGray6))
            .clipShape(Capsule())

        case .payment:
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.caption2)
                Text("Payment")
                    .font(.caption2)
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())

        case .contextual:
            if isKNSTransferMessage {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption2)
                    Text("Domain")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            } else {
                EmptyView()
            }

        case .audio:
            // `sendImage` deliberately reuses `.audio` as the message type (the JSON envelope's
            // own `mimeType` is what actually distinguishes a photo from a voice message), so this
            // badge needs to check `mediaFile` itself rather than assuming every `.audio` message
            // is a voice message.
            if mediaFile?.isImage == true {
                HStack(spacing: 4) {
                    Image(systemName: "photo.circle.fill")
                        .font(.caption2)
                    Text("Photo")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.caption2)
                    Text("Audio")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            }
        }
    }

    private func handleCopy(_ value: String, toast: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        onCopy?(AppLocalization.string(toast), .success)
    }

    private var mediaFile: MediaFile? {
        MediaFile.from(displayText, cacheKey: message.txId)
    }

    private func isSingleEmojiOnlyMessage(_ text: String) -> Bool {
        // `.count` is a full Unicode grapheme-cluster scan (O(n)) - fine for a real single-emoji
        // message, but this runs unguarded on every bubble's `body` evaluation for every message,
        // including photo/audio ones whose `displayText` (see call site) is their multi-KB-to
        // -multi-MB base64 JSON payload. Bailing out on UTF-8 byte length first (O(1) on native
        // Swift storage, unlike `.count`) avoids paying that scan for anything that obviously
        // isn't a single character already - matches the same fix already applied to
        // `ConversationRow.formatPreview` and `MessageReplyCodec.parse` for this exact pattern.
        guard text.utf8.count <= 32 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else {
            return false
        }
        return trimmed.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }
}

/// The preview card for a link that points back INSIDE KaChat (`KaChatInternalLink`): a shared
/// profile or a payment request. Deliberately NOT a `LinkPreviewCardView`: that card
/// scrapes the URL's server for Open Graph metadata, which for our own links would mean a
/// pointless network round trip (and, for a stranger's message, a tap-to-load placeholder) to
/// learn something the app already knows. Everything here is built locally, and a tap routes
/// in-app through `KaChatLinkRouter` instead of handing the URL to Safari.
///
/// Used by 1:1 bubbles (`MessageBubbleView`).
struct KaChatInternalLinkCardView: View {
    let match: KaChatInternalLink.Match
    /// The owning message's transaction id, for the shared "View in Explorer" action - matches
    /// every other bubble type's identical action.
    let txId: String
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action, matching `LinkPreviewCardView`'s convention.
    var onSelect: (() -> Void)?
    /// Double-tap opens the owning message's quick-reaction bar, exactly like a normal bubble.
    var onDoubleTap: (() -> Void)?

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    /// A KaPost link's post, once the indexer has it (`KaPostPreviewLoader`).
    @State private var kaPostPreview: KaPostPreview?

    private var iconName: String {
        switch match.link {
        case .profile: return "person.crop.circle"
        case .paymentRequest: return "arrow.up.circle"
        case .kaPost: return "text.bubble"
        case .publicChatRoom: return "number"
        case .hubSection(let tab): return tab.icon
        }
    }

    private var eyebrow: String {
        switch match.link {
        case .profile: return "KaChat Profile"
        case .paymentRequest: return "Payment Request"
        case .kaPost: return "KaPost"
        case .publicChatRoom: return "Public Chat Room"
        case .hubSection: return "Kaspa Hub"
        }
    }

    private var title: String {
        switch match.link {
        case .profile(let address):
            return ContactsManager.shared.displayName(for: address)
        case .paymentRequest(let request):
            return "\(request.amountText) \(KaspaUnit.symbol)"
        case .kaPost:
            // the poster, named the way a profile card names them
            if let author = kaPostPreview?.authorAddress {
                return ContactsManager.shared.displayName(for: author)
            }
            return AppLocalization.string("A post on KaPost")
        case .publicChatRoom(let channel):
            return "#\(channel)"
        case .hubSection(let tab):
            return AppLocalization.string(tab.label)
        }
    }

    private var subtitle: String {
        switch match.link {
        case .profile(let address):
            let isContact = ContactsManager.shared.contacts.contains { $0.address.lowercased() == address }
            // Translated here: the card shows it as a String (audit 2026-11-24 #33).
            return AppLocalization.string(isContact ? "Tap to open your chat." : "Tap to start a chat on K.")
        case .paymentRequest(let request):
            let action = request.isOwn ? AppLocalization.string("Your payment request. Tap to view.") : AppLocalization.string("Tap to pay.")
            var lines: [String] = []
            if !request.memo.isEmpty { lines.append(request.memo) }
            // the maker, as the signature in the link proves - their name, not the payment address
            if let creator = request.creator, !request.isOwn {
                lines.append(String(format: AppLocalization.string("From %@"), ContactsManager.shared.displayName(for: creator)))
            }
            lines.append(action)
            return lines.joined(separator: "\n")
        case .kaPost:
            return kaPostPreview?.text ?? AppLocalization.string("Tap to open it in KaPost.")
        case .publicChatRoom(let channel):
            // Curated rooms and rooms already in the list just open; anything else is created
            // and added to the user's channel list on tap, so say so before they tap.
            let known = PublicChatService.curatedChannels.contains(channel)
                || PublicChatService.shared.channels.contains { $0.channelName == channel }
            return AppLocalization.string(known
                ? "Tap to open this public chat room."
                : "Tap to join this public chat room.")
        case .hubSection(let tab):
            return AppLocalization.string(tab.hubBlurb) + "\n" + AppLocalization.string("Tap to open it in K.")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                if case .hubSection(let tab) = match.link {
                    // the card's own icon, as the Hub grid draws it (the .kachat wordmark too)
                    AppTabIcon(tab: tab, size: 18)
                } else {
                    Image(systemName: iconName)
                        .font(.scaled(size: 18, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .textCase(.uppercase)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        // Same glass card LinkPreviewCardView's placeholder uses, so an internal link sits in
        // the thread as a sibling of the external link cards rather than a foreign element.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Listed first so a double-tap is claimed here instead of also firing the single tap -
        // matches LinkPreviewCardView's identical pairing.
        .onTapGesture(count: 2) { onDoubleTap?() }
        .onTapGesture { KaChatLinkRouter.open(match.link, fromChat: true) }
        .messageActions(title: "KaChat Link", preview: match.url.absoluteString) { linkActions }
        .task(id: match.url) {
            guard case .kaPost(let txId) = match.link else { return }
            kaPostPreview = KaPostPreviewLoader.cached(txId)
            if kaPostPreview == nil { kaPostPreview = await KaPostPreviewLoader.load(txId) }
        }
    }

    private var linkActions: [MessageAction] {
        var actions: [MessageAction] = [
            // KaPosts posts open in the app too since 2026-11-21
            MessageAction(title: "Open in K", subtitle: "Opens it right here in the app.", systemImage: "arrow.up.forward.app") {
                KaChatLinkRouter.open(match.link, fromChat: true)
            },
            .copyLink { UIPasteboard.general.string = match.url.absoluteString }
        ]
        if let explorerURL = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
            actions.append(.explorer(explorerURL))
        }
        if let onSelect { actions.append(.select(onSelect)) }
        return actions
    }
}

struct LinkifiedMessageTextView: UIViewRepresentable {
    let text: String
    let isOutgoing: Bool
    let isSingleEmojiOnly: Bool
    let onLinkLongPress: (URL) -> Void
    /// Double-tapping a link should still open the quick-reaction bar, matching the rest of the
    /// bubble - without this, the link's own tap recognizer (which `cancelsTouchesInView`)
    /// silently swallowed the touch before the bubble's ancestor double-tap gesture ever saw it.
    var onLinkDoubleTap: () -> Void = {}
    /// When false, tapping a link does nothing - only the long-press menu can open it, so opening
    /// one requires a deliberate long-press rather than a single accidental tap.
    var tapOpensLink: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        context.coordinator.textView = textView
        context.coordinator.configureGestureRecognizersIfNeeded()
        let attributed = context.coordinator.makeAttributedText(
            text: text,
            isOutgoing: isOutgoing,
            isSingleEmojiOnly: isSingleEmojiOnly
        )
        textView.attributedText = attributed
        context.coordinator.noteAssigned(attributed)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        let newValue = context.coordinator.makeAttributedText(
            text: text,
            isOutgoing: isOutgoing,
            isSingleEmojiOnly: isSingleEmojiOnly
        )
        // SwiftUI re-runs this on every parent render (typing indicator, status tick, scroll),
        // and assigning `attributedText` invalidates TextKit's layout even when the string is
        // identical, so skip the assignment unless the content or attributes actually changed.
        // `makeAttributedText` hands back the same instance while nothing changed, so the common
        // case is a pointer comparison; the O(n) `isEqual` only runs when the instance differs.
        if context.coordinator.isAssigned(newValue) { return }
        guard !(uiView.attributedText?.isEqual(to: newValue) ?? false) else {
            context.coordinator.noteAssigned(newValue)
            return
        }
        uiView.attributedText = newValue
        context.coordinator.noteAssigned(newValue)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Below this many characters the bubble may be narrower than its maximum, so the text is
    /// measured unconstrained first to find its natural width. Anything longer wraps past the
    /// maximum width no matter what, and that unconstrained pass - one enormous line through
    /// TextKit - is the single most expensive thing a long message did on every layout.
    private static let naturalWidthMeasureLimit = 80

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let screenWidth = UIScreen.main.bounds.width
        let maxBubbleWidth = screenWidth * 0.72
        let proposedWidth = proposal.width ?? maxBubbleWidth
        let targetMaxWidth = max(1, min(maxBubbleWidth, proposedWidth))

        // Measured once per (text, available width); SwiftUI asks several times per layout pass
        // and once more per re-render, and TextKit's answer does not change in between.
        if let cached = context.coordinator.cachedSize(forMaxWidth: targetMaxWidth) {
            return cached
        }

        let targetWidth: CGFloat
        if (uiView.attributedText?.length ?? 0) > Self.naturalWidthMeasureLimit {
            targetWidth = targetMaxWidth
        } else {
            let unconstrained = uiView.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            targetWidth = max(1, min(targetMaxWidth, ceil(unconstrained.width)))
        }
        let fitting = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let size = CGSize(width: targetWidth, height: ceil(fitting.height))
        context.coordinator.storeSize(size, forMaxWidth: targetMaxWidth)
        return size
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: LinkifiedMessageTextView
        weak var textView: UITextView?
        private var tapRecognizer: UITapGestureRecognizer?
        private var doubleTapRecognizer: UITapGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?
        private var cachedText: String?
        private var cachedIsOutgoing = false
        private var cachedIsSingleEmojiOnly = false
        private var cachedAttributedText: NSAttributedString?
        /// The attributed string currently installed in the text view, by identity.
        private var assignedAttributedText: NSAttributedString?
        /// Measured sizes for the installed string, keyed by the available width (rounded to a
        /// point). Dropped whenever a different string is installed.
        private var sizesByMaxWidth: [Int: CGSize] = [:]

        init(parent: LinkifiedMessageTextView) {
            self.parent = parent
        }

        /// Styled message text shared by every coordinator (`makeAttributedText`).
        private static let sharedAttributed: NSCache<NSString, NSAttributedString> = {
            let cache = NSCache<NSString, NSAttributedString>()
            cache.countLimit = 500
            return cache
        }()

        func isAssigned(_ attributed: NSAttributedString) -> Bool {
            assignedAttributedText === attributed
        }

        func noteAssigned(_ attributed: NSAttributedString) {
            if assignedAttributedText !== attributed {
                sizesByMaxWidth.removeAll()
            }
            assignedAttributedText = attributed
        }

        func cachedSize(forMaxWidth width: CGFloat) -> CGSize? {
            sizesByMaxWidth[Int(width.rounded())]
        }

        func storeSize(_ size: CGSize, forMaxWidth width: CGFloat) {
            sizesByMaxWidth[Int(width.rounded())] = size
        }

        func configureGestureRecognizersIfNeeded() {
            guard let textView else { return }
            if doubleTapRecognizer == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
                recognizer.delegate = self
                recognizer.numberOfTapsRequired = 2
                recognizer.cancelsTouchesInView = true
                textView.addGestureRecognizer(recognizer)
                doubleTapRecognizer = recognizer
            }
            if tapRecognizer == nil, let doubleTapRecognizer {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = true
                // A single tap only fires once the double-tap recognizer has had its chance and
                // failed - otherwise the first tap of a double-tap would open the link immediately
                // before the second tap ever lands.
                recognizer.require(toFail: doubleTapRecognizer)
                textView.addGestureRecognizer(recognizer)
                tapRecognizer = recognizer
            }
            guard longPressRecognizer == nil else { return }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            recognizer.delegate = self
            recognizer.minimumPressDuration = 0.45
            recognizer.cancelsTouchesInView = true
            textView.addGestureRecognizer(recognizer)
            longPressRecognizer = recognizer
        }

        func makeAttributedText(text: String, isOutgoing: Bool, isSingleEmojiOnly: Bool) -> NSAttributedString {
            if let cachedText,
               cachedText == text,
               cachedIsOutgoing == isOutgoing,
               cachedIsSingleEmojiOnly == isSingleEmojiOnly,
               let cachedAttributedText {
                return cachedAttributedText
            }

            let baseColor = isSingleEmojiOnly ? UIColor.label : (isOutgoing ? UIColor.white : UIColor.label)
            let bodyFont = UIFont.preferredFont(forTextStyle: .body)
            // A row coming back on screen has a new coordinator: the styled text is shared across
            // them, so the link detector doesn't run again for every reappearance (2026-11-25
            // smoothness sweep). The text size is in the key, for Dynamic Type.
            let sharedKey = "\(isOutgoing)|\(isSingleEmojiOnly)|\(bodyFont.pointSize)|\(text)" as NSString
            if let shared = Self.sharedAttributed.object(forKey: sharedKey) {
                cachedText = text
                cachedIsOutgoing = isOutgoing
                cachedIsSingleEmojiOnly = isSingleEmojiOnly
                cachedAttributedText = shared
                return shared
            }
            let baseFont = isSingleEmojiOnly ? bodyFont.withSize(bodyFont.pointSize * 5.0) : bodyFont
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: baseColor
                ]
            )
            let fullRange = NSRange(location: 0, length: attributed.length)

            if let detector = SharedDetectors.link {
                detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                    guard let match, let url = match.url else { return }
                    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
                    attributed.addAttributes(
                        [
                            .link: url,
                            .foregroundColor: UIColor.systemBlue,
                            .underlineStyle: NSUnderlineStyle.single.rawValue
                        ],
                        range: match.range
                    )
                }
            }

            let result = NSAttributedString(attributedString: attributed)
            Self.sharedAttributed.setObject(result, forKey: sharedKey)
            cachedText = text
            cachedIsOutgoing = isOutgoing
            cachedIsSingleEmojiOnly = isSingleEmojiOnly
            cachedAttributedText = result
            return result
        }

        @objc
        private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            guard parent.tapOpensLink else { return }
            let point = gesture.location(in: textView)
            guard let url = url(at: point, in: textView) else { return }
            // A link that points back into KaChat routes in-app. Handing our own universal link
            // to `UIApplication.shared.open` would bounce the user out to Safari instead - iOS
            // deliberately does not re-enter the app that opened it.
            // `openAnywhere` also keeps any non-web scheme from running on a tap.
            KaChatLinkRouter.openAnywhere(url, fromChat: true)
        }

        @objc
        private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            let point = gesture.location(in: textView)
            guard url(at: point, in: textView) != nil else { return }
            parent.onLinkDoubleTap()
        }

        @objc
        private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let textView else { return }
            let point = gesture.location(in: textView)
            guard let url = url(at: point, in: textView) else { return }
            Task { @MainActor in LinkLongPress.lastFiredAt = Date() }
            parent.onLinkLongPress(url)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let textView else { return false }
            guard gestureRecognizer === tapRecognizer || gestureRecognizer === doubleTapRecognizer || gestureRecognizer === longPressRecognizer else {
                return true
            }
            let location = gestureRecognizer.location(in: textView)
            return url(at: location, in: textView) != nil
        }

        private func url(at point: CGPoint, in textView: UITextView) -> URL? {
            let textContainerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            guard textContainerPoint.x >= 0, textContainerPoint.y >= 0 else { return nil }

            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            let glyphIndex = layoutManager.glyphIndex(for: textContainerPoint, in: textContainer)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            guard glyphRect.contains(textContainerPoint) else { return nil }

            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < textView.textStorage.length else { return nil }

            let attributes = textView.textStorage.attributes(at: charIndex, effectiveRange: nil)
            if let url = attributes[.link] as? URL {
                return url
            }
            if let urlString = attributes[.link] as? String {
                return URL(string: urlString)
            }
            return nil
        }

    }
}

/// Full text of a message too long to render inline (see `MessageBubbleView.inlineTextTruncationThreshold`)
/// - a plain scrollable, selectable text view, matching iMessage's "tap to see more" detail sheet.
struct FullMessageTextView: View {
    let text: String
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

/// The pending sweep over a message or payment that isn't on chain yet. Driven by a
/// `TimelineView`, as `FeeShimmerOverlay` is: it draws only while on screen and stops with the
/// overlay. The old `withAnimation(.repeatForever)` kept a transaction running on the bubble
/// after it was hidden (audit 2026-11-25 B20). At most 30 frames a second, which a soft sweep
/// doesn't need more than (uncapped it redrew the bubble at 120 Hz on ProMotion), and paused
/// while the bubble is off screen (audit 2026-11-25 M8).
private struct ShimmerOverlay: View {
    private static let sweepSeconds: TimeInterval = 1.4
    @State private var isVisible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isVisible)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.sweepSeconds)
            let phase = CGFloat(elapsed / Self.sweepSeconds) * 2 - 1
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(20))
                    .offset(x: phase * geo.size.width * 1.5)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Not `private` - reused by `GroupChatDetailView` so group photo messages render identically
/// to 1:1 ones instead of duplicating this (thumbnail caching, reveal-gating, share sheet) logic.
struct LazyImageBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    // Fixed size for the placeholder / hidden states (no image loaded yet). Once the image
    // is loaded, the bubble takes the image's natural aspect ratio within these max bounds — so a
    // tall screenshot shows tall and a wide photo shows wide, instead of a fixed letterboxed box.
    private static let thumbnailDisplaySize = CGSize(width: 220, height: 160)
    private static let maxThumbnailWidth: CGFloat = 240
    private static let maxThumbnailHeight: CGFloat = 320

    /// The image's natural aspect ratio, fit within the max bounds (never upscaled past its own
    /// pixels), so the bubble matches the picture instead of forcing a fixed rectangle.
    private var thumbnailAspectSize: CGSize {
        guard let img = thumbnailState?.image, img.size.width > 0, img.size.height > 0 else {
            return Self.thumbnailDisplaySize
        }
        let aspect = img.size.width / img.size.height
        var w = Self.maxThumbnailWidth
        var h = w / aspect
        if h > Self.maxThumbnailHeight { h = Self.maxThumbnailHeight; w = h * aspect }
        w = min(w, img.size.width); h = min(h, img.size.height)
        return CGSize(width: max(w, 80), height: max(h, 80))
    }

    /// Aspect size once the thumbnail is loaded, else the fixed placeholder size.
    private var currentDisplaySize: CGSize {
        (thumbnailState?.txId == txId) ? thumbnailAspectSize : Self.thumbnailDisplaySize
    }

    let media: MediaFile
    let txId: String
    /// The image caches' key: the txId, or for a multi-part photo its joined bytes' own key (the
    /// first part's txId already names that part's chunk in the caches).
    let imageCacheKey: String
    let shouldShowRetry: Bool
    let photosBlocked: Bool
    let senderDisplayName: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    /// Double-tap opens the quick-reaction bar rather than replying directly - nil disables it.
    let onDoubleTap: (() -> Void)?
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action entirely, matching `onReply`'s nil-disables convention.
    let onSelect: (() -> Void)?

    @State private var thumbnailState: (txId: String, image: UIImage)?
    /// A GIF's bytes, once its first frame is in: the bubble plays them (`AnimatedImageView`).
    @State private var animatedState: (txId: String, data: Data)?
    @State private var previewImage: UIImage?
    @State private var previewAnimates = false
    @State private var sharePayload: MessageImageSharePayload?
    @State private var isLoadingPreview = false
    @State private var showImagePreview = false

    init(
        media: MediaFile,
        txId: String,
        shouldShowRetry: Bool,
        photosBlocked: Bool,
        senderDisplayName: String,
        onCopy: ((String, ToastStyle) -> Void)?,
        onRetry: (() -> Void)?,
        onReply: (() -> Void)?,
        onDoubleTap: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil,
        imageCacheKey: String? = nil
    ) {
        self.media = media
        self.txId = txId
        self.imageCacheKey = imageCacheKey ?? txId
        self.shouldShowRetry = shouldShowRetry
        self.photosBlocked = photosBlocked
        self.senderDisplayName = senderDisplayName
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onReply = onReply
        self.onDoubleTap = onDoubleTap
        self.onSelect = onSelect
        // A thumbnail already decoded shows on the first frame, at its own shape: starting empty
        // drew every photo at the placeholder's size and then resized it, so rows jumped as they
        // came back on screen (2026-11-25 smoothness sweep).
        if let cached = media.cachedThumbnail(cacheKey: imageCacheKey ?? txId) {
            _thumbnailState = State(initialValue: (txId, cached))
        }
    }

    /// A GIF: its bytes, checked off the main thread, so the bubble plays it. Only a real GIF
    /// within the play limits; anything else keeps the still thumbnail. Only for a GIF's media
    /// type: every photo used to decode its whole file here on every appearance, filling the
    /// shared data cache that voice notes and photo parts read from (2026-11-25 sweep).
    private func loadAnimationIfGIF() async {
        guard media.mimeType.lowercased().contains("gif") else { return }
        let media = media
        let cacheKey = imageCacheKey
        let animated = await Task.detached(priority: .utility) { () -> Data? in
            guard let data = media.fileData(cacheKey: cacheKey), GIFPrep.isSafeToAnimate(data) else { return nil }
            return data
        }.value
        guard !Task.isCancelled else { return }
        if let animated { animatedState = (txId, animated) }
    }

    var body: some View {
        if photosBlocked {
            hiddenBubble
        } else {
            unlockedBubble
        }
    }

    private var hiddenBubble: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.scaled(size: 24, weight: .regular))
                .foregroundColor(.secondary)
            Text("\(senderDisplayName) sent a photo")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("It shows 10 minutes after you have both sent a message.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var unlockedBubble: some View {
        // Plain tappable view rather than `Button`: a Button's tap action fires immediately on
        // the first touch-up, which always won the race against a double-tap-to-reply gesture
        // attached to an ancestor view (opening the preview before "is this a double tap?" could
        // even be decided) and aggressively claimed touches that were meant to start a
        // swipe-to-reply drag. Attaching both tap counts directly to this same view lets SwiftUI
        // properly wait to see whether a second tap follows before firing the single-tap action.
        ZStack {
            if let thumbnailState, thumbnailState.txId == txId {
                // Fill the aspect-sized frame exactly (frame already matches the image ratio), so
                // there are no gray letterbox bars — the bubble is the shape of the picture.
                if let animatedState, animatedState.txId == txId {
                    AnimatedImageView(data: animatedState.data)
                } else {
                    Image(uiImage: thumbnailState.image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                placeholder
            }

            if isLoadingPreview {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(Circle())
            }
        }
        .frame(width: currentDisplaySize.width, height: currentDisplaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTap?()
        }
        .onTapGesture(count: 1) {
            openPreview()
        }
        .messageActions(title: "File", preview: media.name) {
            var actions: [MessageAction] = [
                MessageAction(title: "Copy File Name", subtitle: "Copies the name to your clipboard.", systemImage: "doc.on.doc") {
                    handleCopy(media.name, toast: "File name copied.")
                }
            ]
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                actions.append(.explorer(url))
            }
            if let onReply { actions.append(.reply(onReply)) }
            if shouldShowRetry { actions.append(.retry { onRetry?() }) }
            if let onSelect { actions.append(.select(onSelect)) }
            return actions
        }
        .tint(.accentColor)
        .task(id: txId) {
            guard thumbnailState?.txId != txId else { return }
            guard let loadedThumbnail = await media.thumbnailImage(cacheKey: imageCacheKey),
                  !Task.isCancelled else {
                return
            }
            thumbnailState = (txId, loadedThumbnail)
            await loadAnimationIfGIF()
        }
        // A thumbnail found at once (`init`) still plays if it's a GIF.
        .task(id: "gif|\(txId)") {
            guard animatedState?.txId != txId, thumbnailState?.txId == txId else { return }
            await loadAnimationIfGIF()
        }

        .fullScreenCover(isPresented: $showImagePreview) {
            if let previewImage, let sharePayload {
                ImagePreviewView(
                    image: previewImage,
                    title: media.name,
                    sharePayload: sharePayload,
                    animates: previewAnimates
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.scaled(size: 28, weight: .regular))
            .foregroundColor(.secondary)
            .frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)
    }

    /// A tap opening the preview can land while the list is still settling from a scroll - if
    /// that ambient animation transaction is still
    /// active when `showImagePreview` flips, SwiftUI's animation engine can end up asked to
    /// animate the `fullScreenCover` presentation using a timeline it's already mid-way through
    /// for the unrelated offset, which has produced a hard freeze/crash (SwiftUI's internal
    /// "Invalid sample ... with time ... > last time ..." assertion - a monotonicity violation
    /// between two colliding animation transactions). This boolean flip should never itself be
    /// animated, so explicitly disabling animation for it removes it from that collision.
    private func setShowImagePreview(_ value: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showImagePreview = value
        }
    }

    private func openPreview() {
        if previewImage != nil, sharePayload != nil {
            setShowImagePreview(true)
            return
        }

        isLoadingPreview = true
        Task {
            let loaded = await media.previewImagePayload(cacheKey: imageCacheKey)
            isLoadingPreview = false
            guard let loaded else { return }
            previewImage = loaded.image
            previewAnimates = loaded.animates
            sharePayload = loaded.sharePayload
            setShowImagePreview(true)
        }
    }

    private func handleCopy(_ value: String, toast: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        onCopy?(AppLocalization.string(toast), .success)
    }
}

/// Bounds how many thumbnail decodes run at once. Without this, opening a chat with many
/// photos - especially jumping straight to the bottom of a long history, as happens when a
/// lock-screen notification tap cold-launches straight into a photo-heavy chat - fired one
/// `Task.detached(priority: .userInitiated)` base64-decode-and-downsample per bubble that
/// appeared, all at once. That can saturate every core while the main thread is also trying to
/// lay out/scroll the message list and, on a cold launch, while wallet unlock/node pool init are
/// already competing for the same CPU time - reading as a multi-second freeze rather than a
/// smooth scroll-in. Capping concurrency keeps CPU headroom free for that other work; each
/// decode is still cheap individually (ImageIO's downsampled thumbnail path), so a small cap
/// doesn't meaningfully slow down how soon photos appear.
private actor ImageDecodeLimiter {
    static let shared = ImageDecodeLimiter()

    private var availablePermits = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Not `private` - reused by `GroupChatDetailView` for group photo/audio message rendering.
struct MediaFile: Codable {
    let type: String
    let name: String
    let size: Int?
    let mimeType: String
    let content: String
    /// A long voice note's part tag (MESSAGING.md, "Long voice notes"). Read leniently: a
    /// malformed tag is nil and the file is a plain single voice note.
    let voicePart: VoicePartTag?
    /// The same tag on a chunk of a multi-part photo (MESSAGING.md, "Photos: quality tiers and
    /// multi-part photos"), read as leniently.
    let mediaPart: VoicePartTag?

    private enum CodingKeys: String, CodingKey {
        case type, name, size, mimeType, content, voicePart, mediaPart
    }

    /// A media file made here: a multi-part photo's joined bytes.
    init(name: String, mimeType: String, data: Data) {
        type = "file"
        self.name = name
        size = data.count
        self.mimeType = mimeType
        content = "data:\(mimeType);base64,\(data.base64EncodedString())"
        voicePart = nil
        mediaPart = nil
    }

    private struct WireVoicePart: Codable {
        let id: String
        let index: Int
        let count: Int
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        content = try container.decode(String.self, forKey: .content)
        let wire = (try? container.decodeIfPresent(WireVoicePart.self, forKey: .voicePart)) ?? nil
        voicePart = mimeType.lowercased().hasPrefix("audio/")
            ? wire.flatMap { VoicePartTag(id: $0.id, index: $0.index, count: $0.count) }
            : nil
        let mediaWire = (try? container.decodeIfPresent(WireVoicePart.self, forKey: .mediaPart)) ?? nil
        mediaPart = mimeType.lowercased().hasPrefix("image/")
            ? mediaWire.flatMap { VoicePartTag(id: $0.id, index: $0.index, count: $0.count) }
            : nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(content, forKey: .content)
        if let voicePart {
            try container.encode(WireVoicePart(id: voicePart.id, index: voicePart.index, count: voicePart.count), forKey: .voicePart)
        }
        if let mediaPart {
            try container.encode(WireVoicePart(id: mediaPart.id, index: mediaPart.index, count: mediaPart.count), forKey: .mediaPart)
        }
    }

    private final class OptionalMediaFileBox: NSObject {
        let value: MediaFile?
        init(_ value: MediaFile?) {
            self.value = value
        }
    }
    private static let parsedCache: NSCache<NSString, OptionalMediaFileBox> = {
        let cache = NSCache<NSString, OptionalMediaFileBox>()
        cache.countLimit = 512
        return cache
    }()
    private static let dataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    var isAudio: Bool {
        mimeType.lowercased().hasPrefix("audio/")
    }

    var fileData: Data? {
        fileData(cacheKey: nil)
    }

    func fileData(cacheKey: String?) -> Data? {
        if let key = Self.cacheKey(from: cacheKey),
           let cached = Self.dataCache.object(forKey: key) {
            return cached as Data
        }
        let decoded = Self.dataFromDataURL(content) ?? Data(base64Encoded: content)
        if let key = Self.cacheKey(from: cacheKey), let decoded {
            Self.dataCache.setObject(decoded as NSData, forKey: key, cost: decoded.count)
        }
        return decoded
    }

    /// The full-screen preview's long edge: the largest photo sent from here
    /// (`ImagePrep.tierEdges`), so zooming in still has detail.
    static let previewMaxPixelSize: CGFloat = 3000

    /// The photo at full-screen size (`previewMaxPixelSize`), never decoded whole.
    func image(cacheKey: String?) -> UIImage? {
        guard isImage else { return nil }
        if let key = Self.cacheKey(from: cacheKey),
           let cachedImage = Self.imageCache.object(forKey: key) {
            return cachedImage
        }
        guard let data = fileData(cacheKey: cacheKey),
              let image = Self.downsampledImage(data: data, maxPixelSize: Self.previewMaxPixelSize) else {
            return nil
        }
        if let key = Self.cacheKey(from: cacheKey) {
            Self.imageCache.setObject(image, forKey: key, cost: Self.cacheCost(for: image))
        }
        return image
    }

    /// The thumbnail if it's already decoded in memory, without waiting (a bubble's first frame).
    func cachedThumbnail(cacheKey: String?, maxPixelSize: CGFloat = 440) -> UIImage? {
        guard isImage, let key = Self.thumbnailCacheKey(from: cacheKey, maxPixelSize: maxPixelSize) else { return nil }
        return Self.thumbnailCache.object(forKey: key)
    }

    func thumbnailImage(cacheKey: String?, maxPixelSize: CGFloat = 440) async -> UIImage? {
        guard isImage else { return nil }
        if let key = Self.thumbnailCacheKey(from: cacheKey, maxPixelSize: maxPixelSize),
           let cached = Self.thumbnailCache.object(forKey: key) {
            return cached
        }

        await ImageDecodeLimiter.shared.wait()
        defer { Task { await ImageDecodeLimiter.shared.signal() } }

        return await Task.detached(priority: .userInitiated) {
            guard let data = fileData(cacheKey: cacheKey),
                  let image = Self.downsampledImage(data: data, maxPixelSize: maxPixelSize) else {
                return nil
            }

            if let key = Self.thumbnailCacheKey(from: cacheKey, maxPixelSize: maxPixelSize) {
                Self.thumbnailCache.setObject(image, forKey: key, cost: Self.cacheCost(for: image))
            }
            return image
        }.value
    }

    /// `animates`: a GIF small enough to play (`GIFPrep.isSafeToAnimate`), checked here off the
    /// main thread.
    func previewImagePayload(cacheKey: String?) async -> (image: UIImage, sharePayload: MessageImageSharePayload, animates: Bool)? {
        guard isImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = fileData(cacheKey: cacheKey),
                  let image = image(cacheKey: cacheKey) else {
                return nil
            }
            return (
                image,
                MessageImageSharePayload(data: data, fileName: name, mimeType: mimeType),
                GIFPrep.isSafeToAnimate(data)
            )
        }.value
    }

    static func from(_ text: String, cacheKey cacheToken: String? = nil) -> MediaFile? {
        if let key = cacheKey(from: cacheToken),
           let cached = parsedCache.object(forKey: key) {
            return cached.value
        }

        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            if let key = cacheKey(from: cacheToken) {
                parsedCache.setObject(OptionalMediaFileBox(nil), forKey: key)
            }
            return nil
        }
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(MediaFile.self, from: data),
              file.type == "file" else {
            if let key = cacheKey(from: cacheToken) {
                parsedCache.setObject(OptionalMediaFileBox(nil), forKey: key)
            }
            return nil
        }
        if let key = cacheKey(from: cacheToken) {
            parsedCache.setObject(OptionalMediaFileBox(file), forKey: key)
        }
        return file
    }

    private static func cacheKey(from value: String?) -> NSString? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed as NSString
    }

    private static func thumbnailCacheKey(from value: String?, maxPixelSize: CGFloat) -> NSString? {
        guard let base = cacheKey(from: value) else { return nil }
        return "\(base)|thumb|\(Int(maxPixelSize.rounded()))" as NSString
    }

    private static func dataFromDataURL(_ text: String) -> Data? {
        guard let prefixRange = text.range(of: "base64,") else { return nil }
        let base64 = text[prefixRange.upperBound...]
        return Data(base64Encoded: String(base64))
    }

    /// Past this a chat photo isn't a real one: photos sent from here are at most 3000 px
    /// (`ImagePrep.tierEdges`), and a 48 MP camera photo is about the largest there is. Even a
    /// thumbnail of a bigger one can decode it whole first.
    private static let maxSourcePixels: Double = 50_000_000

    /// The only way chat photos are decoded: never at full size, and nil (the placeholder) rather
    /// than `UIImage(data:)` when this fails, since a few KB can declare gigabytes of pixels.
    private static func downsampledImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              Double(width) * Double(height) <= maxSourcePixels else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func cacheCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let width = max(1, Int((image.size.width * image.scale).rounded(.up)))
        let height = max(1, Int((image.size.height * image.scale).rounded(.up)))
        return width * height * 4
    }
}

/// A voice note's length and waveform, worked out once per process. Each bubble used to decode
/// the whole note to a temporary file for these every time it appeared (audit 2026-11-25 B9);
/// now a bubble scrolling back in, or the same note in a new view, reads them from here.
/// Keyed by the message's txId and the audio's size (a long note: its anchor txId and the parts
/// present), so a note never reads another's entry.
enum VoiceNoteInfoCache {
    final class Info: Sendable {
        let duration: TimeInterval
        let waveform: [Float]
        init(duration: TimeInterval, waveform: [Float]) {
            self.duration = duration
            self.waveform = waveform
        }
    }

    private static let cache: NSCache<NSString, Info> = {
        let cache = NSCache<NSString, Info>()
        cache.countLimit = 500
        return cache
    }()

    static func info(forKey key: String) -> Info? {
        cache.object(forKey: key as NSString)
    }

    static func store(_ info: Info, forKey key: String) {
        cache.setObject(info, forKey: key as NSString)
    }

    /// A one-part note's key; nil without a txId (nothing to tell two notes apart by).
    static func key(txId: String, data: Data) -> String? {
        guard !txId.isEmpty else { return nil }
        return "\(txId):\(data.count)"
    }

    /// A long note's key: its anchor txId and which parts (and sizes) are here.
    static func key(txId: String, input: VoiceNotePartsInput) -> String? {
        guard !txId.isEmpty else { return nil }
        return "\(txId)#\(input.count):\(input.signature)"
    }
}

private final class AudioPlaybackHelper: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @Published var isPlaying = false
    @Published var durationText: String = "--:--"
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var waveformSamples: [Float] = []

    private var player: AVAudioPlayer?
    private var tempPlaybackURL: URL?
    /// The note `player` was decoded from. A finished player stays for a replay, so a replay
    /// first checks the bubble still holds this note (audit 2026-11-25 M6).
    private var playerSource: (data: Data, mimeType: String)?
    private var cachedDuration: TimeInterval?
    private var loadedKey: String?
    private var progressTimer: Timer?
    /// Bumped by every stop: a decode still running for an older Play doesn't start playing.
    private var playGeneration = 0

    /// Every helper that has started playback, weakly. Each bubble owns its own helper (a per-row
    /// `@StateObject`), so the thread view has no handle on the one that is playing; it stops
    /// them all through here when the thread closes - see `stopAllPlayback()`. Main-thread only.
    private static let playingHelpers = NSHashTable<AudioPlaybackHelper>.weakObjects()

    /// Stop playback in every bubble. Called from the thread view's `onDisappear`, which is where
    /// "the user left the chat" is actually known - the row's own `onDisappear` also fires when a
    /// `LazyVStack` scrolls the bubble out of view, which used to cut the voice note off mid-play.
    static func stopAllPlayback() {
        for helper in playingHelpers.allObjects {
            helper.stop()
        }
        playingHelpers.removeAllObjects()
        MultipartAudioPlaybackHelper.stopAllPlayback()
    }

    deinit {
        // A bubble dropped while playing: its audio stops with it, so give the session back.
        progressTimer?.invalidate()
        player?.stop()
        VoicePlaybackCoordinator.shared.didStop(self)
        if let url = tempPlaybackURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Length and waveform for the bubble: from `VoiceNoteInfoCache` when this note was read
    /// before, otherwise decoded once off the main thread and cached.
    func preloadDuration(data: Data, mimeType: String, txId: String) {
        let key = VoiceNoteInfoCache.key(txId: txId, data: data) ?? "hash:\(data.count):\(data.hashValue)"
        if loadedKey == key, cachedDuration != nil { return }
        loadedKey = key
        if let info = VoiceNoteInfoCache.info(forKey: key) {
            apply(info)
            return
        }

        isLoading = true
        let cacheable = !txId.isEmpty
        Task.detached(priority: .utility) { [weak self] in
            let info = try? Self.loadAudioInfo(data: data, mimeType: mimeType)
            if let info, cacheable { VoiceNoteInfoCache.store(info, forKey: key) }
            await MainActor.run {
                guard let self, self.loadedKey == key else { return }
                if let info {
                    self.apply(info)
                } else {
                    self.durationText = "--:--"
                    self.waveformSamples = Array(repeating: 0.3, count: 40)
                    self.isLoading = false
                }
            }
        }
    }

    private func apply(_ info: VoiceNoteInfoCache.Info) {
        cachedDuration = info.duration
        if !isPlaying { durationText = formattedDuration(info.duration) }
        waveformSamples = info.waveform
        isLoading = false
    }

    private static func loadAudioInfo(data: Data, mimeType: String) throws -> VoiceNoteInfoCache.Info {
        let decoded = try decodeForPlayback(data: data, mimeType: mimeType)
        defer { if decoded.isTemporary { try? FileManager.default.removeItem(at: decoded.url) } }
        let samples = extractWaveformSamples(from: decoded.url, sampleCount: 40)
        let duration = try decoded.duration ?? AVAudioPlayer(contentsOf: decoded.url).duration
        return VoiceNoteInfoCache.Info(duration: duration, waveform: samples)
    }

    /// The note as a file AVAudioPlayer can open: Opus decoded to PCM, anything else written as
    /// it is. Off the main thread: a long note takes a moment.
    private struct PlayableFile: Sendable {
        let url: URL
        let duration: TimeInterval?
        let isTemporary: Bool
        let fileTypeHint: String?
    }

    private static func decodeForPlayback(data: Data, mimeType: String) throws -> PlayableFile {
        let lowered = mimeType.lowercased()
        if lowered.contains("webm") {
            let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
            return PlayableFile(url: decoded.url, duration: decoded.duration, isTemporary: true,
                                fileTypeHint: AVFileType.caf.rawValue)
        }
        if lowered.contains("ogg") || lowered.contains("opus") {
            let decoded = try OggOpusDecoder.decodeToPCMFile(data: data)
            return PlayableFile(url: decoded.url, duration: decoded.duration, isTemporary: true,
                                fileTypeHint: AVFileType.caf.rawValue)
        }
        // Other formats play as they are.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        try data.write(to: tempURL)
        return PlayableFile(url: tempURL, duration: nil, isTemporary: true, fileTypeHint: nil)
    }

    private static func extractWaveformSamples(from url: URL, sampleCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        do {
            try file.read(into: buffer)
        } catch {
            return Array(repeating: 0.3, count: sampleCount)
        }

        guard let floatData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        let totalFrames = Int(buffer.frameLength)
        let framesPerSample = max(1, totalFrames / sampleCount)
        var samples: [Float] = []

        for i in 0..<sampleCount {
            let start = i * framesPerSample
            let end = min(start + framesPerSample, totalFrames)
            var maxAmp: Float = 0
            for j in start..<end {
                maxAmp = max(maxAmp, abs(floatData[j]))
            }
            // Normalize and clamp
            samples.append(min(1.0, max(0.1, maxAmp * 2)))
        }

        return samples
    }

    /// Play decodes the note off the main thread (the bubble shows its spinner meanwhile), then
    /// plays through `VoicePlaybackCoordinator`, which stops any other note and gives the audio
    /// session back when this one stops.
    func togglePlayback(data: Data, mimeType: String) {
        if isPlaying {
            stop()
            return
        }
        // Played to the end before: the decoded file is still here, so play it again - unless
        // the bubble's note changed since, when the old player and its file go first.
        if let player {
            if let source = playerSource, source.mimeType == mimeType, source.data == data {
                play(player)
                return
            }
            stop()
        }
        guard !isLoading else { return }
        isLoading = true
        playGeneration += 1
        let generation = playGeneration
        // Listed while decoding too, so leaving the thread cancels a Play still loading.
        Self.playingHelpers.add(self)
        Task.detached(priority: .userInitiated) { [weak self] in
            let file: PlayableFile?
            do {
                file = try Self.decodeForPlayback(data: data, mimeType: mimeType)
            } catch {
                AppLog.log("[AudioPlayback] Couldn't decode a voice note: %@", error.localizedDescription)
                file = nil
            }
            await MainActor.run {
                guard let self, self.playGeneration == generation else {
                    if let file, file.isTemporary { try? FileManager.default.removeItem(at: file.url) }
                    return
                }
                self.isLoading = false
                guard let file else { return }
                self.startPlaying(file, source: (data: data, mimeType: mimeType))
            }
        }
    }

    private func startPlaying(_ file: PlayableFile, source: (data: Data, mimeType: String)) {
        do {
            let player = try AVAudioPlayer(contentsOf: file.url, fileTypeHint: file.fileTypeHint)
            player.delegate = self
            player.prepareToPlay()
            if let url = tempPlaybackURL, url != file.url { try? FileManager.default.removeItem(at: url) }
            self.player = player
            playerSource = source
            tempPlaybackURL = file.isTemporary ? file.url : nil
            if cachedDuration == nil { cachedDuration = file.duration ?? player.duration }
            play(player)
        } catch {
            if file.isTemporary { try? FileManager.default.removeItem(at: file.url) }
            isPlaying = false
        }
    }

    private func play(_ player: AVAudioPlayer) {
        guard VoicePlaybackCoordinator.shared.willStart(self, stop: { [weak self] in self?.stop() }) else { return }
        player.currentTime = 0
        guard player.play() else {
            stop()
            return
        }
        isPlaying = true
        progress = 0
        Self.playingHelpers.add(self)
        startProgressTimer()
        durationText = formattedDuration(cachedDuration ?? player.duration)
    }

    func stop() {
        playGeneration += 1
        isLoading = false
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        playerSource = nil
        if let url = tempPlaybackURL {
            try? FileManager.default.removeItem(at: url)
            tempPlaybackURL = nil
        }
        isPlaying = false
        progress = 0
        if let duration = cachedDuration {
            durationText = formattedDuration(duration)
        }
        VoicePlaybackCoordinator.shared.didStop(self)
    }

    /// 10 Hz: smooth enough for a 40-bar waveform, half the redraws of the old 20 Hz.
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            let duration = player.duration
            if duration > 0 {
                self.progress = player.currentTime / duration
            }
        }
    }

    /// Played to the end: the session goes back, and the player and its file stay for a replay
    /// (the bubble going away, or the thread closing, removes them).
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.player === player else { return }
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.isPlaying = false
            self.progress = 0
            if let duration = self.cachedDuration {
                self.durationText = self.formattedDuration(duration)
            }
            VoicePlaybackCoordinator.shared.didStop(self)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "--:--" }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Wrapper that lazily creates AudioPlaybackHelper only when needed
/// Not `private` - reused by `GroupChatDetailView` for group audio message rendering.
struct LazyAudioBubble: View {
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil
    @StateObject private var helper = AudioPlaybackHelper()

    /// Stop every voice note that is playing. The thread views (`ChatDetailView`,
    /// `GroupChatDetailView`) call this from their `onDisappear`; the bubble itself no longer stops
    /// on its own `onDisappear`, which the `LazyVStack` also fires on plain scroll-out.
    static func stopAllPlayback() {
        AudioPlaybackHelper.stopAllPlayback()
    }

    var body: some View {
        AudioBubble(
            helper: helper,
            data: data,
            mimeType: mimeType,
            isOutgoing: isOutgoing,
            fileName: fileName,
            txId: txId,
            onCopy: onCopy,
            onRetry: onRetry,
            onReply: onReply,
            onSelect: onSelect
        )
    }
}

private struct AudioBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject var helper: AudioPlaybackHelper
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil
    @State private var showShareSheet = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                helper.togglePlayback(data: data, mimeType: mimeType)
            } label: {
                if helper.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: helper.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.scaled(size: 32))
                }
            }
            .disabled(helper.isLoading)

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(
                    samples: helper.waveformSamples,
                    progress: helper.progress,
                    isOutgoing: isOutgoing
                )
                .frame(height: 24)

                Text(helper.durationText)
                    .font(.caption)
                    .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
        .foregroundColor(isOutgoing ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .messageActions(title: "Voice Message") {
            var actions: [MessageAction] = [
                MessageAction(title: "Save Audio", subtitle: "Saves or shares the recording as a file.", systemImage: "square.and.arrow.down") {
                    showShareSheet = true
                }
            ]
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                actions.append(.explorer(url))
            }
            if let onReply { actions.append(.reply(onReply)) }
            if let onRetry { actions.append(.retry(onRetry)) }
            if let onSelect { actions.append(.select(onSelect)) }
            return actions
        }
        .tint(.accentColor)
        .sheet(isPresented: $showShareSheet) {
            AudioShareSheet(data: data, fileName: fileName, mimeType: mimeType)
        }
        .onAppear {
            helper.preloadDuration(data: data, mimeType: mimeType, txId: txId)
        }
        // No `onDisappear { helper.stop() }` here: inside the thread's `LazyVStack` that fires
        // whenever the bubble scrolls out of view, which killed the voice note mid-play the moment
        // the user scrolled. Leaving the thread stops playback via `LazyAudioBubble.stopAllPlayback()`.
    }
}

// MARK: - Multi-part photos

/// The chunks of one multi-part photo that are on this device (MESSAGING.md, "Photos: quality
/// tiers and multi-part photos"). The photo exists only once every chunk is here: they are
/// joined in index order, then decoded.
struct PhotoPartsInput {
    struct Piece {
        let index: Int
        let data: Data
    }
    let count: Int
    /// The chunks present, in index order.
    let parts: [Piece]
    let mimeType: String
    /// The first part's txId: the bubble's identity, explorer link, reply and react target.
    let anchorTxId: String

    var isComplete: Bool {
        parts.count == count && parts.map(\.index) == Array(1...max(1, count))
    }

    /// The joined photo's cache key - its own, never the first part's (that names its chunk).
    var imageCacheKey: String { "\(anchorTxId)#joined-\(count)" }

    private final class Box {
        let media: MediaFile
        init(_ media: MediaFile) { self.media = media }
    }
    private static let joinedCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        // 16 was fewer than a chat with photos holds on screen and just above it: a miss joins
        // and base64-encodes the whole photo during a redraw (2026-11-25 smoothness sweep)
        cache.countLimit = 48
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    /// The photo, once every chunk is here; nil until then.
    var joinedMedia: MediaFile? {
        guard isComplete else { return nil }
        let key = imageCacheKey as NSString
        if let cached = Self.joinedCache.object(forKey: key) { return cached.media }
        var joined = Data()
        joined.reserveCapacity(parts.reduce(0) { $0 + $1.data.count })
        for part in parts { joined.append(part.data) }
        let media = MediaFile(name: mimeType.lowercased() == "image/gif" ? "animation.gif" : "photo.jpg", mimeType: mimeType, data: joined)
        Self.joinedCache.setObject(Box(media), forKey: key, cost: joined.count * 2)
        return media
    }
}

/// A multi-part photo still arriving: a placeholder with "Receiving… N of M".
struct PhotoPartsPlaceholderBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    let input: PhotoPartsInput
    let isOutgoing: Bool
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.title2)
            ProgressView()
            Text("Receiving… \(input.parts.count) of \(input.count)")
                .font(.caption)
        }
        .foregroundColor(isOutgoing ? .white.opacity(0.85) : .secondary)
        .frame(width: 220, height: 160)
        .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .messageActions(title: "Photo") {
            var actions: [MessageAction] = []
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: input.anchorTxId) {
                actions.append(.explorer(url))
            }
            if let onReply { actions.append(.reply(onReply)) }
            if let onRetry { actions.append(.retry(onRetry)) }
            if let onSelect { actions.append(.select(onSelect)) }
            return actions
        }
    }
}

// MARK: - Long voice notes (multi-part)

/// The parts of one long voice note that are on this device, for its single bubble
/// (MESSAGING.md, "Long voice notes (multi-part)"). Built by `ChatDetailView` from the grouped rows.
/// The decoded parts of long voice notes and multi-part photos, per set of parts: a part's
/// content never changes once it's on chain, and the row's every redraw used to parse each part's
/// envelope and decode its bytes on the main thread. Cost-limited by the bytes held.
@MainActor
enum PartsInputMemo {
    private final class Box {
        let voice: VoiceNotePartsInput?
        let photo: PhotoPartsInput?
        init(voice: VoiceNotePartsInput? = nil, photo: PhotoPartsInput? = nil) { self.voice = voice; self.photo = photo }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private static func key(_ kind: String, _ count: Int, _ txIds: [String]) -> NSString {
        "\(kind)|\(count)|\(txIds.joined(separator: ","))" as NSString
    }

    static func voice(count: Int, txIds: [String], build: () -> VoiceNotePartsInput) -> VoiceNotePartsInput {
        let key = key("v", count, txIds)
        if let hit = cache.object(forKey: key)?.voice { return hit }
        let built = build()
        cache.setObject(Box(voice: built), forKey: key, cost: built.parts.reduce(0) { $0 + $1.data.count })
        return built
    }

    static func photo(count: Int, txIds: [String], build: () -> PhotoPartsInput) -> PhotoPartsInput {
        let key = key("p", count, txIds)
        if let hit = cache.object(forKey: key)?.photo { return hit }
        let built = build()
        cache.setObject(Box(photo: built), forKey: key, cost: built.parts.reduce(0) { $0 + $1.data.count })
        return built
    }
}

struct VoiceNotePartsInput {
    struct Piece {
        let index: Int
        let txId: String
        let data: Data
        let mimeType: String
    }
    /// How many parts the note has in all.
    let count: Int
    /// The parts present, in index order.
    let parts: [Piece]

    var isComplete: Bool { parts.count >= count }
    /// Changes whenever a part arrives.
    var signature: String { parts.map { "\($0.index):\($0.data.count)" }.joined(separator: ",") }
}

/// Plays a long voice note as one recording: every part present is decoded and joined
/// (`WebMOpusDecoder.decodePartsToPCMFile`), so the length is the total and seeking crosses parts.
private final class MultipartAudioPlaybackHelper: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @Published var isPlaying = false
    @Published var durationText: String = "--:--"
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var waveformSamples: [Float] = []

    private var player: AVAudioPlayer?
    private var playbackURL: URL?
    private var playbackSignature: String?
    private var loadedSignature: String?
    private var cachedDuration: TimeInterval?
    private var progressTimer: Timer?
    /// A seek made before playback started: where the next Play begins.
    private var pendingSeekFraction: Double?
    /// Bumped by every stop: a decode still running for an older Play doesn't start playing.
    private var playGeneration = 0

    private static let activeHelpers = NSHashTable<MultipartAudioPlaybackHelper>.weakObjects()

    static func stopAllPlayback() {
        for helper in activeHelpers.allObjects {
            helper.stop()
        }
        activeHelpers.removeAllObjects()
    }

    deinit {
        progressTimer?.invalidate()
        player?.stop()
        // A bubble dropped while playing: give the session back.
        VoicePlaybackCoordinator.shared.didStop(self)
        if let url = playbackURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Length and waveform of the parts present; again whenever a part arrives (unless playing,
    /// which picks the new parts up on the next Play). From `VoiceNoteInfoCache` when these parts
    /// were read before, otherwise decoded once off the main thread and cached.
    func preload(_ input: VoiceNotePartsInput, txId: String) {
        let signature = input.signature
        guard loadedSignature != signature, !isPlaying else { return }
        loadedSignature = signature
        let key = VoiceNoteInfoCache.key(txId: txId, input: input)
        if let key, let info = VoiceNoteInfoCache.info(forKey: key) {
            cachedDuration = info.duration
            durationText = Self.formatted(info.duration)
            waveformSamples = info.waveform
            isLoading = false
            return
        }
        isLoading = cachedDuration == nil
        let datas = input.parts.map(\.data)
        Task.detached(priority: .utility) { [weak self] in
            let decoded = try? WebMOpusDecoder.decodePartsToPCMFile(parts: datas)
            if let url = decoded?.url { try? FileManager.default.removeItem(at: url) }
            let info = decoded.map { VoiceNoteInfoCache.Info(duration: $0.duration, waveform: $0.waveform) }
            if let info, let key { VoiceNoteInfoCache.store(info, forKey: key) }
            await MainActor.run {
                guard let self, self.loadedSignature == signature else { return }
                if let info {
                    self.cachedDuration = info.duration
                    self.durationText = Self.formatted(info.duration)
                    self.waveformSamples = info.waveform
                } else {
                    self.durationText = "--:--"
                    self.waveformSamples = Array(repeating: 0.3, count: 40)
                }
                self.isLoading = false
            }
        }
    }

    func togglePlayback(_ input: VoiceNotePartsInput) {
        if isPlaying {
            pause()
            return
        }
        // Paused on the same parts: carry on from there.
        if let player, playbackSignature == input.signature {
            if let fraction = pendingSeekFraction {
                player.currentTime = fraction * player.duration
                pendingSeekFraction = nil
            }
            start(player)
            return
        }
        let seek = pendingSeekFraction
        stop()
        pendingSeekFraction = seek
        isLoading = true
        // Listed while decoding too, so leaving the thread cancels a Play still loading.
        Self.activeHelpers.add(self)
        let generation = playGeneration
        let signature = input.signature
        let datas = input.parts.map(\.data)
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = try? WebMOpusDecoder.decodePartsToPCMFile(parts: datas)
            await MainActor.run {
                // Stopped meanwhile (the thread closed): don't start playing behind it.
                guard let self, self.playGeneration == generation else {
                    if let url = decoded?.url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.isLoading = false
                guard let decoded else { return }
                do {
                    let player = try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
                    player.delegate = self
                    player.prepareToPlay()
                    self.playbackURL = decoded.url
                    self.playbackSignature = signature
                    self.player = player
                    self.cachedDuration = decoded.duration
                    self.waveformSamples = decoded.waveform
                    if let fraction = self.pendingSeekFraction {
                        player.currentTime = fraction * player.duration
                        self.pendingSeekFraction = nil
                    }
                    self.start(player)
                } catch {
                    try? FileManager.default.removeItem(at: decoded.url)
                }
            }
        }
    }

    /// The scrubber: 0...1 across the whole note.
    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        progress = clamped
        if let player {
            player.currentTime = clamped * player.duration
            durationText = Self.formatted(player.currentTime)
        } else {
            pendingSeekFraction = clamped
            if let duration = cachedDuration { durationText = Self.formatted(clamped * duration) }
        }
    }

    /// Plays through `VoicePlaybackCoordinator`: any other note stops, and the session is given
    /// back when this one pauses, stops or ends.
    private func start(_ player: AVAudioPlayer) {
        guard VoicePlaybackCoordinator.shared.willStart(self, stop: { [weak self] in self?.pause() }) else { return }
        guard player.play() else {
            stop()
            return
        }
        isPlaying = true
        Self.activeHelpers.add(self)
        startProgressTimer()
    }

    private func pause() {
        player?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        VoicePlaybackCoordinator.shared.didStop(self)
    }

    func stop() {
        playGeneration += 1
        isLoading = false
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        playbackSignature = nil
        if let url = playbackURL {
            try? FileManager.default.removeItem(at: url)
            playbackURL = nil
        }
        isPlaying = false
        progress = 0
        pendingSeekFraction = nil
        if let duration = cachedDuration {
            durationText = Self.formatted(duration)
        }
        VoicePlaybackCoordinator.shared.didStop(self)
    }

    /// 10 Hz, as the one-part bubble.
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            if player.duration > 0 {
                self.progress = player.currentTime / player.duration
            }
            self.durationText = Self.formatted(player.currentTime)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.stop()
        }
    }

    private static func formatted(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "--:--" }
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// The one bubble of a long voice note: total length, one scrubber across all parts, and while
/// parts are still on their way, "Receiving… 7 of 12".
struct LazyMultipartAudioBubble: View {
    let input: VoiceNotePartsInput
    let isOutgoing: Bool
    let txId: String
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil
    @StateObject private var helper = MultipartAudioPlaybackHelper()

    var body: some View {
        MultipartAudioBubble(
            helper: helper,
            input: input,
            isOutgoing: isOutgoing,
            txId: txId,
            onRetry: onRetry,
            onReply: onReply,
            onSelect: onSelect
        )
    }
}

private struct MultipartAudioBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject var helper: MultipartAudioPlaybackHelper
    let input: VoiceNotePartsInput
    let isOutgoing: Bool
    let txId: String
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil
    @State private var showShareSheet = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                helper.togglePlayback(input)
            } label: {
                if helper.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: helper.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.scaled(size: 32))
                }
            }
            .disabled(helper.isLoading)

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(
                    samples: helper.waveformSamples,
                    progress: helper.progress,
                    isOutgoing: isOutgoing
                )
                .frame(height: 24)
                .overlay {
                    // One scrubber across every part.
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard geometry.size.width > 0 else { return }
                                        helper.seek(toFraction: value.location.x / geometry.size.width)
                                    }
                            )
                    }
                }

                Text(helper.durationText)
                    .font(.caption)
                    .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
                if !input.isComplete {
                    Text("Receiving… \(input.parts.count) of \(input.count)")
                        .font(.caption2)
                        .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
        .foregroundColor(isOutgoing ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .messageActions(title: "Voice Message") {
            var actions: [MessageAction] = [
                MessageAction(title: "Save Audio", subtitle: "Saves or shares the recording as a file.", systemImage: "square.and.arrow.down") {
                    showShareSheet = true
                }
            ]
            // The first part's transaction: what reply, react and the explorer point at.
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                actions.append(.explorer(url))
            }
            if let onReply { actions.append(.reply(onReply)) }
            if let onRetry { actions.append(.retry(onRetry)) }
            if let onSelect { actions.append(.select(onSelect)) }
            return actions
        }
        .tint(.accentColor)
        .sheet(isPresented: $showShareSheet) {
            // Each part is a complete WebM file: they go out as the files they are, in order.
            MultipartAudioShareSheet(pieces: input.parts, count: input.count)
        }
        .onAppear {
            helper.preload(input, txId: txId)
        }
        .onChange(of: input.signature) { _ in
            helper.preload(input, txId: txId)
        }
    }
}

private struct MultipartAudioShareSheet: UIViewControllerRepresentable {
    let pieces: [VoiceNotePartsInput.Piece]
    let count: Int

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kachat-voice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for piece in pieces {
            // Our own name pattern only, never the sender's: "voice-2of12.webm".
            let url = folder.appendingPathComponent("voice-\(piece.index)of\(count).webm")
            if (try? piece.data.write(to: url)) != nil { urls.append(url) }
        }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: folder)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Not private: public chat voice notes draw the same one (`PublicChatVoiceNoteBubble`).
struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let isOutgoing: Bool

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: barSpacing) {
                let displaySamples = samples.isEmpty ? Array(repeating: Float(0.3), count: 40) : samples
                ForEach(0..<displaySamples.count, id: \.self) { index in
                    let amplitude = CGFloat(displaySamples[index])
                    let barProgress = Double(index) / Double(displaySamples.count)
                    let isPlayed = barProgress < progress

                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barColor(isPlayed: isPlayed))
                        .frame(width: barWidth, height: max(4, amplitude * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func barColor(isPlayed: Bool) -> Color {
        if isOutgoing {
            return isPlayed ? .white : .white.opacity(0.5)
        } else {
            return isPlayed ? kaspaBubbleColor : .gray.opacity(0.4)
        }
    }
}

private struct AudioShareSheet: UIViewControllerRepresentable {
    let data: Data
    let fileName: String
    let mimeType: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Create temp file for sharing
        let lowercasedMime = mimeType.lowercased()
        let fileExtension: String
        if lowercasedMime.contains("webm") {
            fileExtension = "webm"
        } else if lowercasedMime.contains("ogg") || lowercasedMime.contains("opus") {
            fileExtension = "ogg"
        } else {
            fileExtension = "m4a"
        }
        // The name comes from the sender: only its last path component, with no separators, so
        // "../Library/x" can't reach outside the temporary folder.
        let lastComponent = URL(fileURLWithPath: fileName).lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (lastComponent.isEmpty || lastComponent == "." || lastComponent == "..") ? "voice" : lastComponent
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.hasSuffix(".\(fileExtension)") ? safeName : "\(safeName).\(fileExtension)")

        try? data.write(to: tempURL)

        let controller = UIActivityViewController(
            activityItems: [tempURL],
            applicationActivities: nil
        )
        // The copy is for the share sheet only; it used to stay in tmp until iOS purged it.
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: tempURL)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#if canImport(YbridOpus) || OPUS_BRIDGE || OPUS_CATALYST
/// The most a voice note decodes to: the longest one any composer records, `nextcloudVoiceSeconds`
/// (an on-chain note is far shorter). A crafted file's packet count would otherwise set the size
/// of the buffer reserved below.
private func maxDecodedVoiceSamples(sampleRate: Double, channels: Int) -> Int {
    Int(sampleRate * ComposerMediaLimits.nextcloudVoiceSeconds) * channels
}

private enum WebMOpusDecodeError: LocalizedError {
    case invalidWebM(String)
    case missingOpusHead
    case invalidOpusHead
    case decoderInit(Int32)
    case decodeFailed(Int32)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidWebM(let details):
            return "Invalid WebM data. \(details)"
        case .missingOpusHead:
            return "Missing Opus header."
        case .invalidOpusHead:
            return "Invalid Opus header."
        case .decoderInit(let code):
            return "Opus decoder init failed (\(code))."
        case .decodeFailed(let code):
            return "Opus decode failed (\(code))."
        case .noAudio:
            return "No audio data."
        }
    }
}

struct WebMOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        let parsed = try parseWebM(data)
        let head = try parseOpusHead(parsed.opusHead)
        let packets = parsed.packets
        if packets.isEmpty {
            throw WebMOpusDecodeError.noAudio
        }

        let sampleRate = normalizedSampleRate(head.sampleRate)
        var opusError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(head.channels), &opusError) else {
            throw WebMOpusDecodeError.decoderInit(opusError)
        }
        defer { opus_decoder_destroy(decoder) }

        let maxFrameSize = Int(sampleRate / 1000.0 * 120.0)
        let maxSamples = maxDecodedVoiceSamples(sampleRate: sampleRate, channels: head.channels)
        var samples = [Float]()
        samples.reserveCapacity(min(packets.count * maxFrameSize * head.channels, maxSamples))

        var tempBuffer = [Float](repeating: 0, count: maxFrameSize * head.channels)
        for packet in packets {
            let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OPUS_BAD_ARG
                }
                return opus_decode_float(
                    decoder,
                    base,
                    Int32(buffer.count),
                    &tempBuffer,
                    Int32(maxFrameSize),
                    0
                )
            }
            if decodedFrames < 0 {
                throw WebMOpusDecodeError.decodeFailed(decodedFrames)
            }
            let frameCount = Int(decodedFrames)
            let total = frameCount * head.channels
            guard samples.count + total <= maxSamples else {
                throw WebMOpusDecodeError.invalidWebM("Too long.")
            }
            samples.append(contentsOf: tempBuffer.prefix(total))
        }

        let skipFrames = Int(Double(head.preSkip) * sampleRate / 48_000.0)
        if skipFrames > 0 && samples.count >= skipFrames * head.channels {
            samples.removeFirst(skipFrames * head.channels)
        }

        let duration = TimeInterval(Double(samples.count / head.channels) / sampleRate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(head.channels),
                                         interleaved: false) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to build output format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count / head.channels)) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count / head.channels)
        if let channels = buffer.floatChannelData {
            for channel in 0..<head.channels {
                var writeIndex = 0
                let channelPointer = channels[channel]
                for frameIndex in stride(from: channel, to: samples.count, by: head.channels) {
                    channelPointer[writeIndex] = samples[frameIndex]
                    writeIndex += 1
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL,
                                        settings: format.settings,
                                        commonFormat: format.commonFormat,
                                        interleaved: format.isInterleaved)
        try audioFile.write(from: buffer)

        return DecodedAudio(url: outputURL, duration: duration)
    }

    struct DecodedParts {
        let url: URL
        let duration: TimeInterval
        /// Peaks across the whole note, `waveformBars` of them, 0.1...1.
        let waveform: [Float]
        /// How many of the given parts decoded.
        let decodedParts: Int
    }

    /// The parts of a long voice note (MESSAGING.md, "Long voice notes"), in the order given,
    /// as ONE mono PCM file: each part is decoded on its own, its pre-skip removed and cut to its
    /// Info Duration (the encoder feeds each part a little of the next one to cover the codec's
    /// look-ahead), so the joins are gapless and one player seeks across the whole note.
    ///
    /// Decoded at 24 kHz: the parts are narrowband-to-wideband SILK, so nothing audible is lost,
    /// and five minutes stay ~29 MB of samples instead of ~58. A part that doesn't decode is left
    /// out; with none decoding this throws.
    static func decodePartsToPCMFile(parts: [Data], waveformBars: Int = 40) throws -> DecodedParts {
        guard !parts.isEmpty else { throw WebMOpusDecodeError.noAudio }
        let outputRate = 24_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: outputRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to build output format.")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")
        var audioFile: AVAudioFile? = try AVAudioFile(forWriting: outputURL,
                                                      settings: format.settings,
                                                      commonFormat: format.commonFormat,
                                                      interleaved: format.isInterleaved)
        var totalFrames = 0
        var decodedParts = 0
        // Peaks per 0.1 s across the note, folded into `waveformBars` at the end.
        let binFrames = Int(outputRate / 10)
        var bins: [Float] = []
        var binPeak: Float = 0
        var binFill = 0
        // A part is at most 14.5 s (25 s accepted); a crafted file can't grow one past this.
        let maxPartFrames = Int(outputRate * (VoicePartTag.maxPartSeconds + 1))
        let maxFrameSize = Int(outputRate / 1000.0 * 120.0)

        for part in parts.prefix(VoicePartTag.maxParts) {
            guard let parsed = try? parseWebM(part),
                  !parsed.packets.isEmpty,
                  let head = try? parseOpusHead(parsed.opusHead) else { continue }
            let channels = max(1, min(head.channels, 2))
            var opusError: Int32 = 0
            guard let decoder = opus_decoder_create(Int32(outputRate), Int32(channels), &opusError) else { continue }
            defer { opus_decoder_destroy(decoder) }

            var mono = [Float]()
            mono.reserveCapacity(min(parsed.packets.count * maxFrameSize, maxPartFrames))
            var tempBuffer = [Float](repeating: 0, count: maxFrameSize * channels)
            var failed = false
            for packet in parsed.packets {
                let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                    guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return OPUS_BAD_ARG
                    }
                    return opus_decode_float(decoder, base, Int32(buffer.count), &tempBuffer, Int32(maxFrameSize), 0)
                }
                guard decodedFrames >= 0 else { failed = true; break }
                let frames = Int(decodedFrames)
                guard mono.count + frames <= maxPartFrames else { break }
                if channels == 1 {
                    mono.append(contentsOf: tempBuffer.prefix(frames))
                } else {
                    for frame in 0..<frames {
                        mono.append((tempBuffer[frame * 2] + tempBuffer[frame * 2 + 1]) / 2)
                    }
                }
            }
            if failed || mono.isEmpty { continue }

            let skip = Int(Double(head.preSkip) * outputRate / 48_000.0)
            if skip > 0 && mono.count > skip { mono.removeFirst(skip) }
            if let durationMs = parsed.durationMs {
                // The header comes from the sender. Clamp before converting so an absurd value
                // (e.g. 1e300) can't trap Int() - no genuine part runs longer than the cap.
                let cappedMs = min(durationMs, (VoicePartTag.maxPartSeconds + 1) * 1000.0)
                let wanted = Int((cappedMs / 1000.0 * outputRate).rounded())
                if wanted > 0 && wanted < mono.count { mono.removeLast(mono.count - wanted) }
            }

            for sample in mono {
                binPeak = max(binPeak, abs(sample))
                binFill += 1
                if binFill == binFrames {
                    bins.append(binPeak)
                    binPeak = 0
                    binFill = 0
                }
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(mono.count)
            mono.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base, count: mono.count)
                }
            }
            try audioFile?.write(from: buffer)
            totalFrames += mono.count
            decodedParts += 1
        }
        audioFile = nil // closes the file
        if binFill > 0 { bins.append(binPeak) }

        guard decodedParts > 0, totalFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw WebMOpusDecodeError.noAudio
        }

        let bars = max(1, waveformBars)
        var waveform: [Float] = []
        if bins.isEmpty {
            waveform = Array(repeating: 0.3, count: bars)
        } else {
            for bar in 0..<bars {
                let start = min(bar * bins.count / bars, bins.count - 1)
                let end = min(max(start + 1, (bar + 1) * bins.count / bars), bins.count)
                let peak = bins[start..<end].max() ?? 0
                waveform.append(min(1.0, max(0.1, peak * 2)))
            }
        }
        return DecodedParts(
            url: outputURL,
            duration: TimeInterval(Double(totalFrames) / outputRate),
            waveform: waveform,
            decodedParts: decodedParts
        )
    }

    private struct OpusHead {
        let channels: Int
        let preSkip: Int
        let sampleRate: Double
    }

    /// A voice message's length without decoding it: the samples its Opus packets carry (read from
    /// each packet's TOC byte), less the pre-skip, which is what `decodeToPCMFile` would report.
    /// Nil when the file doesn't parse. Cheap enough for a bubble to call as it appears.
    static func duration(of data: Data) -> TimeInterval? {
        guard let parsed = try? parseWebM(data), !parsed.packets.isEmpty,
              let head = try? parseOpusHead(parsed.opusHead) else { return nil }
        let samples = parsed.packets.reduce(0) { $0 + opusPacketSamples48k($1) }
        let frames = max(0, samples - head.preSkip)
        return min(Double(frames) / 48_000.0, ComposerMediaLimits.nextcloudVoiceSeconds)
    }

    /// A long voice note's length without decoding it, as `decodePartsToPCMFile` would report it:
    /// each part's packet samples less its pre-skip, cut to its Info Duration, summed. Nil when
    /// no part parses.
    static func duration(ofParts parts: [Data]) -> TimeInterval? {
        var total: TimeInterval = 0
        var counted = 0
        for part in parts.prefix(VoicePartTag.maxParts) {
            guard let parsed = try? parseWebM(part), !parsed.packets.isEmpty,
                  let head = try? parseOpusHead(parsed.opusHead) else { continue }
            let samples = parsed.packets.reduce(0) { $0 + opusPacketSamples48k($1) }
            var seconds = Double(max(0, samples - head.preSkip)) / 48_000.0
            if let durationMs = parsed.durationMs, durationMs.isFinite, durationMs > 0 {
                seconds = min(seconds, durationMs / 1000.0)
            }
            seconds = min(seconds, VoicePartTag.maxPartSeconds + 1)
            guard seconds > 0 else { continue }
            total += seconds
            counted += 1
        }
        return counted > 0 ? total : nil
    }

    /// How many 48 kHz samples one Opus packet decodes to, from its TOC byte (RFC 6716 3.1).
    /// 0 for an empty or malformed packet.
    private static func opusPacketSamples48k(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frameSize: Int
        if config < 12 {
            frameSize = [480, 960, 1920, 2880][config & 3]      // SILK: 10, 20, 40, 60 ms
        } else if config < 16 {
            frameSize = [480, 960][config & 1]                  // Hybrid: 10, 20 ms
        } else {
            frameSize = [120, 240, 480, 960][config & 3]        // CELT: 2.5, 5, 10, 20 ms
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return 0 }
            frames = Int(packet[packet.index(after: packet.startIndex)] & 0x3F)
        }
        // A packet holds at most 120 ms.
        return min(frames * frameSize, 5_760)
    }

    private struct ParsedWebM {
        let opusHead: Data
        let packets: [Data]
        /// Segment Info's Duration in ms (TimecodeScale 1 ms, what our encoder writes), if any.
        let durationMs: Double?
    }

    private static func parseWebM(_ data: Data) throws -> ParsedWebM {
        var opusHead: Data?
        var packets: [Data] = []
        var durationMs: Double?

        let containerIDs: Set<UInt64> = [
            0x18538067, // Segment
            0x1549A966, // Info
            0x1654AE6B, // Tracks
            0xAE,       // TrackEntry
            0x1F43B675, // Cluster
            0xA0        // BlockGroup - real WebM muxers (e.g. Android's AOSP MediaRecorder/
                        // MediaMuxer) commonly wrap an Opus frame in BlockGroup > Block rather
                        // than a bare SimpleBlock, unlike this app's own hand-rolled encoder.
        ]

        // Real files nest Segment > Cluster > BlockGroup > Block. Each container recurses, so a
        // crafted one nested thousands deep overflowed the stack just by being rendered.
        let maxContainerDepth = 16

        func parseElements(in range: Range<Int>, depth: Int) throws {
            guard depth <= maxContainerDepth else {
                throw WebMOpusDecodeError.invalidWebM("Nested too deeply.")
            }
            var offset = range.lowerBound
            while offset < range.upperBound {
                let (id, idLen, _) = try readVInt(data, offset: offset, forSize: false)
                let sizeOffset = offset + idLen
                if sizeOffset >= range.upperBound { break }
                let (size, _, isUnknown, payloadStart) = try readElementSize(
                    data: data,
                    id: id,
                    sizeOffset: sizeOffset,
                    range: range
                )
                if payloadStart > range.upperBound { break }
                let payloadEnd: Int
                if isUnknown {
                    payloadEnd = range.upperBound
                } else {
                    let end = payloadStart + Int(size)
                    if end < payloadStart { break }
                    payloadEnd = min(end, range.upperBound)
                }

                if id == 0x63A2 {
                    opusHead = data.subdata(in: payloadStart..<payloadEnd)
                } else if id == 0x4489 {
                    durationMs = readFloat(data, range: payloadStart..<payloadEnd)
                } else if id == 0xA3 || id == 0xA1 {
                    // SimpleBlock (0xA3) or Block (0xA1, inside a BlockGroup) - both share the
                    // same track-number/timecode/flags header layout for our purposes.
                    let block = data.subdata(in: payloadStart..<payloadEnd)
                    if let packet = try parseSimpleBlock(block) {
                        packets.append(packet)
                    }
                } else if containerIDs.contains(id) {
                    try parseElements(in: payloadStart..<payloadEnd, depth: depth + 1)
                }

                if payloadEnd <= offset {
                    break
                }
                offset = payloadEnd
            }
        }

        try parseElements(in: 0..<data.count, depth: 0)

        guard let opusHead else {
            throw WebMOpusDecodeError.missingOpusHead
        }
        return ParsedWebM(opusHead: opusHead, packets: packets, durationMs: durationMs)
    }

    /// An EBML float: 4 or 8 bytes, big-endian. Nil for any other length or a non-finite value.
    private static func readFloat(_ data: Data, range: Range<Int>) -> Double? {
        let bytes = [UInt8](data[range])
        let value: Double
        if bytes.count == 8 {
            value = Double(bitPattern: bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        } else if bytes.count == 4 {
            value = Double(Float(bitPattern: bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }))
        } else {
            return nil
        }
        return value.isFinite && value > 0 ? value : nil
    }

    private static func parseSimpleBlock(_ data: Data) throws -> Data? {
        var offset = 0
        // Track number isn't validated against a fixed value (e.g. this app's own encoder
        // always uses track 1) - these files only ever contain a single audio track, and other
        // real-world muxers (Android's AOSP MediaRecorder among them) aren't guaranteed to number
        // it the same way, so any track number here is accepted.
        let (_, trackLen) = try readVIntValue(data, offset: offset)
        offset += trackLen
        guard offset + 3 <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Short SimpleBlock.")
        }
        let _ = Int16(bitPattern: UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
        offset += 2
        let flags = data[offset]
        offset += 1

        let lacing = (flags >> 1) & 0x03
        if lacing != 0 {
            // Skip rather than abort the whole file - one oddly-laced block shouldn't lose every
            // other valid packet already parsed.
            return nil
        }
        guard offset <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Short SimpleBlock payload.")
        }
        return data.subdata(in: offset..<data.count)
    }

    private static func readElementSize(
        data: Data,
        id: UInt64,
        sizeOffset: Int,
        range: Range<Int>
    ) throws -> (size: UInt64, sizeLen: Int, isUnknown: Bool, payloadStart: Int) {
        if id == 0x18538067, sizeOffset + 8 <= range.upperBound {
            let candidate = data[sizeOffset..<(sizeOffset + 8)]
            if candidate.allSatisfy({ $0 == 0xFF }) {
                return (0, 8, true, sizeOffset + 8)
            }
        }
        let (size, sizeLen, isUnknown) = try readVInt(data, offset: sizeOffset, forSize: true)
        return (size, sizeLen, isUnknown, sizeOffset + sizeLen)
    }

    private static func parseOpusHead(_ data: Data) throws -> OpusHead {
        guard data.count >= 19, data.starts(with: Array("OpusHead".utf8)) else {
            throw WebMOpusDecodeError.invalidOpusHead
        }
        let channels = Int(data[9])
        let preSkip = Int(readUInt16LE(data, offset: 10))
        let sampleRate = Double(readUInt32LE(data, offset: 12))
        return OpusHead(channels: max(1, channels), preSkip: preSkip, sampleRate: sampleRate)
    }

    private static func readVInt(_ data: Data, offset: Int, forSize: Bool) throws -> (value: UInt64, length: Int, isUnknown: Bool) {
        guard offset < data.count else {
            throw WebMOpusDecodeError.invalidWebM("Unexpected end of data.")
        }
        let first = data[offset]
        var mask: UInt8 = 0x80
        var length = 1
        while length <= 8 && (first & mask) == 0 {
            mask >>= 1
            length += 1
        }
        guard length <= 8 else {
            throw WebMOpusDecodeError.invalidWebM("Invalid VINT length.")
        }
        guard offset + length <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Truncated VINT.")
        }

        var value: UInt64
        if forSize {
            let leadingBit = mask
            value = UInt64(first & (leadingBit - 1))
        } else {
            value = UInt64(first)
        }
        if length > 1 {
            for index in 1..<length {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }

        if forSize {
            let maxValue = (UInt64(1) << (7 * length)) - 1
            let isUnknown = value == maxValue
            return (value, length, isUnknown)
        }
        return (value, length, false)
    }

    private static func readVIntValue(_ data: Data, offset: Int) throws -> (value: UInt64, length: Int) {
        let (value, length, _) = try readVInt(data, offset: offset, forSize: true)
        return (value, length)
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        switch value {
        case 8_000, 12_000, 16_000, 24_000, 48_000:
            return value
        default:
            return 48_000
        }
    }
}

private enum OggOpusDecodeError: LocalizedError {
    case invalidOgg(String)
    case invalidOpusHead
    case decoderInit(Int32)
    case decodeFailed(Int32)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidOgg(let details):
            return "Invalid Ogg data. \(details)"
        case .invalidOpusHead:
            return "Invalid Opus header."
        case .decoderInit(let code):
            return "Opus decoder init failed (\(code))."
        case .decodeFailed(let code):
            return "Opus decode failed (\(code))."
        case .noAudio:
            return "No audio data."
        }
    }
}

private struct OggOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        let packets = try extractPackets(from: data)
        guard packets.count >= 2 else {
            throw OggOpusDecodeError.invalidOgg("Missing Opus header.")
        }
        guard packets[0].starts(with: Array("OpusHead".utf8)) else {
            throw OggOpusDecodeError.invalidOpusHead
        }
        let head = try parseOpusHead(packets[0])
        let audioPackets = packets.dropFirst(2)
        if audioPackets.isEmpty {
            throw OggOpusDecodeError.noAudio
        }

        let sampleRate = normalizedSampleRate(head.sampleRate)
        var opusError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(head.channels), &opusError) else {
            throw OggOpusDecodeError.decoderInit(opusError)
        }
        defer { opus_decoder_destroy(decoder) }

        let maxFrameSize = Int(sampleRate / 1000.0 * 120.0)
        let maxSamples = maxDecodedVoiceSamples(sampleRate: sampleRate, channels: head.channels)
        var samples = [Float]()
        samples.reserveCapacity(min(audioPackets.count * maxFrameSize * head.channels, maxSamples))

        var tempBuffer = [Float](repeating: 0, count: maxFrameSize * head.channels)
        for packet in audioPackets {
            let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OPUS_BAD_ARG
                }
                return opus_decode_float(
                    decoder,
                    base,
                    Int32(buffer.count),
                    &tempBuffer,
                    Int32(maxFrameSize),
                    0
                )
            }
            if decodedFrames < 0 {
                throw OggOpusDecodeError.decodeFailed(decodedFrames)
            }
            let frameCount = Int(decodedFrames)
            let total = frameCount * head.channels
            guard samples.count + total <= maxSamples else {
                throw OggOpusDecodeError.invalidOgg("Too long.")
            }
            samples.append(contentsOf: tempBuffer.prefix(total))
        }

        let skipFrames = Int(Double(head.preSkip) * sampleRate / 48_000.0)
        if skipFrames > 0 && samples.count >= skipFrames * head.channels {
            samples.removeFirst(skipFrames * head.channels)
        }

        let duration = TimeInterval(Double(samples.count / head.channels) / sampleRate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(head.channels),
                                         interleaved: false) else {
            throw OggOpusDecodeError.invalidOgg("Failed to build output format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count / head.channels)) else {
            throw OggOpusDecodeError.invalidOgg("Failed to allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count / head.channels)
        if let channels = buffer.floatChannelData {
            for channel in 0..<head.channels {
                var writeIndex = 0
                let channelPointer = channels[channel]
                for frameIndex in stride(from: channel, to: samples.count, by: head.channels) {
                    channelPointer[writeIndex] = samples[frameIndex]
                    writeIndex += 1
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL,
                                        settings: format.settings,
                                        commonFormat: format.commonFormat,
                                        interleaved: format.isInterleaved)
        try audioFile.write(from: buffer)

        return DecodedAudio(url: outputURL, duration: duration)
    }

    private struct OpusHead {
        let channels: Int
        let preSkip: Int
        let sampleRate: Double
    }

    private static func parseOpusHead(_ data: Data) throws -> OpusHead {
        guard data.count >= 19 else {
            throw OggOpusDecodeError.invalidOpusHead
        }
        let channels = Int(data[9])
        let preSkip = Int(readUInt16LE(data, offset: 10))
        let sampleRate = Double(readUInt32LE(data, offset: 12))
        return OpusHead(channels: max(1, channels), preSkip: preSkip, sampleRate: sampleRate)
    }

    private static func extractPackets(from data: Data) throws -> [Data] {
        var packets: [Data] = []
        var current = Data()
        var offset = 0

        while offset + 27 <= data.count {
            guard data[offset..<(offset + 4)] == Data([0x4f, 0x67, 0x67, 0x53]) else {
                throw OggOpusDecodeError.invalidOgg("Missing OggS at \(offset).")
            }
            let pageSegments = Int(data[offset + 26])
            let headerSize = 27 + pageSegments
            guard offset + headerSize <= data.count else {
                throw OggOpusDecodeError.invalidOgg("Short header.")
            }
            let segmentTable = data[(offset + 27)..<(offset + 27 + pageSegments)]
            let bodySize = segmentTable.reduce(0) { $0 + Int($1) }
            let bodyStart = offset + headerSize
            guard bodyStart + bodySize <= data.count else {
                throw OggOpusDecodeError.invalidOgg("Short body.")
            }
            var cursor = bodyStart
            for seg in segmentTable {
                let length = Int(seg)
                if length > 0 {
                    current.append(data[cursor..<(cursor + length)])
                }
                cursor += length
                if seg < 255 {
                    packets.append(current)
                    current = Data()
                }
            }
            offset = bodyStart + bodySize
        }
        return packets
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        switch value {
        case 8_000, 12_000, 16_000, 24_000, 48_000:
            return value
        default:
            return 48_000
        }
    }
}
#else
private enum WebMOpusDecodeError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio decoding is not supported on this platform."
    }
}

private enum OggOpusDecodeError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio decoding is not supported on this platform."
    }
}

struct WebMOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        throw WebMOpusDecodeError.unsupportedPlatform
    }

    struct DecodedParts {
        let url: URL
        let duration: TimeInterval
        let waveform: [Float]
        let decodedParts: Int
    }

    static func decodePartsToPCMFile(parts: [Data], waveformBars: Int = 40) throws -> DecodedParts {
        throw WebMOpusDecodeError.unsupportedPlatform
    }

    static func duration(of data: Data) -> TimeInterval? { nil }

    static func duration(ofParts parts: [Data]) -> TimeInterval? { nil }
}

private struct OggOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        throw OggOpusDecodeError.unsupportedPlatform
    }
}
#endif

private struct ImagePreviewView: View {
    let image: UIImage
    let title: String
    let sharePayload: MessageImageSharePayload
    /// A GIF within the play limits, checked before this opens (`previewImagePayload`).
    let animates: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false
    @State private var dragOffset: CGFloat = 0
    /// A GIF plays here too.
    private var animatedData: Data? {
        animates ? sharePayload.data : nil
    }

    /// Past this translation (or a fast-enough flick, see `onEnded`), the swipe commits to
    /// dismissing instead of springing back.
    private let dismissThreshold: CGFloat = 120

    var body: some View {
        NavigationStack {
            ZoomableImageView(image: image, isZoomed: $isZoomed, animatedData: animatedData)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(
                        item: ShareableImage(payload: sharePayload),
                        preview: SharePreview(title, image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .offset(y: dragOffset)
        .opacity(1 - min(abs(dragOffset) / 500, 0.4))
        // `simultaneousGesture` rather than `gesture` so this never steals the scroll view's own
        // pinch-zoom/pan recognizers; the `!isZoomed` guards below additionally make sure a swipe
        // only dismisses when the image is at its default scale, matching how Photos/Messages
        // handle swipe-to-dismiss on a zoomable image.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard !isZoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    guard !isZoomed else { return }
                    if abs(dragOffset) > dismissThreshold || abs(value.predictedEndTranslation.height) > dismissThreshold * 2 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

}

/// Pinch-zoomable full-screen image host. Internal (not private) because the Nextcloud media
/// viewer (`LinkPreviewCardView.swift`) reuses it for remote photos — same zoom behavior as
/// the local chat-photo preview.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    /// An animated GIF's bytes: played in place of `image` (its first frame).
    var animatedData: Data? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4.0
        scrollView.minimumZoomScale = 1.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .black

        // Plays a GIF only while in a window, as the bubble's does.
        let imageView = AnimatedGIFImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.imageView = imageView
        if let animatedData {
            imageView.animate(animatedData)
        }
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.imageView?.stopGIF(forget: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: AnimatedGIFImageView?
        @Binding var isZoomed: Bool

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if isZoomed != zoomed {
                isZoomed = zoomed
            }
        }
    }
}

private struct ShareableImage: Transferable {
    let payload: MessageImageSharePayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try item.payload.writeTemporaryFile())
        }
    }
}

/// Small, non-interactive board render for the in-chat live game card. The full-screen
/// `ChessGameView` has its own interactive board renderer (tap-to-select, highlights) rather than
/// reusing this - different enough concerns (static thumbnail vs. tappable squares) that sharing
/// the layout code wasn't worth the added complexity.
private extension View {
    /// Long-press "View in Explorer" for any chess bubble (invite/live card/log entry) - mirrors
    /// `messageTextBubble`'s own long-press sheet, scoped down to just the one action since a
    /// chess envelope's own JSON isn't meaningful to offer as "Copy Message".
    func chessExplorerMenu(txId: String, settingsViewModel: SettingsViewModel, onRetry: (() -> Void)? = nil) -> some View {
        messageActions(title: "Chess") {
            var actions: [MessageAction] = []
            if let onRetry { actions.append(.retry(onRetry)) }
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                actions.append(.explorer(url))
            }
            return actions
        }
    }
}

struct ChessBoardThumbnail: View {
    let board: ChessBoard
    var size: CGFloat = 160

    /// Classic wood-tone board colors (matches chess.com/lichess's default theme) - shared with
    /// the full-screen board in ChessGameView.
    static let lightSquareColor = Color(red: 0.937, green: 0.851, blue: 0.706) // #EFD9B4
    static let darkSquareColor = Color(red: 0.710, green: 0.533, blue: 0.388)  // #B58863

    var body: some View {
        let squareSize = size / 8
        VStack(spacing: 0) {
            ForEach((0..<8).reversed(), id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { file in
                        let isLight = !(file + rank).isMultiple(of: 2)
                        ZStack {
                            Rectangle().fill(isLight ? Self.lightSquareColor : Self.darkSquareColor)
                            if let piece = board.piece(at: ChessSquare(file: file, rank: rank)) {
                                ChessPieceGlyphView(piece: piece, fontSize: squareSize * 0.72)
                            }
                        }
                        .frame(width: squareSize, height: squareSize)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Renders a single chess piece glyph with an explicit white/black fill plus a crisp
/// contrasting outline (four offset copies of the glyph drawn behind the fill, a standard
/// lightweight text-stroke trick), rather than relying on the bare Unicode glyph's
/// outline-vs-filled shape alone to distinguish sides - at typical board sizes that distinction
/// was too subtle to read at a glance, especially on a same-toned square.
struct ChessPieceGlyphView: View {
    let piece: ChessPiece
    var fontSize: CGFloat

    private var fillColor: Color { piece.color == .white ? Color(white: 0.99) : Color(white: 0.07) }
    private var outlineColor: Color { piece.color == .white ? Color(white: 0.07) : Color(white: 0.99) }

    private static let outlineOffsets: [CGSize] = {
        let d: CGFloat = 0.9
        return [CGSize(width: d, height: 0), CGSize(width: -d, height: 0), CGSize(width: 0, height: d), CGSize(width: 0, height: -d)]
    }()

    private var glyphText: some View {
        Text(piece.glyph)
            .font(.scaled(size: fontSize))
            .minimumScaleFactor(0.5)
    }

    var body: some View {
        ZStack {
            ForEach(0..<Self.outlineOffsets.count, id: \.self) { index in
                glyphText
                    .foregroundColor(outlineColor)
                    .offset(Self.outlineOffsets[index])
            }
            glyphText
                .foregroundColor(fillColor)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        MessageBubbleView(message: ChatMessage(
            txId: "1",
            senderAddress: "kaspa:qr123",
            receiverAddress: "kaspa:qr456",
            content: "Hello! How are you?",
            timestamp: Date(),
            blockTime: UInt64(Date().timeIntervalSince1970),
            acceptingBlock: "abc123",
            isOutgoing: false
        ))

        MessageBubbleView(message: ChatMessage(
            txId: "2",
            senderAddress: "kaspa:qr456",
            receiverAddress: "kaspa:qr123",
            content: "I'm doing great, thanks for asking! How about you?",
            timestamp: Date(),
            blockTime: UInt64(Date().timeIntervalSince1970),
            acceptingBlock: nil,
            isOutgoing: true
        ))

        MessageBubbleView(message: ChatMessage(
            txId: "3",
            senderAddress: "kaspa:qr123",
            receiverAddress: "kaspa:qr456",
            content: "Payment received",
            timestamp: Date(),
            blockTime: UInt64(Date().timeIntervalSince1970),
            isOutgoing: false,
            messageType: .payment
        ))
    }
    .padding()
}

/// A voice note that was sent through Nextcloud: the same play button, waveform and duration
/// as an on-chain voice note, fetched from the share's `/download` endpoint on first sight and
/// kept for the bubble's life. Before that the on-chain and Nextcloud paths looked nothing
/// alike - one played inline, the other was a file card that opened a separate screen.
struct NextcloudAudioBubble: View {
    let downloadURL: URL
    let shareURL: URL
    let fileName: String
    let isOutgoing: Bool
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil

    @StateObject private var helper = AudioPlaybackHelper()
    @State private var data: Data?
    @State private var failed = false

    private var mimeType: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "ogg", "opus", "oga": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        default: return "audio/mp4"
        }
    }

    var body: some View {
        Group {
            if let data {
                AudioBubble(
                    helper: helper,
                    data: data,
                    mimeType: mimeType,
                    isOutgoing: isOutgoing,
                    fileName: fileName,
                    txId: txId,
                    onCopy: onCopy,
                    onRetry: nil,
                    onReply: onReply,
                    onSelect: onSelect
                )
            } else {
                HStack(spacing: 10) {
                    if failed {
                        Image(systemName: "exclamationmark.circle")
                            .font(.scaled(size: 32))
                    } else {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failed ? "Voice message unavailable" : "Voice message")
                            .font(.subheadline.weight(.medium))
                        Text(failed ? "Tap to retry" : "Loading\u{2026}")
                            .font(.caption)
                            .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
                .foregroundColor(isOutgoing ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture {
                    if failed {
                        failed = false
                        Task { await load() }
                    }
                }
            }
        }
        .task(id: downloadURL.absoluteString) {
            if data == nil { await load() }
        }
    }

    private func load() async {
        // Same fetcher the photo bubble uses: it sends the share link as Referer, which is
        // what Nextcloud's public download endpoint wants, and caps the size.
        if let bytes = await LinkPreviewService.shared.imageData(downloadURL, referer: shareURL, maxBytes: 30_000_000),
           !bytes.isEmpty {
            data = bytes
        } else {
            failed = true
        }
    }
}

/// A payment card's taps: one opens its details (when the host offers them), two react. With no
/// details to open it keeps the plain simultaneous double-tap it always had.
private struct PaymentCardTaps: ViewModifier {
    let onOpen: (() -> Void)?
    let onDoubleTap: () -> Void

    func body(content: Content) -> some View {
        if let onOpen {
            content
                .onTapGesture(count: 2, perform: onDoubleTap)
                .onTapGesture(perform: onOpen)
        } else {
            content
                .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleTap))
        }
    }
}

/// A payment card's "Sent" / "Received" line, which says "Sent tip" / "Received tip" for a KaPost
/// tip (`KaPostTipLedger`; the card then opens the tipped post). Looks the payment up once.
struct PaymentCardHeading: View {
    let txId: String
    let outgoing: Bool
    let canBeTip: Bool
    @ObservedObject private var tips = KaPostTipLedger.shared

    var body: some View {
        let isTip = canBeTip && tips.postId(for: txId) != nil
        Text(isTip ? (outgoing ? "Sent tip" : "Received tip") : (outgoing ? "Sent" : "Received"))
            .task(id: txId) {
                if canBeTip { tips.resolve(txId: txId) }
            }
    }
}
