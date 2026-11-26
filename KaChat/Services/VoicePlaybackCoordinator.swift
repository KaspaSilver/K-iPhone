import AVFoundation

/// One voice note plays at a time, and the audio session is given back when it stops.
///
/// Every voice bubble owns its own player, so without this two notes could play over each other,
/// and the session stayed active after a note ended, so music another app was playing never
/// resumed. A player calls `willStart` right before it plays (the one playing before is stopped,
/// and the session is set to `.playback` and made active) and `didStop` when it pauses, stops or
/// finishes (the session is deactivated with `.notifyOthersOnDeactivation`). The players that do:
/// room bubbles (`PublicChatMultipartAudioPlayer`), 1:1 and group bubbles (`AudioPlaybackHelper`,
/// `MultipartAudioPlaybackHelper` in MessageBubbleView.swift) and both composers' previews
/// (ChatDetailView, `VoiceNoteRecorder`), and the Nextcloud viewer's video and audio
/// (`NextcloudMediaPlayback`). Audio that doesn't go through here keeps the session as it leaves
/// it. An interruption (a call, Siri) stops whichever of them is playing.
///
/// The recorders (`PublicChatAudioRecorder`, `VoiceNoteRecorder`, ChatDetailView's) set
/// `.playAndRecord` only while they record: `recordingWillStart` stops any note playing, nothing
/// plays until `recordingDidEnd`, and each recorder deactivates the session itself (with
/// `.notifyOthersOnDeactivation`, back to `.soloAmbient`) before calling it. Nothing needs a
/// category set at launch: each user sets its own right before it activates the session.
///
/// Main thread only.
final class VoicePlaybackCoordinator: @unchecked Sendable {
    static let shared = VoicePlaybackCoordinator()

    private var currentOwner: ObjectIdentifier?
    private var stopCurrent: (() -> Void)?
    private var isRecording = false
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        // A call or Siri pauses the player under us, but its bubble or preview still showed
        // "playing" and the next tap only "stopped" it (audit 2026-11-25 M5). Stopping the owner
        // puts its button back to Play. On the main queue: the coordinator is main-thread only.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.stopPrevious()
        }
    }

    /// Stops whatever note is playing and readies the session for `owner`'s playback. False when
    /// the session couldn't be set up, or while a recording is in progress: the caller doesn't play.
    @discardableResult
    func willStart(_ owner: AnyObject, stop: @escaping () -> Void) -> Bool {
        guard !isRecording else { return false }
        let id = ObjectIdentifier(owner)
        if currentOwner != id { stopPrevious() }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            AppLog.log("[VoicePlayback] Couldn't start the audio session: %@", error.localizedDescription)
            if currentOwner == id {
                currentOwner = nil
                stopCurrent = nil
            }
            return false
        }
        currentOwner = id
        stopCurrent = stop
        return true
    }

    /// `owner` paused, stopped or finished. If it was the one playing, the session is given back
    /// so other apps' audio can resume.
    func didStop(_ owner: AnyObject) {
        guard currentOwner == ObjectIdentifier(owner) else { return }
        currentOwner = nil
        stopCurrent = nil
        guard !isRecording else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The recorder is about to take the session: any note playing stops first.
    func recordingWillStart() {
        stopPrevious()
        isRecording = true
    }

    /// The recorder gave the session back.
    func recordingDidEnd() {
        isRecording = false
    }

    private func stopPrevious() {
        // Cleared before the call, so the stopped player's own `didStop` doesn't deactivate the
        // session the next player is about to use.
        let previous = stopCurrent
        currentOwner = nil
        stopCurrent = nil
        previous?()
    }
}
