import SwiftUI
import AVFoundation

/// Records a voice message for a public chat room with KaChat's on-chain voice settings
/// (`VoiceNotePolicy.publicChat`): 16 kbps CBR Opus in 60 ms frames, parts of at most 14.5 s,
/// up to 170 s (2:50), as long as 1 KAS of fees allows. A note of one part's length or less is
/// one untagged message; a longer one goes as tagged parts (`PublicChatService.sendPublicChatVoiceParts`).
@MainActor
final class PublicChatAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case encoding
        case failed(String)
    }

    static let policy = VoiceNotePolicy.publicChat
    static var maxDuration: TimeInterval { policy.maxSeconds }
    private static let sampleRate: Double = 48_000

    @Published private(set) var state: State = .idle
    /// Whole seconds recorded, from the recorder's own clock (`currentTime`): what the 2:50
    /// cut-off and the live fee go by, so it can't drift from what the file holds.
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    /// A call, Siri or another app took the microphone: the recording stopped there and what was
    /// recorded so far waits for Send or the trash.
    @Published private(set) var wasInterrupted = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pcmURL: URL?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.handleInterruption() }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        timer?.invalidate()
    }

    func start() {
        guard state == .idle else { return }
        Task {
            let granted = await Self.requestPermission()
            guard granted else {
                state = .failed("Microphone access denied")
                return
            }
            beginRecording()
        }
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func beginRecording() {
        do {
            // Any voice note playing stops, and none starts until the session is given back.
            VoicePlaybackCoordinator.shared.recordingWillStart()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("broadcast_rec_\(UUID().uuidString).caf")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()

            self.recorder = recorder
            self.pcmURL = url
            self.elapsedSeconds = 0
            self.wasInterrupted = false
            self.state = .recording
            startTimer()
        } catch {
            releaseAudioSession()
            state = .failed(error.localizedDescription)
        }
    }

    /// Reads the recorder's clock a few times a second, in the common run loop mode so it keeps
    /// going while the room is scrolled (the default mode pauses timers during a scroll, which
    /// held the count - and the 2:50 cut-off - back).
    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard state == .recording, let recorder else { return }
        // Only forward: a stopped recorder reads 0.
        let whole = recorder.currentTime.rounded(.down)
        if whole > elapsedSeconds { elapsedSeconds = whole }
    }

    /// The microphone was taken away: the file is closed where it got to, and the bar keeps
    /// Send and the trash for it.
    private func handleInterruption() {
        guard state == .recording, let recorder, !wasInterrupted else { return }
        tick()
        timer?.invalidate()
        timer = nil
        recorder.stop()
        wasInterrupted = true
        releaseAudioSession()
    }

    /// Gives the audio session back to what it was before recording (other apps' audio may
    /// resume). Playing a voice bubble sets its own category again.
    private func releaseAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient)
        VoicePlaybackCoordinator.shared.recordingDidEnd()
    }

    func cancel() {
        let wasActive = recorder != nil
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.delegate = nil
        recorder = nil
        if let pcmURL {
            try? FileManager.default.removeItem(at: pcmURL)
        }
        pcmURL = nil
        state = .idle
        elapsedSeconds = 0
        wasInterrupted = false
        if wasActive { releaseAudioSession() }
    }

    /// Stops recording and encodes it as the parts it goes as: at most 14.5 s each (one part,
    /// sent untagged, when it is that short), every part a complete WebM-Opus file. In order.
    /// Safe to call once `elapsedSeconds` reaches `maxDuration` too (the caller drives that cutoff).
    func stopAndEncodeParts() async throws -> [Data] {
        timer?.invalidate()
        timer = nil
        guard state == .recording, let recorder, let pcmURL else {
            throw KasiaError.networkError("Not recording")
        }
        state = .encoding
        let interrupted = wasInterrupted
        recorder.stop()
        self.recorder = nil
        wasInterrupted = false
        // An interruption already gave the session back.
        if !interrupted { releaseAudioSession() }

        defer {
            try? FileManager.default.removeItem(at: pcmURL)
            self.pcmURL = nil
            if state == .encoding { state = .idle }
        }

        let urls = try await WebMOpusEncoder.encodeParts(
            pcmURL: pcmURL,
            outputDirectory: FileManager.default.temporaryDirectory,
            bitrate: VoiceNotePolicy.bitrate,
            sampleRate: Self.sampleRate,
            frameMs: VoiceNotePolicy.frameMs,
            partSeconds: Self.policy.partSeconds,
            maxParts: VoicePartTag.maxParts,
            maxBytes: Self.policy.maxBytes
        )
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let parts = try urls.map { try Data(contentsOf: $0) }
        state = .idle
        return parts
    }

    /// Estimated WebM bytes of each part a recording of `seconds` goes as - the live fee.
    static func estimatedPartSizes(forDuration seconds: TimeInterval) -> [Int] {
        VoiceNoteLayout.partSizes(
            duration: min(seconds, maxDuration),
            partSeconds: policy.partSeconds,
            bitrate: VoiceNotePolicy.bitrate,
            frameMs: VoiceNotePolicy.frameMs,
            maxBytes: policy.maxBytes,
            sampleRate: sampleRate
        )
    }
}

