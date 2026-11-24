import SwiftUI

/// KaPlay > Chess, laid out as the arcade's game homes (owner's call, 2026-11-24): the Play card,
/// then the leaderboard, whose cycle button steps through every board (1v1, Tournaments, each
/// bot), this month and all time. Play opens a half sheet to pick 1v1, a tournament (`ChessTournamentsView`) or the bots
/// (`ChessBotsView`). If the player is already waiting or playing somewhere, that is offered first.
struct ChessHomeView: View {
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var openMode: ChessTournamentsView.Mode?
    @State private var openBots = false
    @ObservedObject private var links = ChessBotLinkRouter.shared
    /// A challenge from a post being shown (`ChessBotLinks`).
    @State private var openChallenge: ChessBotChallenge?
    /// This screen is the top of the stack (not under a pushed screen).
    @State private var isVisible = false
    @State private var showPlaySheet = false
    /// What the Play sheet picked, opened once the sheet is gone.
    @State private var pickedPlay: PlayChoice?
    @State private var board = ChessHomeView.boardChoices[0]
    @ObservedObject private var botBoards = ChessBotLeaderboardService.shared
    @State private var profileAddress: String?

    private enum PlayChoice { case duel, tournament, bots }

    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let mine = service.myActiveTournament {
                    Button {
                        openMode = mine.isDuel ? .duel : .tournament
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mine.status == .open ? "hourglass" : "play.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: ChessText.whereYouAre(mine))
                                    .font(.subheadline.weight(.semibold))
                                Text("Tap to go back to it").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }

                playCard
                leaderboard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Chess")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            botBoards.refresh(force: true)
            await service.refreshIndexerLeaderboardsNow()
        }
        .sheet(isPresented: $showPlaySheet, onDismiss: openPicked) {
            playSheet
        }
        .sheet(isPresented: Binding(
            get: { profileAddress != nil },
            set: { if !$0 { profileAddress = nil } }
        )) {
            if let address = profileAddress {
                NavigationStack {
                    ChessPlayerView(address: address)
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { openMode != nil },
            set: { if !$0 { openMode = nil } }
        )) {
            if let openMode {
                ChessTournamentsView(mode: openMode)
            }
        }
        .navigationDestination(isPresented: $openBots) {
            ChessBotsView()
        }
        .navigationDestination(isPresented: Binding(
            get: { openChallenge != nil },
            set: { if !$0 { openChallenge = nil } }
        )) {
            if let openChallenge {
                // A bot still locked: the ladder, which says who to beat first.
                if ChessBotProgress.shared.isUnlocked(openChallenge.bot) {
                    ChessBotDetailView(bot: openChallenge.bot, challenge: openChallenge)
                } else {
                    ChessBotsView(challenge: openChallenge)
                }
            }
        }
        .onAppear {
            isVisible = true
            service.refreshIndexerLeaderboards()
            botBoards.refresh()
            takeChallenge()
        }
        .onChange(of: board) { _ in
            service.refreshIndexerLeaderboards()
            botBoards.refresh()
        }
        // Through onScreenPresence: Kaspa Hub keeps KaPlay alive (hidden) once left, and the arena
        // is watched only while this screen shows.
        .onScreenPresence(appear: { service.acquire() }, disappear: { service.release() })
        // Never from under a pushed screen (a bot game, a board): it waits in the router until
        // this screen is back.
        .onChange(of: links.challenge) { _ in if isVisible { takeChallenge() } }
        // The online game a challenge waited for is over (or the rooms have loaded): take it
        // here, never from under a pushed screen.
        .onChange(of: service.isBusyOnline) { busy in if !busy, isVisible { takeChallenge() } }
        .onDisappear {
            isVisible = false
        }
    }

    // MARK: Play

