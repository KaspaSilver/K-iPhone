import SwiftUI

/// The line a chess screen shows while the chess server isn't answering: what's on screen may be
/// behind, and says so.
struct ChessServerDownNote: View {
    var text: LocalizedStringKey = "Chess server unreachable, showing what we have. Your games keep going from the network. Public rooms can be joined again when it's back."

    var body: some View {
        Label(text, systemImage: "exclamationmark.icloud")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The side to move's clock as "m:ss" (a list row, the bracket's LIVE pill). The one part of
/// those screens redrawn every second: it alone observes the arena's clock (`ChessClock`).
/// `format` turns the time into the shown text ("LIVE %@").
struct ChessLiveClockText: View {
    let game: ChessTournamentGame
    var format: ((String) -> String)? = nil
    @ObservedObject private var clock = ChessClock.shared

    var body: some View {
        let time = ChessText.clock(game.remainingMs(game.sideToMove, at: clock.now))
        Text(verbatim: format.map { $0(time) } ?? time)
    }
}

// The small board, its piece glyphs and the waiting overlay are the 1:1 chat chess's
// (`ChessBoardThumbnail` and `ChessPieceGlyphView` in MessageBubbleView.swift,
// `WaitingOnOpponentOverlay` in ChessGameView.swift), shared with the arena's screens.

// MARK: - Screen titles
// (moved here from ChessLeaderboardView.swift, deleted as dead code: audit 2026-11-24 #41)

extension View {
    /// A chess screen's title, as KaPlay drew it: big, fixed above the content that scrolls, with
    /// the balance alone in the center of the bar. Keep `navigationTitle` as well: the next
    /// screen's Back reads it. A tab's first screen passes `showsBackupBanner`, so
    /// `AccountBackupBanner` sits above its title.
    func fixedScreenTitle(_ title: Text, showsBackupBanner: Bool = false) -> some View {
        VStack(spacing: 0) {
            if showsBackupBanner {
                AccountBackupBanner()
            }
            title
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            self
        }
    }
}

/// A game's title with the balance under it, for the center of a navigation bar: a board has no
/// room for `fixedScreenTitle`. A principal toolbar item takes the place of `navigationTitle`, so
/// a bar with only the balance there shows no title at all.
struct ScreenTitleToolbarLabel: View {
    let title: Text

    var body: some View {
        VStack(spacing: 0) {
            title
                .font(.headline)
                .lineLimit(1)
            BalanceToolbarLabel()
        }
    }
}