/// Voice-note lengths already worked out, so a bubble scrolling back in doesn't parse its audio
/// again. Keyed by the audio itself (its size and hash), so two notes never share an entry.
enum VoiceNoteDurationCache {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 1_000
        return cache
    }()

    static func duration(forKey key: String, compute: () -> TimeInterval?) -> TimeInterval? {
        if let cached = cache.object(forKey: key as NSString) { return cached.doubleValue }
        guard let duration = compute() else { return nil }
        cache.setObject(NSNumber(value: duration), forKey: key as NSString)
        return duration
    }

    static func key(for data: Data) -> String { "1:\(data.count):\(data.hashValue)" }

    static func key(for input: PublicChatVoiceNoteInput) -> String {
        "\(input.count):\(input.signature):\(input.partContents.hashValue)"
    }
}

/// A long voice note's parts as the bubble plays them: the parts present, in index order.
struct PublicChatVoiceNoteInput: Equatable {
    /// How many parts the note has in all.
    let count: Int
    /// The parts present, in index order, as their messages read (the voice-message JSON). The
    /// audio is decoded only off the main thread, when the player needs it: decoding every part
    /// here ran on each pass of the room's body, and a room with more notes than the decode cache
    /// holds did it again every time.
    let partContents: [String]

    var isComplete: Bool { partContents.count >= count }
    /// Changes whenever a part arrives.
    var signature: String { partContents.map { String($0.utf8.count) }.joined(separator: ",") }

    /// The parts' audio, in order. Off the main thread only.
    static func decodedParts(_ contents: [String]) -> [Data] {
        contents.compactMap { VoiceMessageSniff.decode($0)?.data }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.signature == rhs.signature
    }
}