    private var playCard: some View {
        VStack(spacing: 14) {
            // the image itself, not `ChessTabIcon.view`, which tints it teal: on the teal tile
            // it vanished. White, as on KaPlay's Chess card.
            Image(uiImage: ChessTabIcon.image(side: 40))
                .renderingMode(.template)
                .foregroundColor(.white)
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.accentColor))
            Text("1v1, tournaments and five bots. Online moves and bot results go on Kaspa.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let record = myRecord {
                Text(String(format: AppLocalization.string("Your record: %@ won, %@ lost"),
                            record.wins.formatted(), record.losses.formatted()))
                    .font(.headline)
            }
            Button {
                Haptics.impact(.medium)
                showPlaySheet = true
            } label: {
                Text("Play")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            Text("Online, five minutes a side and every move is a Kaspa transaction. Bot games stamp their result on Kaspa when they end.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }

    /// Your games won and lost online, all time (1v1s and tournament games alike).
    private var myRecord: (wins: Int, losses: Int)? {
        guard let me = me?.lowercased(),
              let row = service.board(for: .allTime).first(where: { $0.address.lowercased() == me }),
              row.wins + row.losses > 0 else { return nil }
        return (row.wins, row.losses)
    }

    /// Play's half sheet: which kind of game.
    private var playSheet: some View {
        VStack(spacing: 12) {
            Text("Choose your game")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)
            ActionSheetRow(
                title: "1v1",
                subtitle: "Play the next person who joins, or a friend by code.",
                systemImage: "person.2.fill"
            ) { pick(.duel) }
            ActionSheetRow(
                title: "Tournament",
                subtitle: "Eight players, single elimination.",
                systemImage: "trophy.fill"
            ) { pick(.tournament) }
            ActionSheetRow(
                title: "Bots",
                subtitle: "Five bots, level 1 to 5. Beat one to unlock the next.",
                systemImage: "cpu"
            ) { pick(.bots) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .fittedSheetDetent(estimate: 330)
    }

    private func pick(_ choice: PlayChoice) {
        pickedPlay = choice
        showPlaySheet = false
    }

    /// Opens what the sheet picked, now that it's gone (a push while it closes can be lost).
    private func openPicked() {
        guard let choice = pickedPlay else { return }
        pickedPlay = nil
        switch choice {
        case .duel: openMode = .duel
        case .tournament: openMode = .tournament
        case .bots: openBots = true
        }
    }

    // MARK: Leaderboard

    /// One stop of the board's cycle button: a board and its period.
    private struct BoardChoice: Hashable {
        enum Kind: Hashable {
            case duel, tournament
            case bot(Int)
        }
        let kind: Kind
        let period: ChessLeaderboardPeriod
    }

    /// Every board, each for this month and all time (owner, 2026-11-24: the cycle button goes
    /// through every kind of leaderboard): 1v1, Tournaments, then each bot.
    private static let boardChoices: [BoardChoice] = {
        let kinds: [BoardChoice.Kind] = [.duel, .tournament] + ChessBot.all.map { .bot($0.level) }
        return kinds.flatMap { kind in ChessLeaderboardPeriod.allCases.map { BoardChoice(kind: kind, period: $0) } }
    }()

    private func boardTitle(_ choice: BoardChoice) -> String {
        let kind: String
        switch choice.kind {
        case .duel: kind = AppLocalization.string("1v1")
        case .tournament: kind = AppLocalization.string("Tournaments")
        case .bot(let level): kind = ChessBot.all.first { $0.level == level }?.name ?? ""
        }
        return "\(kind) · \(AppLocalization.string(choice.period.cycleTitle))"
    }

    private struct BoardRow: Identifiable {
        let address: String
        let trailing: AnyView
        var id: String { address }
    }

    private func boardRows(_ choice: BoardChoice) -> [BoardRow] {
        switch choice.kind {
        case .duel:
            return ChessTournamentEngine.duelLeaderboard(service.board(for: choice.period)).map { row in
                BoardRow(address: row.address, trailing: AnyView(HStack(spacing: 10) {
                    Text("\(row.wins) W").foregroundColor(.green)
                    Text("\(row.losses) L").foregroundColor(.red)
                }))
            }
        case .tournament:
            return ChessTournamentEngine.tournamentLeaderboard(service.board(for: choice.period)).map { row in
                BoardRow(address: row.address, trailing: AnyView(HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        // Orange, not yellow: yellow can't be read on a light row.
                        Image(systemName: "trophy.fill").foregroundColor(.orange)
                        Text(verbatim: "\(row.tournamentsWon)").foregroundColor(.orange)
                    }
                    Text("\(row.tournamentsLost) L").foregroundColor(.red)
                }))
            }
        case .bot(let level):
            guard let bot = ChessBot.all.first(where: { $0.level == level }) else { return [] }
            return botBoards.rows(for: bot, period: choice.period).map { row in
                BoardRow(address: row.address, trailing: AnyView(Text("\(row.moves) moves").foregroundColor(.green)))
            }
        }
    }

    private func emptyText(_ choice: BoardChoice) -> String {
        switch (choice.kind, choice.period) {
        case (.duel, .month): return AppLocalization.string("No finished 1v1 games this month yet.")
        case (.duel, .allTime): return AppLocalization.string("No finished 1v1 games yet.")
        case (.tournament, .month): return AppLocalization.string("No finished tournaments this month yet.")
        case (.tournament, .allTime): return AppLocalization.string("No finished tournaments yet.")
        case (.bot(let level), let period):
            let name = ChessBot.all.first { $0.level == level }?.name ?? ""
            return String(format: AppLocalization.string(period == .month ? "Nobody has beaten %@ this month yet." : "Nobody has beaten %@ yet."), name)
        }
    }

    private var boardServerDown: Bool {
        if case .bot = board.kind { return botBoards.serverUnreachable }
        return service.arenaServerDown
    }

    private var leaderboard: some View {
        let rows = boardRows(board)
        let mine = me?.lowercased()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Leaderboard")
                .font(.title3.weight(.bold))
            CycleCapsuleButton(options: Self.boardChoices, selection: $board,
                               title: { boardTitle($0) }, hint: "Switches to the next leaderboard")
            if rows.isEmpty {
                Text(verbatim: boardServerDown
                     ? AppLocalization.string("Chess server unreachable. Showing what this phone has.")
                     : emptyText(board))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(10).enumerated()), id: \.element.id) { index, row in
                        Button {
                            profileAddress = row.address
                        } label: {
                            HStack(spacing: 12) {
                                Text(verbatim: "\(index + 1)")
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundColor(index < 3 ? .accentColor : .secondary)
                                    .frame(width: 28, alignment: .leading)
                                KNSAvatarView(
                                    avatarURLString: nil,
                                    fallbackText: ContactsManager.shared.displayName(for: row.address),
                                    size: 32,
                                    contactAddress: row.address
                                )
                                Text(verbatim: ContactsManager.shared.displayName(for: row.address))
                                    .font(.subheadline.weight(row.address.lowercased() == mine ? .bold : .regular))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                row.trailing
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .fixedSize()
                                    .layoutPriority(1)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < min(rows.count, 10) - 1 { Divider().padding(.leading, 98) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
    }

    /// A challenge never pops a board or a waiting room: while the player is busy online
    /// (`ChessTournamentService.isBusyOnline`), it waits in the router until that is over and
    /// this screen is back.
    private func takeChallenge() {
        guard let challenge = links.challenge, !service.isBusyOnline else { return }
        links.challenge = nil
        openChallenge = challenge
    }
}
