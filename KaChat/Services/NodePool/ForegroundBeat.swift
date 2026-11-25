import Foundation

/// One shared beat for K's foreground polls (audit 2026-11-25 B4).
///
/// The room sweep, KaPost's poll, the kUSDT poll and the group pass each used to wake on their
/// own schedule (20 s, 20 s, 30 s, 30-60 s), so on cellular the radio, which stays in high
/// power for about 10 s after any traffic, never went idle while K was open. Now each loop sleeps
/// to the same wall-clock beat (every 30 s on Wi-Fi, 60 s on an expensive or constrained path) and
/// they run within a second or two of each other, so the radio wakes once per beat.
///
/// A loop calls `await ForegroundBeat.sleepUntilNextBeat(offset:)` instead of a fixed
/// `Task.sleep`. `offset` spreads the loops a few hundred ms apart inside the beat, so they don't
/// hit the main actor in the same instant. Cancelling the task returns at once.
enum ForegroundBeat {
    /// 30 s on Wi-Fi, 60 s on cellular or Low Data Mode.
    @MainActor
    static var interval: TimeInterval {
        NetworkEpochMonitor.shared.isExpensivePath ? 60 : 30
    }

    /// Sleeps until the next beat (the next whole multiple of `interval` since 1970), plus
    /// `offset` seconds. Never less than one second, so a loop that just ran doesn't run twice in
    /// one beat.
    @MainActor
    static func sleepUntilNextBeat(offset: TimeInterval = 0) async {
        let delay = delayToNextBeat(interval: interval, offset: offset, now: Date())
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// The wait until the next beat; pure, for the loops that need the number.
    static func delayToNextBeat(interval: TimeInterval, offset: TimeInterval, now: Date) -> TimeInterval {
        let t = now.timeIntervalSince1970
        var next = (floor(t / interval) + 1) * interval + offset
        if next - t < 1 { next += interval }
        return next - t
    }
}
