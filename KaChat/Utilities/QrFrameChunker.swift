import Foundation
import CryptoKit

/// Multi-frame (animated) QR chunking. K writes v1.0.7 frames (below), which every KasSigner reads,
/// and reads both those and v1.1's (`Accumulator`, `V11`). The v1.0.7 scheme matches KasSigner's
/// own raw-byte scheme exactly —
/// verified against `kassee/src/qr.rs` and the device firmware's `process_multiframe`/
/// `is_multiframe` (`bootloader/src/handlers/camera_loop.rs`). Fully symmetric: the same
/// chunker/dechunker works whether KaChat is sending an unsigned KSPT to the device or receiving
/// the signed one back. Port of the Android client's `QrFrameChunker.kt`, same wire format.
///
/// ```
/// <=134 bytes total: no wrapper at all — the raw payload is a single QR frame.
/// otherwise: [frameNum(1)] [totalFrames(1)] [fragLen(1)] [fragment(fragLen bytes)], balanced
///            across frames (not simply 106 bytes each except possibly the last), capped at
///            64 frames, each frame zero-padded to a minimum of 20 bytes for reliable scanning.
/// ```
enum QrFrameChunker {
    static let singleFrameMax = 134
    static let maxFrameData = 106
    static let maxFrames = 64
    private static let minFrameSize = 20
    private static let headerSize = 3

    enum ChunkError: LocalizedError {
        case payloadTooLarge(Int)
        case fragmentOverflow

        var errorDescription: String? {
            switch self {
            case .payloadTooLarge(let n): return "Payload too large to chunk into QR frames (\(n) bytes)"
            case .fragmentOverflow: return "Chunk fragment overflowed a single byte length field"
            }
        }
    }

    static func chunk(_ data: Data) throws -> [Data] {
        if data.count <= singleFrameMax { return [data] }

        let totalFrames = Int(ceil(Double(data.count) / Double(maxFrameData)))
        guard totalFrames <= maxFrames else { throw ChunkError.payloadTooLarge(data.count) }
        let perFrame = Int(ceil(Double(data.count) / Double(totalFrames)))

        var frames: [Data] = []
        var offset = 0
        let bytes = [UInt8](data)
        for frameNum in 0..<totalFrames {
            let end = min(offset + perFrame, bytes.count)
            let fragment = Array(bytes[offset..<end])
            guard fragment.count <= 255 else { throw ChunkError.fragmentOverflow }

            var frame = [UInt8]()
            frame.append(UInt8(frameNum))
            frame.append(UInt8(totalFrames))
            frame.append(UInt8(fragment.count))
            frame.append(contentsOf: fragment)
            if frame.count < minFrameSize {
                frame.append(contentsOf: [UInt8](repeating: 0, count: minFrameSize - frame.count))
            }
            frames.append(Data(frame))
            offset = end
        }
        return frames
    }

    /// Reassembles frames scanned in any order (or with duplicates/retries) as the camera happens
    /// to catch them mid-animation. `isComplete` identifies a payload that arrived as a single,
    /// unwrapped QR frame (no multi-frame header) — pass a magic-byte check like
    /// `KsptCodec.looksLikeKspt` for whatever payload type is being scanned.
    ///
    /// Two frame layouts are read, never mixed in one set:
    /// - v1.0.7's `[index, total, fragLen, fragment]` (what K writes, and what a KasSigner shows
    ///   for a single-key 0x01 request's reply);
    /// - v1.1's (KasSigner `crates/kassigner-protocol/src/frame.rs`), which the unit uses for
    ///   every other reply, every 0x06 (quantum) one included, even when it fits one code:
    ///   `[0x1B, format, index, total, tag]`, frame 0 three more digest bytes, then the
    ///   fragment. The fragments in index order are the payload, and the first four bytes of its
    ///   SHA-256 must be the digest frame 0 named, so frames of two transmissions are never
    ///   joined into a transaction nobody sent.
    ///
    /// A v1.0.7 frame can't be taken for a v1.1 one: index 0x1B needs a total of 28 or more,
    /// and no v1.1 format byte is in 28...64.
    final class Accumulator {
        private enum Layout: Equatable { case v107, v11 }

        private let isComplete: (Data) -> Bool
        private let v11Format: UInt8
        private var layout: Layout?
        private var totalFrames: Int?
        private var received: [Int: Data] = [:]
        // v1.1 only: the stream's format, its tag (the digest's first byte, in every frame), and
        // the whole digest once frame 0 has been seen.
        private var tag: UInt8?
        private var digest: Data?

        /// `v11Format` is the v1.1 format byte to collect (`V11.formatKspt` for a signed KSPT);
        /// v1.1 frames of any other format are something else in view and are ignored.
        init(v11Format: UInt8 = V11.formatKspt, isComplete: @escaping (Data) -> Bool) {
            self.v11Format = v11Format
            self.isComplete = isComplete
        }

        /// Feed one scanned frame's raw bytes. Returns the reassembled payload once every frame
        /// has arrived (and, for v1.1, matches its digest), else nil.
        func addFrame(_ bytes: Data) -> Data? {
            if isComplete(bytes) { return bytes }
            let arr = [UInt8](bytes)
            if V11.isFrame(arr) { return addV11(arr) }
            return addV107(arr)
        }

