import SwiftUI

// Back from KaPlay (phase 4, 2026-11-21): the leaderboards, and the title helpers the chess
// screens were written with.

/// KaPlay > Chess > Leaderboard (owner's call, 2026-11-22: inside Chess, no longer a Kaspa Hub
/// tile of its own): three rows, each opening its own page. 1v1 and Tournaments are a board for
/// this month or all time (`ChessLeaderboardPage`); Bots is a board per bot
/// (`ChessBotLeaderboardsView`).
struct ChessLeaderboardView: View {
    @State private var openMode: ChessTournamentsView.Mode?
    @State private var openBots = false

    var body: some View {
        // Pushed inside KaPlay's NavigationStack, so no stack of its own.
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ChessLeaderboardLink(title: "1v1", icon: "person.2.fill") { openMode = .duel }
                ChessLeaderboardLink(title: "Tournaments", icon: "trophy.fill") { openMode = .tournament }
                ChessLeaderboardLink(title: "Bots", icon: "cpu") { openBots = true }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Spacer(minLength: 0)
        }
        .fixedScreenTitle(Text("Leaderboard"))
        .background(Color(.systemGroupedBackground))
        .navigationDestination(isPresented: Binding(
            get: { openMode != nil },
            set: { if !$0 { openMode = nil } }
        )) {
            if let openMode {
                ChessLeaderboardPage(mode: openMode)
            }
        }
        .navigationDestination(isPresented: $openBots) {
            ChessBotLeaderboardsView()
        }
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
    }
}

/// Leaderboard > 1v1 or Tournaments: that board, on a page of its own.
private struct ChessLeaderboardPage: View {
    let mode: ChessTournamentsView.Mode
    @ObservedObject private var service = ChessTournamentService.shared

    private var title: Text { mode == .duel ? Text("1v1") : Text("Tournaments") }

    var body: some View {
        List {
            ChessLeaderboardRows(mode: mode)
        }
        .listStyle(.insetGrouped)
        // Past the 20 s throttle, and the spinner stays until the boards are in.
        .refreshable { await service.refreshIndexerLeaderboardsNow() }
        .fixedScreenTitle(title)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
        // Reads the arena while the board is up, the same as the Play screens do (through
        // onScreenPresence: Kaspa Hub keeps KaPlay alive, hidden, once left).
        .onScreenPresence(appear: { service.acquire() }, disappear: { service.release() })
    }
}

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
