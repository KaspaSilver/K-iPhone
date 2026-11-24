import Foundation
import SwiftUI

// KaPlay's arcade on Kaspa (ARCADE.md): a finished game is stamped in the hidden `#kplay-arcade`
// room by the player's chatting address; the indexer replays each stamp and serves the boards
// (`GET /arcade/leaderboard`); a score shared to KaPost carries a `kachatarcade://` challenge.

// MARK: - The stamp

/// A finished game's stamp: plaintext broadcast JSON in `#kplay-arcade`, signed by the player's
/// address, sent once when the game ends (ARCADE.md §1).
struct ArcadeStamp: Codable, Equatable {
    var type: String = "arcade"
    var v: Int = 1
    /// "snake" or "2048".
    let game: String
    /// Game id: a lowercase UUID chosen by the player's phone.
    let g: String
    /// The game's seed, 16 hex digits.
    let seed: String
    /// The score the game reached.
    let score: Int
    /// The moves: Snake's turns ("12R 30U"), 2048's swipes ("ULDR...").
    let m: String

    static let channel = "kplay-arcade"

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// One finished game being stamped, from the game-over screen: goes on even if the screen closes.
@MainActor
final class ArcadeStampJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case sending
        case stamped
        case failed(String)
        /// It may have gone through: no Retry, which could stamp twice.
        case unconfirmed(String)
        /// A score of 0: nothing is sent.
        case notSent
    }

    let id = UUID().uuidString.lowercased()
    let game: ArcadeGame
    let score: Int
    let seed: UInt64
    let moves: String
    let playerAddress: String?
    @Published private(set) var state: State = .sending

    /// Share to KaPost from the game-over sheet. Posting, shared and unconfirmed keep Share off,
    /// so one score is never posted twice (audit 2026-11-24 #8).
    enum ShareState: Equatable {
        case none
        case posting
        case shared
        /// The post may have gone out: no second Share.
        case unconfirmed
        /// It definitely didn't go: Share is on again.
        case failed(String)
    }
    @Published var share: ShareState = .none

    init(game: ArcadeGame, score: Int, seed: UInt64, moves: String, send shouldSend: Bool = true) {
        self.game = game
        self.score = score
        self.seed = seed
        self.moves = moves
        playerAddress = WalletManager.shared.currentWallet?.publicAddress
        if shouldSend { send() } else { state = .notSent }
    }

    var stamp: ArcadeStamp {
        ArcadeStamp(game: game.rawValue, g: id, seed: ArcadeRandom.hex(seed), score: score, m: moves)
    }

    func retry() {
        guard case .failed = state else { return }
        send()
    }

    private func send() {
        guard let sender = playerAddress, WalletManager.shared.currentWallet?.publicAddress == sender else {
            state = .failed(AppLocalization.string("This game was played on another account. Sign in to it to stamp the score."))
            return
        }
        state = .sending
        let content = stamp.encoded
        Task {
            var attempt = 0
            while true {
                guard WalletManager.shared.currentWallet?.publicAddress == sender else {
                    state = .failed(AppLocalization.string("This game was played on another account. Sign in to it to stamp the score."))
                    return
                }
                do {
                    guard let txId = try await PublicChatService.shared.sendPublicChat(
                        channel: ArcadeStamp.channel, content: content, deferNoInputRetry: false,
                        expectedSender: sender
                    ) else {
                        state = .failed(AppLocalization.string("The score was not sent."))
                        return
                    }
                    // The node took it into its mempool, and Kaspa puts that in a block within a
                    // second or so: "stamped" now (owner, 2026-11-24: waiting for the REST API to
                    // index it took 8-12 s). The check below still runs, and takes it back if the
                    // chain never shows it.
                    state = .stamped
                    let record = ArcadeRecord(game: game, score: score, at: Int64(Date().timeIntervalSince1970 * 1000),
                                              gameId: id, txId: txId)
                    ArcadeProgress.shared.add(record, address: sender)
                    // Only a definite "not accepted" takes the record back; no answer keeps it
                    // and checks again later (`ArcadeProgress.recheckUnconfirmed`), since until
                    // the boards are served it is the player's only row (audit 2026-11-24 #9).
                    ArcadeProgress.shared.markUnconfirmed(record, address: sender)
                    switch await landed(txId) {
                    case .accepted:
                        ArcadeProgress.shared.confirm(gameId: id, address: sender)
                    case .notAccepted:
                        // off the board, but still checked: a slow REST API can say 404 for a
                        // while, and a later "accepted" puts it back
                        state = .unconfirmed(AppLocalization.string("Sent, but Kaspa hasn't confirmed it yet."))
                        ArcadeProgress.shared.takeBack(gameId: id, address: sender)
                    case .unanswered:
                        state = .unconfirmed(AppLocalization.string("Sent, but Kaspa hasn't confirmed it yet."))
                    }
                    return
                } catch {
                    if error is SendOutcomeUnknownError {
                        state = .unconfirmed(SendOutcomeUnknownError.message)
                        return
                    }
                    attempt += 1
                    if attempt > 5 || !PublicChatService.isRetryableSendError(error) {
                        AppLog.log("[Arcade] Stamp failed: %@", error.localizedDescription)
                        state = .failed(PublicChatService.friendlySendErrorMessage(for: error))
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
        }
    }

    /// Whether the REST API shows the stamp accepted within a minute and a half. Not accepted
    /// only when its last answer, past the window, said so; no answer is `.unanswered`.
    private func landed(_ txId: String) async -> ArcadeTransactionCheck.Answer {
        var last: ArcadeTransactionCheck.Answer = .unanswered
        for _ in 0..<45 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            last = await ArcadeTransactionCheck.lookUp(txId)
            if last == .accepted { return .accepted }
        }
        return last
    }
}

/// The REST API's word on a stamp, keeping "no answer" apart from "not accepted"
/// (`PublicChatService.isTransactionAccepted` folds both into false; audit 2026-11-24 #9).
enum ArcadeTransactionCheck {
    enum Answer: Equatable { case accepted, notAccepted, unanswered }

    static func lookUp(_ txId: String) async -> Answer {
        guard txId.count == 64, txId.allSatisfy(\.isHexDigit) else { return .unanswered }
        var base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard let url = URL(string: "\(base)/transactions/\(txId)?inputs=false&outputs=false&resolve_previous_outpoints=no") else { return .unanswered }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unanswered }
        if status == 404 { return .notAccepted }
        // in a block but not accepted yet, or anything odd: not an answer either way
        guard status == 200, data.count <= 256 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["is_accepted"] as? Bool) == true else { return .unanswered }
        return .accepted
    }
}