/// Plays a long voice note as one recording: every part present is decoded and joined with no
/// gap (`WebMOpusDecoder.decodePartsToPCMFile`), so the length is the total and seeking
/// crosses parts. Parts that arrive later are picked up on the next Play.
@MainActor
final class PublicChatMultipartAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var durationText = "0:00"
    /// The note's shape for the waveform, as 1:1 chats draw it (`VoiceNoteInfoCache`).
    @Published private(set) var waveformSamples: [Float] = []

    private var player: AVAudioPlayer?
    private var playbackURL: URL?
    private var playbackSignature: String?
    private var loadedSignature: String?
    private var duration: TimeInterval?
    private var progressTimer: Timer?
    /// A seek made before playback started: where the next Play begins.
    private var pendingSeekFraction: Double?

    /// The length of the parts present, again whenever a part arrives (unless playing). Read
    /// from the parts' packets without decoding them (`WebMOpusDecoder.duration(ofParts:)`) and
    /// kept in `VoiceNoteDurationCache`, so scrolling a bubble back in costs nothing; the audio is
    /// decoded only on Play.
    /// The length and waveform come from `VoiceNoteInfoCache` when this note was read before;
    /// otherwise the parts are decoded once off the main thread (as a 1:1 voice note's are) and
    /// cached, so scrolling the bubble back in costs nothing.
    func preload(_ input: PublicChatVoiceNoteInput) {
        let signature = input.signature
        guard loadedSignature != signature, !isPlaying else { return }
        loadedSignature = signature
        let key = "room|" + VoiceNoteDurationCache.key(for: input)
        if let info = VoiceNoteInfoCache.info(forKey: key) {
            apply(info)
            isLoading = false
            return
        }
        isLoading = duration == nil
        let contents = input.partContents
        Task.detached(priority: .utility) { [weak self] in
            let decoded = try? WebMOpusDecoder.decodePartsToPCMFile(parts: PublicChatVoiceNoteInput.decodedParts(contents))
            if let url = decoded?.url { try? FileManager.default.removeItem(at: url) }
            let info = decoded.map { VoiceNoteInfoCache.Info(duration: $0.duration, waveform: $0.waveform) }
            if let info { VoiceNoteInfoCache.store(info, forKey: key) }
            await MainActor.run {
                guard let self, self.loadedSignature == signature else { return }
                if let info {
                    self.apply(info)
                } else if self.waveformSamples.isEmpty {
                    self.waveformSamples = Array(repeating: 0.3, count: 40)
                }
                self.isLoading = false
            }
        }
    }

    private func apply(_ info: VoiceNoteInfoCache.Info) {
        waveformSamples = info.waveform
        guard player == nil else { return }
        duration = info.duration
        if !isPlaying { durationText = Self.formatted(info.duration) }
    }

    func toggle(_ input: PublicChatVoiceNoteInput) {
        if isPlaying {
            pause()
            return
        }
        // Paused on the same parts: carry on from there.
        if let player, playbackSignature == input.signature {
            if let fraction = pendingSeekFraction {
                player.currentTime = fraction * player.duration
                pendingSeekFraction = nil
            }
            start(player)
            return
        }
        let seek = pendingSeekFraction
        stop()
        pendingSeekFraction = seek
        isLoading = true
        let signature = input.signature
        let contents = input.partContents
        Task.detached(priority: .userInitiated) { [weak self] in
            let parts = PublicChatVoiceNoteInput.decodedParts(contents)
            let decoded = try? WebMOpusDecoder.decodePartsToPCMFile(parts: parts)
            await MainActor.run {
                guard let self else {
                    if let url = decoded?.url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.isLoading = false
                guard let decoded else { return }
                do {
                    let player = try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
                    player.delegate = self
                    player.prepareToPlay()
                    self.playbackURL = decoded.url
                    self.playbackSignature = signature
                    self.player = player
                    self.duration = decoded.duration
                    self.waveformSamples = decoded.waveform
                    if let fraction = self.pendingSeekFraction {
                        player.currentTime = fraction * player.duration
                        self.pendingSeekFraction = nil
                    }
                    self.start(player)
                } catch {
                    try? FileManager.default.removeItem(at: decoded.url)
                }
            }
        }
    }

    /// The scrubber: 0...1 across the whole note.
    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        progress = clamped
        if let player {
            player.currentTime = clamped * player.duration
            durationText = Self.formatted(player.currentTime)
        } else {
            pendingSeekFraction = clamped
            if let duration { durationText = Self.formatted(clamped * duration) }
        }
    }

    private func start(_ player: AVAudioPlayer) {
        // One note at a time: the one playing before pauses here.
        guard VoicePlaybackCoordinator.shared.willStart(self, stop: { [weak self] in self?.pause() }) else {
            stop()
            return
        }
        guard player.play() else {
            stop()
            return
        }
        isPlaying = true
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if player.duration > 0 { self.progress = player.currentTime / player.duration }
                self.durationText = Self.formatted(player.currentTime)
            }
        }
    }

    private func pause() {
        player?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        VoicePlaybackCoordinator.shared.didStop(self)
    }

    private func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        playbackSignature = nil
        if let playbackURL {
            try? FileManager.default.removeItem(at: playbackURL)
            self.playbackURL = nil
        }
        isPlaying = false
        progress = 0
        pendingSeekFraction = nil
        if let duration { durationText = Self.formatted(duration) }
        VoicePlaybackCoordinator.shared.didStop(self)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    private static func formatted(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.isFinite ? duration : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    deinit {
        progressTimer?.invalidate()
        VoicePlaybackCoordinator.shared.didStop(self)
        if let playbackURL {
            try? FileManager.default.removeItem(at: playbackURL)
        }
    }
}

/// The one bubble of a voice note in a room, one part or many: play, the waveform as a scrubber
/// across every part, the total length, and while parts are still on their way, "Receiving… 7 of
/// 12". A one-part note is a long one with a single part.
struct PublicChatVoiceNoteBubble: View {
    let input: PublicChatVoiceNoteInput
    let isOwnMessage: Bool
    @StateObject private var player = PublicChatMultipartAudioPlayer()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(input)
            } label: {
                if player.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.scaled(size: 32))
                }
            }
            .disabled(player.isLoading)

            // As a 1:1 voice note draws it (owner, 2026-11-25): the waveform, dragged to scrub.
            VStack(alignment: .leading, spacing: 4) {
                WaveformView(
                    samples: player.waveformSamples,
                    progress: player.progress,
                    isOutgoing: isOwnMessage
                )
                .frame(height: 24)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard geometry.size.width > 0 else { return }
                                        player.seek(toFraction: value.location.x / geometry.size.width)
                                    }
                            )
                    }
                }

                Text(player.durationText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(isOwnMessage ? .white.opacity(0.8) : .secondary)
                if !input.isComplete {
                    Text("Receiving… \(input.partContents.count) of \(input.count)")
                        .font(.caption2)
                        .foregroundColor(isOwnMessage ? .white.opacity(0.8) : .secondary)
                }
            }
        }
        .foregroundColor(isOwnMessage ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 180, alignment: .leading)
        .onAppear { player.preload(input) }
        .onChange(of: input.signature) { _ in player.preload(input) }
    }
}