        private func addV107(_ arr: [UInt8]) -> Data? {
            guard arr.count >= QrFrameChunker.headerSize else { return nil }
            let frameNum = Int(arr[0])
            let total = Int(arr[1])
            let fragLen = Int(arr[2])
            guard (2...QrFrameChunker.maxFrames).contains(total), frameNum < total, fragLen > 0 else { return nil }
            guard arr.count >= QrFrameChunker.headerSize + fragLen else { return nil }

            // A v1.1 set in progress names its payload; a bare shape match here is more likely
            // something else in view than the unit switching layouts, so it doesn't wipe it.
            if layout == .v11 { return nil }
            // A frame from a different scan (mismatched total) — reset and start over rather
            // than silently mixing two different transactions' fragments together.
            if totalFrames != total { reset() }
            layout = .v107
            totalFrames = total
            received[frameNum] = Data(arr[QrFrameChunker.headerSize..<(QrFrameChunker.headerSize + fragLen)])
            return assembled()
        }

        private func addV11(_ arr: [UInt8]) -> Data? {
            let format = arr[1]
            let index = Int(arr[2])
            let total = Int(arr[3])
            // Another kind of payload (a kpub, a PSKB...) on screen: not ours, and not a reason
            // to drop what we hold.
            guard format == v11Format else { return nil }
            guard total > 0, index < total, total <= V11.maxFrames else { return nil }
            let header = index == 0 ? V11.firstHeaderLen : V11.headerLen
            guard arr.count >= header else { return nil }
            let frameTag = arr[V11.headerLen - 1]
            let frameDigest: Data? = index == 0 ? Data(arr[(V11.headerLen - 1)..<header]) : nil
            let fragment = Data(arr[header...])

            // Another transmission: the count or tag changed, or frame 0 names another digest
            // (the unit rebuilt its reply, or a second screen is in view). Start over with it.
            if layout != .v11 || totalFrames != total || tag != frameTag {
                reset()
            } else if let frameDigest, let digest, frameDigest != digest {
                reset()
            } else if let held = received[index], held != fragment {
                // A sender never changes a frame: two transmissions are mixed.
                reset()
            }
            layout = .v11
            totalFrames = total
            tag = frameTag
            if let frameDigest { digest = frameDigest }
            received[index] = fragment

            guard let payload = assembled() else { return nil }
            // Complete: it must be the payload frame 0 named.
            guard let digest, V11.digest(of: payload) == digest else {
                reset()
                return nil
            }
            return payload
        }

        private func assembled() -> Data? {
            guard let expected = totalFrames, received.count >= expected else { return nil }
            var out = Data()
            for i in 0..<expected {
                guard let piece = received[i] else { return nil }
                out.append(piece)
            }
            return out
        }

        /// (received, total) — nil until the first valid frame arrives.
        var progress: (received: Int, total: Int)? {
            totalFrames.map { (received.count, $0) }
        }

        /// Which frame indices have arrived so far — for a per-slot progress indicator (frames
        /// can arrive out of order).
        var receivedFrameIndices: Set<Int> { Set(received.keys) }

        func reset() {
            layout = nil
            totalFrames = nil
            received.removeAll()
            tag = nil
            digest = nil
        }
    }

    /// KasSigner v1.1's frame layout (`frame.rs`): the constants and the writer's even split, the
    /// latter only so host tests can build a unit's frames.
    enum V11 {
        static let magic: UInt8 = 0x1B
        static let formatKspt: UInt8 = 1
        /// Every format value frame.rs defines (Kspt, Pskb, Kpub, Descriptor, Container, Opaque).
        static let knownFormats: Set<UInt8> = [1, 2, 3, 4, 5, 0xFF]
        static let headerLen = 5
        static let digestLen = 4
        static let firstHeaderLen = headerLen + digestLen - 1
        /// A unit shows a few frames for a reply; this only bounds what a stray code can claim.
        static let maxFrames = 64

        static func isFrame(_ arr: [UInt8]) -> Bool {
            arr.count >= headerLen && arr[0] == magic && knownFormats.contains(arr[1])
        }

        static func digest(of payload: Data) -> Data {
            Data(SHA256.hash(data: payload).prefix(digestLen))
        }

        /// frame.rs `write_split`: split evenly with frame 0's three extra header bytes counted
        /// against its fragment. `perFrame` is the unit's bytes per frame past the 5-byte header.
        static func frames(of payload: Data, format: UInt8 = formatKspt, perFrame: Int = 225) -> [Data] {
            let extra = firstHeaderLen - headerLen
            guard !payload.isEmpty, perFrame > 0 else { return [] }
            let total = max(1, (payload.count + extra + perFrame - 1) / perFrame)
            let per = (payload.count + extra + total - 1) / total
            let digest = [UInt8](digest(of: payload))
            let bytes = [UInt8](payload)
            var out: [Data] = []
            for i in 0..<total {
                let start = max(0, i * per - extra)
                let end = min(max(0, (i + 1) * per - extra), bytes.count)
                guard start < end else { break }
                var frame: [UInt8] = [magic, format, UInt8(i), UInt8(total)]
                frame.append(contentsOf: i == 0 ? digest : [digest[0]])
                frame.append(contentsOf: bytes[start..<end])
                out.append(Data(frame))
            }
            return out
        }
    }
}
