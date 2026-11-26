import SwiftUI

/// The Games tab (KaPlay's Play tab): a card per game. Chess, then the arcade (Snake and 2048,
/// since 2026-11-23, ARCADE.md); a new game is one more card here.
struct GamesView: View {
    @ObservedObject private var links = ChessBotLinkRouter.shared
    @ObservedObject private var arcadeLinks = ArcadeLinkRouter.shared
    @State private var openChess = false
    /// An arcade game's home, with the challenge that opened it, if any.
    @State private var openArcade: ArcadeOpen?

    private struct ArcadeOpen: Identifiable, Hashable {
        let game: ArcadeGame
        var challenge: ArcadeChallenge?
        var id: String { game.rawValue + (challenge?.id ?? "") }
        static func == (a: ArcadeOpen, b: ArcadeOpen) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    gameCard(
                        title: "Chess",
                        detail: "1v1, tournaments and five bots. Online moves and bot results go on Kaspa."
                    ) {
                        Image(uiImage: ChessTabIcon.image(side: 30))
                            .renderingMode(.template)
                            .foregroundColor(.white)
                    } open: {
                        openChess = true
                    }
                    ForEach(ArcadeGame.allCases) { game in
                        gameCard(title: LocalizedStringKey(game.title), detail: LocalizedStringKey(game.detail)) {
                            ArcadeGameIcon(game: game, size: 26)
                                .foregroundColor(.white)
                        } open: {
                            openArcade = ArcadeOpen(game: game)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .fixedScreenTitle(Text("Arcade"))
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Arcade"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
            }
            .navigationDestination(isPresented: $openChess) {
                ChessHomeView()
            }
            .navigationDestination(isPresented: Binding(get: { openArcade != nil }, set: { if !$0 { openArcade = nil } })) {
                if let open = openArcade {
                    ArcadeGameHomeView(game: open.game, challenge: open.challenge)
                }
            }
            // A challenge from a post is for chess: ChessHomeView takes it from the router.
            .onAppear { takeChessChallenge() }
            .onChange(of: links.challenge) { _ in takeChessChallenge() }
            // A score challenge from a post: that game's home, with the score to beat.
            .onAppear { takeArcadeChallenge() }
            .onChange(of: arcadeLinks.challenge) { _ in takeArcadeChallenge() }
            // What a challenge waited for is over (audit 2026-11-24 #11).
            .onChange(of: arcadeLinks.isBusy) { busy in
                guard !busy else { return }
                takeChessChallenge()
                takeArcadeChallenge()
            }
            // only this one value: observing the whole arena would redraw the tab on every move
            .onReceive(ChessTournamentService.shared.$isBusyOnline) { busy in
                if !busy { takeArcadeChallenge() }
            }
            .onChange(of: openChess) { open in
                if !open { takeArcadeChallenge() }
            }
        }
    }

    /// Opens Chess for a bot challenge, closing an arcade game's home; an arcade round on screen
    /// keeps it waiting (audit 2026-11-24 #11).
    private func takeChessChallenge() {
        guard links.challenge != nil, !arcadeLinks.arcadeRoundOpen else { return }
        openArcade = nil
        openChess = true
    }

    /// A challenge never pops a game: while a bot game or an online game is on, or an arcade
    /// round is up, it waits in the router until that is over (as `ChessHomeView.takeChallenge`
    /// does; audit 2026-11-24 #11). With Chess closed there is no board to pop, and the arena may
    /// never have loaded (`isBusyOnline` is true until it has), so only an open Chess waits on it.
    private func takeArcadeChallenge() {
        guard let challenge = arcadeLinks.challenge, !arcadeLinks.isBusy,
              !(openChess && ChessTournamentService.shared.isBusyOnline) else { return }
        arcadeLinks.challenge = nil
        openChess = false
        openArcade = ArcadeOpen(game: challenge.game, challenge: challenge)
    }

    private func gameCard<Icon: View>(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder icon: () -> Icon,
        open: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            open()
        } label: {
            HStack(spacing: 16) {
                icon()
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
