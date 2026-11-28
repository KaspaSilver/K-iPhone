import SwiftUI

// KaPlay's arcade screens (ARCADE.md): a game's home (Play, your best, the boards), the game itself
// (Snake, 2048), and the game-over sheet that stamps the score on Kaspa and shares it to KaPost.

// MARK: - A game's home

/// A game's mark: Snake's symbol, and 2048 as the number itself (owner, 2026-11-24).
struct ArcadeGameIcon: View {
    let game: ArcadeGame
    /// The symbol's point size; the number is drawn to fit the same space.
    let size: CGFloat

    var body: some View {
        switch game {
        case .g2048:
            Text(verbatim: "2048")
                .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size * 1.7)
        case .snake:
            Image(systemName: game.systemImage)
                .font(.system(size: size, weight: .bold))
        }
    }
}

struct ArcadeGameHomeView: View {
    let game: ArcadeGame
    /// Someone's score to beat, from a challenge card.
    var challenge: ArcadeChallenge?

    @ObservedObject private var boards = ArcadeLeaderboardService.shared
    @ObservedObject private var progress = ArcadeProgress.shared
    @ObservedObject private var contactsManager = ContactsManager.shared
    @State private var period: ChessLeaderboardPeriod = .month
    @State private var playing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let challenge, let banner = challengeText(challenge) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "flag.2.crossed.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                        Text(verbatim: banner)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.14)))
                }

                VStack(spacing: 14) {
                    ArcadeGameIcon(game: game, size: 40)
                        .foregroundColor(.white)
                        .frame(width: 84, height: 84)
                        .background(RoundedRectangle(cornerRadius: 22).fill(Color.accentColor))
                    Text(LocalizedStringKey(game.detail))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let best = progress.best(game) {
                        Text(String(format: AppLocalization.string("Your best: %@"), best.score.formatted()))
                            .font(.headline)
                    }
                    Button {
                        Haptics.impact(.medium)
                        playing = true
                    } label: {
                        Text("Play")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    Text("Each finished game's score is stamped on Kaspa from your chatting address, for a small network fee.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))

                leaderboard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Text(LocalizedStringKey(game.title)))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { boards.refresh(game, force: true) }
        .onAppear { boards.refresh(game) }
        .fullScreenCover(isPresented: $playing, onDismiss: { boards.refresh(game, force: true) }) {
            ArcadePlayView(game: game)
        }
    }

    private func challengeText(_ challenge: ArcadeChallenge) -> String? {
        // named only when the link's `by` is the post's author (audit 2026-11-24 #21)
        let who = challenge.confirmedBy.map { contactsManager.displayName(for: $0) }
        switch (who, challenge.score) {
        case let (who?, score?):
            return String(format: AppLocalization.string("%@ scored %@ in %@. Can you beat it?"), who, score.formatted(), game.title)
        case let (nil, score?):
            return String(format: AppLocalization.string("Someone scored %@ in %@. Can you beat it?"), score.formatted(), game.title)
        default:
            return nil
        }
    }

    private var leaderboard: some View {
        let rows = boards.rows(game, period: period)
        let me = WalletManager.shared.currentWallet?.publicAddress.lowercased()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leaderboard")
                    .font(.title3.weight(.bold))
                Spacer()
                CycleCapsuleButton(options: ChessLeaderboardPeriod.allCases, selection: $period,
                                   title: { $0.cycleTitle }, hint: "Switches the leaderboard period")
            }
            if rows.isEmpty {
                Text(boards.serverUnreachable(game)
                     ? "The leaderboard couldn't be loaded. Pull down to try again."
                     : "No scores yet. Be the first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                // lazy: up to 100 rows (smoothness audit L12)
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.prefix(100).enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 12) {
                            Text(verbatim: "\(index + 1)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundColor(index < 3 ? .accentColor : .secondary)
                                .frame(width: 28, alignment: .leading)
                            KNSAvatarView(
                                avatarURLString: nil,
                                fallbackText: contactsManager.displayName(for: row.address),
                                size: 32,
                                contactAddress: row.address
                            )
                            Text(verbatim: contactsManager.displayName(for: row.address))
                                .font(.subheadline.weight(row.address.lowercased() == me ? .bold : .regular))
                                .lineLimit(1)
                            Spacer()
                            Text(verbatim: row.score.formatted())
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        if index < min(rows.count, 100) - 1 { Divider().padding(.leading, 98) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
    }
}

// MARK: - Playing

/// The game full screen, then its game-over sheet.
struct ArcadePlayView: View {
    let game: ArcadeGame
    @Environment(\.dismiss) private var dismiss
    @State private var round = UUID()
    @State private var finished: ArcadeStampJob?
    /// Share to KaPost was tapped: the composer comes up once the game-over sheet has gone.
    @State private var shareJob: ArcadeStampJob?
    /// The post the composer is writing and its game; the game-over sheet comes back when it
    /// closes. The text rides in the item, so the composer is built with it (held in a separate
    /// state it reached the composer empty).
    @State private var composing: ComposeItem?

    private struct ComposeItem: Identifiable {
        let job: ArcadeStampJob
        let text: String
        var id: String { job.id }
    }
    @State private var notice: String?
    @State private var noticeStyle: ToastStyle = .success

    var body: some View {
        NavigationStack {
            Group {
                switch game {
                case .snake:
                    SnakePlayView(onOver: over).id(round)
                case .g2048:
                    Game2048PlayView(onOver: over).id(round)
                }
            }
            .navigationTitle(Text(LocalizedStringKey(game.title)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Color(.systemBackground))
        }
        .sheet(item: $finished, onDismiss: shareIfAsked) { job in
            ArcadeGameOverView(job: job, onPlayAgain: {
                finished = nil
                round = UUID()
            }, onDone: {
                finished = nil
                dismiss()
            }, onShare: {
                shareJob = job
                finished = nil
            })
            .interactiveDismissDisabled()
        }
        // Share to KaPost stays in KaPlay (owner, 2026-11-24): KaPost's composer slides up over
        // the game with the post written. Post sends it; the X closes it. Either way the game
        // and its game-over sheet are right where they were.
        .fullScreenCover(item: $composing, onDismiss: {
            if let job = shareJob {
                shareJob = nil
                finished = job
            }
        }) { item in
            let job = item.job
            // Where the post stands lives on the job and shows on the game-over sheet, which is
            // back over the game by the time it is known: a toast here was hidden under it, and
            // Share stayed on, so a second tap could post it twice (audit 2026-11-24 #8). The
            // toast is only for when the sheet has gone.
            KaPostQuickComposer(text: item.text, onPosting: {
                job.share = .posting
            }, onResult: { result in
                switch result {
                case .success:
                    job.share = .shared
                    if finished == nil { showNotice(AppLocalization.string("Posted to KaPost"), style: .success) }
                case .failure(let error) where error is SendOutcomeUnknownError:
                    job.share = .unconfirmed
                case .failure(let error):
                    let message = PublicChatService.friendlySendErrorMessage(for: error)
                    job.share = .failed(message)
                    if finished == nil { showNotice(message, style: .error) }
                }
            })
        }
        .toast(message: notice, style: noticeStyle)
        // A round on screen holds challenge links until it closes (audit 2026-11-24 #11).
        .onAppear { ArcadeLinkRouter.shared.arcadeRoundOpen = true }
        .onDisappear { ArcadeLinkRouter.shared.arcadeRoundOpen = false }
    }

    private func shareIfAsked() {
        guard let job = shareJob,
              let text = ArcadeLinkRouter.shareText(game: job.game, score: job.score, gameId: job.id) else {
            shareJob = nil
            return
        }
        composing = ComposeItem(job: job, text: text)
    }

    private func showNotice(_ text: String, style: ToastStyle) {
        noticeStyle = style
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if notice == text { notice = nil }
        }
    }

    private func over(score: Int, seed: UInt64, moves: String) {
        Haptics.error()
        // a game of nothing isn't worth a fee
        guard score > 0 else {
            finished = ArcadeStampJob.notStamped(game: game)
            return
        }
        finished = ArcadeStampJob(game: game, score: score, seed: seed, moves: moves)
    }
}

extension ArcadeStampJob {
    /// A finished game with no score: shown, never sent.
    static func notStamped(game: ArcadeGame) -> ArcadeStampJob {
        ArcadeStampJob(game: game, score: 0, seed: 0, moves: "", send: false)
    }
}

/// Game over: the score, where its stamp stands, Share to KaPost once it is on Kaspa, Play Again.
struct ArcadeGameOverView: View {
    @ObservedObject var job: ArcadeStampJob
    let onPlayAgain: () -> Void
    let onDone: () -> Void
    let onShare: () -> Void
    @ObservedObject private var progress = ArcadeProgress.shared

    var body: some View {
        VStack(spacing: 18) {
            Text("Game Over")
                .font(.title2.weight(.bold))
                .padding(.top, 24)
            Text(verbatim: job.score.formatted())
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundColor(.accentColor)
            if let best = progress.best(job.game), best.gameId != job.id {
                Text(String(format: AppLocalization.string("Your best: %@"), best.score.formatted()))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            stampLine
            shareLine
            VStack(spacing: 10) {
                if job.score > 0 {
                    Button {
                        if case .failed = job.state {
                            job.retry()
                        } else {
                            Haptics.impact(.light)
                            onShare()
                        }
                    } label: {
                        Text(shareTitle)
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Capsule().fill(Color.accentColor.opacity(shareEnabled ? 1 : 0.4)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!shareEnabled)
                }
                Button {
                    Haptics.impact(.light)
                    onPlayAgain()
                } label: {
                    Text("Play Again")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                Button("Done", action: onDone)
                    .font(.headline)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium, .large])
    }

    private var shareEnabled: Bool {
        switch job.share {
        case .posting, .shared, .unconfirmed: return false
        case .none, .failed: break
        }
        switch job.state {
        case .stamped, .failed: return true
        case .sending, .unconfirmed, .notSent: return false
        }
    }

    private var shareTitle: LocalizedStringKey {
        switch job.share {
        case .posting: return "Posting to KaPost…"
        case .shared: return "Shared to KaPost"
        case .unconfirmed: return "Not confirmed"
        case .none, .failed: break
        }
        switch job.state {
        case .failed: return "Retry the Stamp"
        default: return "Share to KaPost"
        }
    }

    /// Why Share to KaPost is off or back on, under the stamp's line (audit 2026-11-24 #8).
    /// Posting and shared are the button's own title.
    @ViewBuilder
    private var shareLine: some View {
        switch job.share {
        case .none, .posting, .shared:
            EmptyView()
        case .unconfirmed:
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundColor(.orange)
                Text(verbatim: SendOutcomeUnknownError.message)
            }
            .modifier(ArcadeStatusLineStyle())
        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(verbatim: error)
            }
            .modifier(ArcadeStatusLineStyle())
        }
    }

    @ViewBuilder
    private var stampLine: some View {
        HStack(spacing: 8) {
            switch job.state {
            case .sending:
                ProgressView()
                Text("Stamping the score on Kaspa…")
            case .stamped:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Score stamped on Kaspa")
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(verbatim: error)
            case .unconfirmed(let note):
                Image(systemName: "clock").foregroundColor(.orange)
                Text(verbatim: note)
            case .notSent:
                Text("No score to stamp.")
            }
        }
        .modifier(ArcadeStatusLineStyle())
    }
}

/// The game-over sheet's small status lines (the stamp, the post).
private struct ArcadeStatusLineStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }
}

// MARK: - Snake

struct SnakePlayView: View {
    let onOver: (_ score: Int, _ seed: UInt64, _ moves: String) -> Void

    @State private var seed: UInt64
    @State private var engine: SnakeEngine
    /// Turns asked for, taken one per tick.
    @State private var queued: [ArcadeDirection] = []
    @State private var started = false
    @State private var loop: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init(onOver: @escaping (_ score: Int, _ seed: UInt64, _ moves: String) -> Void) {
        self.onOver = onOver
        let seed = ArcadeRandom.newSeed()
        _seed = State(initialValue: seed)
        _engine = State(initialValue: SnakeEngine(seed: seed))
    }

    /// Slow to start, faster as it grows: 240 ms a step, 5 ms less per apple, down to 85
    /// (owner, 2026-11-24: 150 ms felt too fast to start on).
    private var stepNanos: UInt64 {
        UInt64(max(85, 240 - engine.score * 5)) * 1_000_000
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(String(format: AppLocalization.string("Score: %@"), engine.score.formatted()))
                .font(.title2.weight(.bold).monospacedDigit())
            board
                .padding(.horizontal, 12)
                .gesture(DragGesture(minimumDistance: 14).onEnded { swipe($0.translation) })
            if !started {
                Text("Swipe on the board or use the arrows to start.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            pad
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .onDisappear { loop?.cancel() }
        // Control Center, a call banner or the background pause it: the snake waits for the next
        // swipe or arrow, with the "Swipe ... to start" hint back (audit 2026-11-24 #12).
        .onChange(of: scenePhase) { phase in
            if phase != .active { pause() }
        }
    }

    private func pause() {
        guard started, !engine.isOver else { return }
        loop?.cancel()
        loop = nil
        queued = []
        started = false
    }

    private var board: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cell = side / CGFloat(SnakeEngine.width)
            Canvas { context, _ in
                // Kaspa eats Bitcoin (owner, 2026-11-24): the apple is the Bitcoin logo and the
                // snake's head the Kaspa logo.
                if let food = engine.food {
                    let rect = CGRect(x: CGFloat(food.x) * cell, y: CGFloat(food.y) * cell, width: cell, height: cell).insetBy(dx: cell * 0.08, dy: cell * 0.08)
                    // the coin image has white corners, not see-through ones: drawn inside its circle
                    var coin = context
                    coin.clip(to: Path(ellipseIn: rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.03)))
                    coin.draw(coin.resolve(Image("CoinBtc")), in: rect)
                }
                // tail first, so the head draws over the body
                for (index, part) in engine.body.enumerated().reversed() {
                    let rect = CGRect(x: CGFloat(part.x) * cell, y: CGFloat(part.y) * cell, width: cell, height: cell).insetBy(dx: 1, dy: 1)
                    if index == 0 {
                        context.draw(context.resolve(Image("KaspaLogo")), in: rect.insetBy(dx: -0.5, dy: -0.5))
                    } else {
                        context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.25), with: .color(Color.accentColor.opacity(0.75)))
                    }
                }
            }
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var pad: some View {
        VStack(spacing: 8) {
            arrow(.up)
            HStack(spacing: 48) {
                arrow(.left)
                arrow(.right)
            }
            arrow(.down)
        }
    }

    private func arrow(_ direction: ArcadeDirection) -> some View {
        let icon: String
        switch direction {
        case .up: icon = "chevron.up"
        case .down: icon = "chevron.down"
        case .left: icon = "chevron.left"
        case .right: icon = "chevron.right"
        }
        return Button {
            ask(direction)
        } label: {
            Image(systemName: icon)
                .font(.title2.weight(.bold))
                .foregroundColor(.accentColor)
                .frame(width: 64, height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func swipe(_ t: CGSize) {
        if abs(t.width) > abs(t.height) {
            ask(t.width > 0 ? .right : .left)
        } else {
            ask(t.height > 0 ? .down : .up)
        }
    }

    private func ask(_ direction: ArcadeDirection) {
        guard !engine.isOver else { return }
        if queued.count < 3 { queued.append(direction) }
        Haptics.selection()
        if !started {
            started = true
            run()
        }
    }

    private func run() {
        loop?.cancel()
        loop = Task { @MainActor in
            while !Task.isCancelled, !engine.isOver {
                try? await Task.sleep(nanoseconds: stepNanos)
                guard !Task.isCancelled else { return }
                // the first queued turn that can be taken now
                var turn: ArcadeDirection?
                while let next = queued.first {
                    queued.removeFirst()
                    if engine.canTurn(next) { turn = next; break }
                }
                let ateBefore = engine.score
                engine.tick(turn: turn)
                if engine.score > ateBefore { Haptics.impact(.light) }
            }
            if engine.isOver { onOver(engine.score, seed, engine.movesText) }
        }
    }
}

// MARK: - 2048

struct Game2048PlayView: View {
    let onOver: (_ score: Int, _ seed: UInt64, _ moves: String) -> Void

    @State private var seed: UInt64
    @State private var engine: Game2048Engine
    @State private var reported = false
    /// The tiles as drawn, each with its own identity, so a move slides every tile to where it
    /// lands and two equal tiles run into each other before they become one (owner, 2026-11-24:
    /// no fading). Kept equal to `engine.tiles` between moves.
    @State private var shown: [VisualTile] = []
    /// The second half of a move (merges and the new tile), run early if the next swipe comes
    /// before it has.
    @State private var settle: (() -> Void)?
    @State private var settleToken = 0

    private static let slide = 0.11

    struct VisualTile: Identifiable, Equatable {
        let id: UUID
        var value: Int
        var cell: Int
        /// Bumped when it doubles: the tile pops.
        var pops = 0
        /// Merged into another tile: it slides there, then goes.
        var consumed = false
        var isNew = false
    }

    init(onOver: @escaping (_ score: Int, _ seed: UInt64, _ moves: String) -> Void) {
        self.onOver = onOver
        let seed = ArcadeRandom.newSeed()
        let engine = Game2048Engine(seed: seed)
        _seed = State(initialValue: seed)
        _engine = State(initialValue: engine)
        _shown = State(initialValue: Self.tiles(from: engine))
    }

    private static func tiles(from engine: Game2048Engine) -> [VisualTile] {
        engine.tiles.indices.compactMap { index in
            engine.tiles[index] == 0 ? nil : VisualTile(id: UUID(), value: engine.tiles[index], cell: index)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                scoreBox("Score", engine.score)
                scoreBox("Best Tile", engine.bestTile)
            }
            grid
                .padding(.horizontal, 16)
                .gesture(DragGesture(minimumDistance: 14).onEnded { swipe($0.translation) })
            Text("Swipe to move the tiles. Equal tiles merge.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    private func scoreBox(_ title: LocalizedStringKey, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(verbatim: value.formatted())
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 4)
    }

    private var grid: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let gap: CGFloat = 8
            let cell = (side - gap * 5) / 4
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground))
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
                        .frame(width: cell, height: cell)
                        .offset(x: gap + CGFloat(index % 4) * (cell + gap), y: gap + CGFloat(index / 4) * (cell + gap))
                }
                // consumed tiles under the ones they merge into
                ForEach(shown.sorted { ($0.consumed ? 0 : 1) < ($1.consumed ? 0 : 1) }) { tile in
                    Game2048Tile(value: tile.value, pops: tile.pops, isNew: tile.isNew)
                        .frame(width: cell, height: cell)
                        .offset(x: gap + CGFloat(tile.cell % 4) * (cell + gap), y: gap + CGFloat(tile.cell / 4) * (cell + gap))
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func swipe(_ t: CGSize) {
        guard !engine.isOver else { return }
        // the last move's merges land now, so this one starts from the board as it is
        settleNow()
        let direction: ArcadeDirection = abs(t.width) > abs(t.height)
            ? (t.width > 0 ? .right : .left)
            : (t.height > 0 ? .down : .up)
        guard engine.move(direction) else { return }
        Haptics.selection()

        // Where each tile goes, line by line, the way the engine slides them: equal neighbours
        // meet in one cell, nearest the wall first.
        var moved = shown
        var merges: [(keep: UUID, gone: UUID)] = []
        for line in 0..<Game2048Engine.size {
            let cells = Game2048Engine.lineIndices(line, direction)
            let inLine = cells.compactMap { cell in moved.firstIndex { $0.cell == cell && !$0.consumed } }
            var target = 0
            var i = 0
            while i < inLine.count {
                let a = inLine[i]
                if i + 1 < inLine.count, moved[a].value == moved[inLine[i + 1]].value {
                    let b = inLine[i + 1]
                    moved[a].cell = cells[target]
                    moved[b].cell = cells[target]
                    moved[b].consumed = true
                    merges.append((moved[a].id, moved[b].id))
                    i += 2
                } else {
                    moved[a].cell = cells[target]
                    i += 1
                }
                target += 1
            }
        }
        for index in moved.indices { moved[index].isNew = false }
        withAnimation(.easeInOut(duration: Self.slide)) { shown = moved }

        // Then they clash: the pair becomes one tile of double the value, and the new tile
        // appears.
        let after = engine
        settleToken &+= 1
        let token = settleToken
        settle = {
            var tiles = shown.filter { !$0.consumed }
            for merge in merges {
                if let index = tiles.firstIndex(where: { $0.id == merge.keep }) {
                    tiles[index].value *= 2
                    tiles[index].pops += 1
                }
            }
            if let spawn = after.lastSpawn, after.tiles[spawn] != 0 {
                tiles.append(VisualTile(id: UUID(), value: after.tiles[spawn], cell: spawn, isNew: true))
            }
            // the board as drawn must be the engine's; if it isn't, the engine wins
            var check = Array(repeating: 0, count: 16)
            for tile in tiles { check[tile.cell] = tile.value }
            if check != after.tiles { tiles = Self.tiles(from: after) }
            shown = tiles
            settle = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slide) {
            if settleToken == token { settleNow() }
        }

        if engine.isOver, !reported {
            reported = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                onOver(engine.score, seed, engine.moves)
            }
        }
    }

    private func settleNow() {
        guard let settle else { return }
        self.settle = nil
        settle()
    }
}

/// One 2048 tile: its colour by value, a pop when it doubles, a grow-in when it's new.
private struct Game2048Tile: View {
    let value: Int
    let pops: Int
    let isNew: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        let level = value > 0 ? Int(log2(Double(value))) : 0
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(min(1, 0.25 + Double(level) * 0.07)))
            Text(verbatim: "\(value)")
                .font(.system(size: value >= 1000 ? 22 : 28, weight: .heavy, design: .rounded))
                .foregroundColor(level >= 7 ? .black : .primary)
                .minimumScaleFactor(0.5)
                .padding(4)
        }
        .scaleEffect(scale)
        .onAppear {
            guard isNew else { return }
            scale = 0.2
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { scale = 1 }
        }
        .onChange(of: pops) { _ in
            // the clash: a quick swell as the two become one
            scale = 1.18
            withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { scale = 1 }
        }
    }
}