// MARK: - Your own scores

struct ArcadeRecord: Codable, Equatable {
    let game: ArcadeGame
    let score: Int
    /// When it was stamped (ms).
    let at: Int64
    let gameId: String
    let txId: String?
}

/// The account's stamped scores on this phone, so its own best shows on the board at once.
@MainActor
final class ArcadeProgress: ObservableObject {
    static let shared = ArcadeProgress()
    @Published private(set) var revision = 0

    private static func key(_ address: String) -> String { "kachat_arcade_records_v1_\(address.lowercased())" }
    /// Stamps the REST API hasn't confirmed yet, checked again on each board refresh
    /// (audit 2026-11-24 #9).
    private static func unconfirmedKey(_ address: String) -> String { "kachat_arcade_unconfirmed_v1_\(address.lowercased())" }
    /// A stamp still not accepted this long after it was sent is gone: its record goes.
    private static let notAcceptedAfterMs: Int64 = 10 * 60 * 1000
    private var rechecking = false
    private var lastRecheck: Date?

    private func records(for address: String) -> [ArcadeRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.key(address)),
              let list = try? JSONDecoder().decode([ArcadeRecord].self, from: data) else { return [] }
        return list
    }

    func add(_ record: ArcadeRecord, address: String) {
        var list = records(for: address)
        list.append(record)
        // the best 50 per game are plenty for any board
        var kept: [ArcadeRecord] = []
        for game in ArcadeGame.allCases {
            kept += list.filter { $0.game == game }.sorted { $0.score > $1.score }.prefix(50)
        }
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: Self.key(address)) }
        revision &+= 1
    }

    /// The signed-in account's best stamped score in `game` since `since` (ms).
    func best(_ game: ArcadeGame, since: Int64 = 0) -> ArcadeRecord? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return records(for: address).filter { $0.game == game && $0.at >= since }
            .max { ($0.score, -$0.at) < ($1.score, -$1.at) }
    }

    /// A stamp the REST API says isn't accepted: off the board, still checked
    /// (`recheckUnconfirmed`).
    func takeBack(gameId: String, address: String) {
        let list = records(for: address).filter { $0.gameId != gameId }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.key(address)) }
        revision &+= 1
    }

    /// A stamp the chain never showed: gone for good.
    func remove(gameId: String, address: String) {
        takeBack(gameId: gameId, address: address)
        confirm(gameId: gameId, address: address)
    }

    /// Delete Account.
    func removeAll(forAddress address: String) {
        UserDefaults.standard.removeObject(forKey: Self.key(address))
        UserDefaults.standard.removeObject(forKey: Self.unconfirmedKey(address))
        revision &+= 1
    }

    // MARK: Stamps not confirmed yet

    private func unconfirmed(for address: String) -> [ArcadeRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.unconfirmedKey(address)),
              let list = try? JSONDecoder().decode([ArcadeRecord].self, from: data) else { return [] }
        return list
    }

    private func setUnconfirmed(_ list: [ArcadeRecord], address: String) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.unconfirmedKey(address))
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.unconfirmedKey(address))
        }
    }

    /// Sent, its acceptance not known yet.
    func markUnconfirmed(_ record: ArcadeRecord, address: String) {
        guard record.txId != nil else { return }
        var list = unconfirmed(for: address).filter { $0.gameId != record.gameId }
        list.append(record)
        setUnconfirmed(Array(list.suffix(50)), address: address)
    }

    /// The REST API showed it accepted (or it was taken back): no more checks.
    func confirm(gameId: String, address: String) {
        let list = unconfirmed(for: address)
        let kept = list.filter { $0.gameId != gameId }
        if kept.count != list.count { setUnconfirmed(kept, address: address) }
    }

    /// Looks the signed-in account's unconfirmed stamps up again, at most once a minute: accepted
    /// ones stop being checked, ones the REST API says aren't accepted well past their send are
    /// taken back, and no answer leaves them for next time.
    func recheckUnconfirmed() {
        guard !rechecking, let address = WalletManager.shared.currentWallet?.publicAddress else { return }
        if let lastRecheck, Date().timeIntervalSince(lastRecheck) < 60 { return }
        let pending = unconfirmed(for: address)
        guard !pending.isEmpty else { return }
        rechecking = true
        lastRecheck = Date()
        Task {
            defer { rechecking = false }
            for record in pending {
                guard let txId = record.txId else { continue }
                switch await ArcadeTransactionCheck.lookUp(txId) {
                case .accepted:
                    // taken back on an earlier 404: it landed after all
                    if !records(for: address).contains(where: { $0.gameId == record.gameId }) {
                        add(record, address: address)
                    }
                    confirm(gameId: record.gameId, address: address)
                case .notAccepted:
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    if now - record.at > Self.notAcceptedAfterMs {
                        AppLog.log("[Arcade] Stamp %@ never accepted: its score is taken back", txId)
                        remove(gameId: record.gameId, address: address)
                    }
                case .unanswered:
                    break
                }
            }
        }
    }
}

