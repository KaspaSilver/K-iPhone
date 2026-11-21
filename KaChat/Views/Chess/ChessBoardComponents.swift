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
