import SwiftUI
import UIKit

/// Someone's win against a bot, from the Challenge button on their post: beat `bot` in fewer
/// than `moves`.
struct ChessBotChallenge: Identifiable, Equatable {
    let bot: ChessBot
    let moves: Int?
    /// The address that won.
    let by: String?

    var id: String { "\(bot.level)-\(moves ?? 0)-\(by ?? "")" }
}

/// A challenge link waiting for the Games tab, which may not be up yet (a cold start, or a link
/// opened before signing in).
@MainActor
final class ChessBotLinkRouter: ObservableObject {
    static let shared = ChessBotLinkRouter()
    @Published var challenge: ChessBotChallenge?
}

/// The two links of a bot win (KaPlay's ONLINE_CHESS.md §7): the post sharing it, written for
/// the KaPosts composer, and the challenge link in that post. KaPlay's `kachatchess://` link is
/// kept as it is, so posts from KaPlay and from KaChat read the same; in KaChat its card
/// (`KaPostBotChallengeCard`) opens the game here, not KaPlay.
enum ChessBotLinks {
    static let scheme = "kachatchess"

    /// `kachatchess://bot/<level>?name=<bot>&moves=<n>&by=<address>&game=<game id>`
    static func challengeURL(bot: ChessBot, moves: Int, by: String, gameId: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "bot"
        components.path = "/\(bot.level)"
        components.queryItems = [
            URLQueryItem(name: "name", value: bot.name),
            URLQueryItem(name: "moves", value: String(moves)),
            URLQueryItem(name: "by", value: by),
            URLQueryItem(name: "game", value: gameId)
        ]
        return components.url
    }

    /// Links come from other people's posts, so only the level has to be right; a bad `moves` or
    /// `by` just leaves that part out of the challenge.
    static func challenge(from url: URL) -> ChessBotChallenge? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "bot",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let level = Int(url.lastPathComponent),
              let bot = ChessBot.all.first(where: { $0.level == level }) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        let moves = value("moves").flatMap { Int($0) }.flatMap { (1...999).contains($0) ? $0 : nil }
        let by = value("by").flatMap { KaspaAddress.isValid($0) ? $0 : nil }
        return ChessBotChallenge(bot: bot, moves: moves, by: by)
    }

    /// Opens the KaPosts composer with the post written; the player still taps Post there.
    @MainActor
    static func shareToKaPosts(bot: ChessBot, moves: Int, gameId: String) {
        guard let address = WalletManager.shared.currentWallet?.publicAddress,
              let challenge = challengeURL(bot: bot, moves: moves, by: address, gameId: gameId) else { return }
        let boast = String(
            format: AppLocalization.string("I beat %@ (Level %lld) in %lld moves on KaChat. Think you can do it in fewer?"),
            locale: AppLocalization.locale, bot.name, bot.level, moves
        )
        KaPostsDeepLink.pendingComposeText = "\(boast)\n\n\(challenge.absoluteString)"
        NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
    }

    /// A challenge card's button in a post: the Games tab, wherever it lives, opens the bot.
    @MainActor
    static func open(_ url: URL) {
        guard let challenge = challenge(from: url) else { return }
        ChessBotLinkRouter.shared.challenge = challenge
        NotificationCenter.default.post(name: .openGames, object: nil)
    }
}

extension Notification.Name {
    /// A bot challenge to play: the Games tab (`ChessBotLinkRouter.challenge` says which).
    static let openGames = Notification.Name("openGames")
}

/// What a challenge asks, at the top of the screen it opened.
struct ChessBotChallengeBanner: View {
    let challenge: ChessBotChallenge
    @ObservedObject private var progress = ChessBotProgress.shared

    /// One whole text per case (who is known or not, moves or not, locked or not).
    private var message: String {
        let bot = challenge.bot
        let who = challenge.by.map { ContactsManager.shared.displayName(for: $0) }
        let claim: String
        switch (who, challenge.moves) {
        case let (who?, moves?):
            claim = ChessText.format("%@ beat %@ in %lld moves. Can you do it in fewer?", who, bot.name, moves)
        case let (nil, moves?):
            claim = ChessText.format("Someone beat %@ in %lld moves. Can you do it in fewer?", bot.name, moves)
        case let (who?, nil):
            claim = ChessText.format("%@ challenges you to beat %@.", who, bot.name)
        case (nil, nil):
            claim = ChessText.format("Someone challenges you to beat %@.", bot.name)
        }
        guard !progress.isUnlocked(bot) else { return claim }
        // Its own sentence after the claim, never part of it.
        return claim + " " + ChessText.format("%@ is still locked: climb the ladder to reach it.", bot.name)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.title3)
                .foregroundColor(.orange)
            Text(verbatim: message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.14)))
    }
}