// MARK: - Leaderboards

struct ArcadeBoardRow: Identifiable, Equatable {
    var id: String { address }
    let address: String
    let score: Int
    /// Block time of the stamp (ms).
    let at: Int64
}

/// The boards, from the indexer's `/arcade/leaderboard` (ARCADE.md §5), with the player's own
/// stamped best merged in so a score shows the moment it is stamped. A failure leaves what is
/// there in place.
@MainActor
final class ArcadeLeaderboardService: ObservableObject {
    static let shared = ArcadeLeaderboardService()

    private struct Response: Decodable {
        struct Player: Decodable {
            let address: String
            let score: Int
            let at: Int64
        }
        let game: String
        let period: String
        let games: Int?
        let players: [Player]
    }

    @Published private var boards: [String: [ArcadeBoardRow]] = [:]
    /// Per game: Snake's board failing says nothing about 2048's (audit 2026-11-24 #19).
    @Published private var unreachable: Set<ArcadeGame> = []
    private var lastFetch: [ArcadeGame: Date] = [:]
    /// The most rows a board keeps, and the most bytes an answer may be (audit 2026-11-24 #22).
    private static let limit = 100
    private static let maxResponseBytes = 512 * 1024

    func serverUnreachable(_ game: ArcadeGame) -> Bool { unreachable.contains(game) }

    private static func key(_ game: ArcadeGame, _ period: ChessLeaderboardPeriod) -> String { "\(game.rawValue)|\(period.rawValue)" }

    /// At most every 20 s per game unless forced.
    func refresh(_ game: ArcadeGame, force: Bool = false) {
        ArcadeProgress.shared.recheckUnconfirmed()
        if !force, let last = lastFetch[game], Date().timeIntervalSince(last) < 20 { return }
        var base = PublicChatService.indexerBaseURL(forChannel: ArcadeStamp.channel)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return }
        lastFetch[game] = Date()
        Task {
            var answered = false
            for period in ChessLeaderboardPeriod.allCases {
                guard var components = URLComponents(string: "\(base)/arcade/leaderboard") else { return }
                components.queryItems = [
                    URLQueryItem(name: "game", value: game.rawValue),
                    URLQueryItem(name: "period", value: period.rawValue),
                    URLQueryItem(name: "limit", value: String(Self.limit))
                ]
                guard let url = components.url else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                // An ephemeral session that stops reading past `maxResponseBytes` (audit
                // 2026-11-24 #22).
                let reader = CappedResponseReader(limit: Self.maxResponseBytes, onOverflow: .fail)
                let session = URLSession(configuration: .ephemeral, delegate: reader, delegateQueue: nil)
                let result = try? await reader.read(request, using: session)
                session.finishTasksAndInvalidate()
                guard let (data, response) = result, let http = response as? HTTPURLResponse else { continue }
                // Not served yet (ARCADE.md §5 is still open): an answer, of no scores; the own
                // stamped best still shows (audit 2026-11-24 #19).
                if http.statusCode == 404 {
                    answered = true
                    continue
                }
                guard (200...299).contains(http.statusCode),
                      let decoded = try? JSONDecoder().decode(Response.self, from: data),
                      decoded.game == game.rawValue, decoded.period == period.rawValue else { continue }
                answered = true
                // One row per address, the best one kept, at most `limit` (audit 2026-11-24 #22).
                var seen = Set<String>()
                var rows: [ArcadeBoardRow] = []
                for player in decoded.players.sorted(by: { ($1.score, $0.at) < ($0.score, $1.at) })
                where KaspaAddress.isValid(player.address) && player.score >= 0 {
                    guard seen.insert(player.address.lowercased()).inserted else { continue }
                    rows.append(ArcadeBoardRow(address: player.address, score: player.score, at: player.at))
                    if rows.count == Self.limit { break }
                }
                boards[Self.key(game, period)] = rows
            }
            if answered { unreachable.remove(game) } else { unreachable.insert(game) }
        }
    }

    /// Highest score first, the earlier stamp on a tie.
    func rows(_ game: ArcadeGame, period: ChessLeaderboardPeriod) -> [ArcadeBoardRow] {
        var rows = boards[Self.key(game, period)] ?? []
        let since = ChessTournamentEngine.periodSinceMs(period, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        if let address = WalletManager.shared.currentWallet?.publicAddress,
           let mine = ArcadeProgress.shared.best(game, since: since) {
            let own = ArcadeBoardRow(address: address, score: mine.score, at: mine.at)
            if let index = rows.firstIndex(where: { $0.address.lowercased() == address.lowercased() }) {
                if mine.score > rows[index].score { rows[index] = own }
            } else {
                rows.append(own)
            }
        }
        return Array(rows.sorted { ($1.score, $0.at, $0.address) < ($0.score, $1.at, $1.address) }.prefix(Self.limit))
    }
}

// MARK: - Challenges

/// Someone's score, from the Challenge card on their post: beat `score` in `game`.
struct ArcadeChallenge: Identifiable, Equatable {
    let game: ArcadeGame
    let score: Int?
    /// Who scored it, as the link claims.
    let by: String?
    let url: URL
    /// `by` is the post's author, so the name can be shown; anyone can write any address into a
    /// link (audit 2026-11-24 #21).
    var byIsAuthor = false

    /// The name to show for who scored it: only `by` confirmed as the post's author.
    var confirmedBy: String? { byIsAuthor ? by : nil }

    var id: String { url.absoluteString }

    static let scheme = "kachatarcade"

    /// `kachatarcade://<game>?score=<n>&by=<address>&game=<game id>`
    static func url(game: ArcadeGame, score: Int, by: String, gameId: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = game.rawValue
        components.queryItems = [
            URLQueryItem(name: "score", value: String(score)),
            URLQueryItem(name: "by", value: by),
            URLQueryItem(name: "game", value: gameId)
        ]
        return components.url
    }

    /// Links come from other people's posts: only the game has to be right; a bad score or
    /// address is left out, and `url` is rebuilt from what passed.
    init?(url source: URL) {
        guard source.scheme?.lowercased() == Self.scheme,
              let host = source.host?.lowercased(), let game = ArcadeGame(rawValue: host),
              let components = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        let score = value("score").flatMap { raw -> Int? in raw.allSatisfy(\.isNumber) ? Int(raw) : nil }
            .flatMap { (0...10_000_000).contains($0) ? $0 : nil }
        let by = value("by").flatMap { KaspaAddress.isValid($0) ? $0 : nil }
        let gameId = value("game").flatMap { raw -> String? in
            raw.count <= 64 && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } ? raw : nil
        }
        var rebuilt = URLComponents()
        rebuilt.scheme = Self.scheme
        rebuilt.host = game.rawValue
        let items = [
            score.map { URLQueryItem(name: "score", value: String($0)) },
            by.map { URLQueryItem(name: "by", value: $0) },
            gameId.map { URLQueryItem(name: "game", value: $0) }
        ].compactMap { $0 }
        rebuilt.queryItems = items.isEmpty ? nil : items
        guard let url = rebuilt.url else { return nil }
        self.game = game
        self.score = score
        self.by = by
        self.url = url
    }

    /// "Beat 1,240 in Snake", or "Challenge: play Snake" without a score.
    var title: String {
        guard let score else {
            return String(format: AppLocalization.string("Challenge: play %@"), locale: AppLocalization.locale, game.title)
        }
        return String(format: AppLocalization.string("Beat %@ in %@"), locale: AppLocalization.locale,
                      score.formatted(), game.title)
    }

    struct Match: Equatable {
        let challenge: ArcadeChallenge
        /// The exact text matched, which the post leaves out of its text.
        let matchedText: String
    }

    private static let regex = try? NSRegularExpression(pattern: #"kachatarcade://[^\s<>"']+"#, options: .caseInsensitive)
    private static let trailingTrim = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    /// The first valid challenge in a post's text.
    static func match(in text: String) -> Match? {
        // a scan in place, no copy: most posts have no link at all, and this runs on every
        // redraw of every post while the feed scrolls (it lowercased the whole post before)
        guard text.range(of: "kachatarcade://", options: .caseInsensitive) != nil, let regex else { return nil }
        let ns = text as NSString
        var found: Match?
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            guard let result else { return }
            var candidate = ns.substring(with: result.range)
            while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) { candidate.removeLast() }
            guard let url = URL(string: candidate), let challenge = ArcadeChallenge(url: url) else { return }
            found = Match(challenge: challenge, matchedText: candidate)
            stop.pointee = true
        }
        return found
    }
}

/// A challenge waiting for KaPlay, which may not be up yet (a cold start).
@MainActor
final class ArcadeLinkRouter: ObservableObject {
    static let shared = ArcadeLinkRouter()
    @Published var challenge: ArcadeChallenge?

    /// A bot game on screen (`ChessBotMatchView`'s token while its board is up), and an
    /// arcade round on screen (`ArcadePlayView`): a challenge waits here until both are done, so
    /// it never pops a game (audit 2026-11-24 #11).
    @Published private(set) var botGameToken: String?
    @Published var arcadeRoundOpen = false
    var isBusy: Bool { botGameToken != nil || arcadeRoundOpen }

    func botGame(_ token: String, running: Bool) {
        if running {
            if botGameToken != token { botGameToken = token }
        } else if botGameToken == token {
            botGameToken = nil
        }
    }

    /// A challenge card's Play, or a tapped link: KaPlay opens the game. `author` is the address
    /// of the post the card is on; the challenger is named only when it is `by` (audit
    /// 2026-11-24 #21), so a tapped link (no post) says "Someone".
    static func open(_ url: URL, author: String? = nil) {
        guard var challenge = ArcadeChallenge(url: url) else { return }
        if let by = challenge.by, let author, by.lowercased() == author.lowercased() {
            challenge.byIsAuthor = true
        }
        shared.challenge = challenge
        NotificationCenter.default.post(name: .openGames, object: nil)
    }

    /// Opens the KaPost composer with the post written; the player still taps Post there.
    /// The post Share to KaPost writes: the boast and the challenge link (the composer shows the
    /// link as its card).
    static func shareText(game: ArcadeGame, score: Int, gameId: String) -> String? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress,
              let link = ArcadeChallenge.url(game: game, score: score, by: address, gameId: gameId) else { return nil }
        let boast = String(format: AppLocalization.string("I scored %@ in %@ on K. Think you can beat it?"),
                           locale: AppLocalization.locale, score.formatted(), game.title)
        return "\(boast)\n\n\(link.absoluteString)"
    }
}
