import ImageIO
import UIKit
import SwiftUI

struct PreparedChatImage {
    let data: Data
    let fileName: String
    let mimeType: String
}

/// Prepares a picked photo for sending as a chat message, matching Android's
/// `ImagePrep.prepareForChatMessage` byte budget/dimension approach so a photo sent from either
/// platform lands at a similar on-chain payload size.
enum ImagePrep {
    enum PrepError: Error {
        case invalidImage
        case compressionFailed
    }

    /// Longest edge cap in pixels before compression (small images: group and contact photos).
    static let chatMaxDimension: CGFloat = 1280
    /// The default budget of `prepareForChatMessage` (small images only; chat photos go by
    /// `PhotoTier`).
    static let defaultChatTargetBytes = 20_000
    private static let maxShrinkAttempts = 4
    private static let shrinkFactor: CGFloat = 0.7

    /// Normalizes to a standard-range bitmap, downsamples, and JPEG-compresses, binary-searching
    /// quality to fit `targetBytes` and shrinking dimensions further if quality reduction alone
    /// isn't enough.
    ///
    /// AVIF was tried here previously (matching Android's approach for smaller on-chain payloads)
    /// but was removed: while iOS's own AVIF encode/decode is reliable (guaranteed by ImageIO
    /// since iOS 16), AVIF *decode* support on Android is inconsistent across devices/OS builds -
    /// an iPhone-sent AVIF photo could permanently fail to render for an Android recipient with no
    /// way to detect or recover from that in advance. JPEG decodes everywhere, on every device on
    /// both platforms, so it's the only format guaranteed to actually reach the other person.
    static func prepareForChatMessage(
        _ image: UIImage,
        targetBytes: Int = defaultChatTargetBytes
    ) throws -> PreparedChatImage {
        let data = try prepareJPEGForChatMessage(image, targetBytes: targetBytes)
        return PreparedChatImage(data: data, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    static func prepareJPEGForChatMessage(
        _ image: UIImage,
        targetBytes: Int = defaultChatTargetBytes
    ) throws -> Data {
        try prepareEncodedDataForChatMessage(image, targetBytes: targetBytes, encoder: jpegData)
    }

    private static func prepareEncodedDataForChatMessage(
        _ image: UIImage,
        targetBytes: Int,
        encoder: (UIImage, CGFloat) -> Data?
    ) throws -> Data {
        var currentImage = try normalizedAndDownscaled(image, maxDimension: chatMaxDimension)

        for _ in 0..<maxShrinkAttempts {
            if let data = compressToQualityBudget(
                currentImage,
                targetBytes: targetBytes,
                encoder: encoder
            ) {
                return data
            }
            let newSize = CGSize(
                width: currentImage.size.width * shrinkFactor,
                height: currentImage.size.height * shrinkFactor
            )
            currentImage = resize(currentImage, to: newSize)
        }

        // Last resort: send whatever the lowest quality produces even if still over budget,
        // rather than rejecting the photo outright.
        guard let data = encoder(currentImage, 0.05) else {
            throw PrepError.compressionFailed
        }
        return data
    }

    // MARK: - Quality tiers (on-chain chat photos)

    /// Long edges tried for a tier, largest first: a big budget buys a big image at a decent
    /// quality, not a small one at quality 1.
    static let tierEdges: [CGFloat] = [3000, 2560, 2240, 2048, 1920, 1600, 1440, 1280, 1080, 960, 800, 640, 480, 360]
    /// The JPEG quality range searched at each edge.
    static let tierMaxQuality: CGFloat = 0.85
    static let tierMinQuality: CGFloat = 0.5

    /// The best-looking JPEG within each of `budgets` bytes, by budget: the LARGEST long edge
    /// (never upscaled) at which quality `tierMinQuality` fits, then the highest quality up to
    /// `tierMaxQuality` that still fits there. Only when nothing fits at `tierMinQuality` even at
    /// the smallest edge does the quality go lower. The image is re-rendered into a fresh
    /// standard-range bitmap, so orientation is applied and nothing of the original's metadata
    /// (EXIF, GPS, camera) is carried, as before. Heavy: call it off the main thread.
    ///
    /// Renders are reused across budgets one at a time, and the quality-0.5 size measured at one
    /// edge predicts the others (size ~ edge squared), so a small budget skips the big edges.
    static func prepareJPEGForTiers(_ image: UIImage, budgets: [Int]) throws -> [Int: Data] {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else {
            throw PrepError.invalidImage
        }
        let originalEdge = max(image.size.width, image.size.height)
        var edges = tierEdges.filter { $0 < originalEdge }
        edges.insert(min(originalEdge, tierEdges[0]), at: 0)

        var renderedEdge: CGFloat?
        var rendered: UIImage?
        func render(_ edge: CGFloat) -> UIImage {
            if renderedEdge == edge, let rendered { return rendered }
            let scale = edge / originalEdge
            let scaled = resize(image, to: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            renderedEdge = edge
            rendered = scaled
            return scaled
        }
        var minQualitySize: [CGFloat: Int] = [:]
        func sizeAtMinQuality(_ edge: CGFloat) -> (Int, Data)? {
            guard let data = jpegData(from: render(edge), quality: tierMinQuality) else { return nil }
            minQualitySize[edge] = data.count
            return (data.count, data)
        }
        func predicted(_ edge: CGFloat) -> Int? {
            guard let (known, size) = minQualitySize.max(by: { $0.key < $1.key }) else { return nil }
            return Int(Double(size) * Double(edge * edge) / Double(known * known))
        }

        var results: [Int: Data] = [:]
        for budget in budgets.sorted(by: >) {
            var chosen: Data?
            for edge in edges {
                if let known = minQualitySize[edge], known > budget { continue }
                if minQualitySize[edge] == nil, let guess = predicted(edge), guess > budget * 13 / 10 { continue }
                guard let (size, floorData) = sizeAtMinQuality(edge), size <= budget else { continue }
                // Fits at the floor: the best quality that still fits, at this edge.
                var best = floorData
                var low = tierMinQuality
                var high = tierMaxQuality
                for _ in 0..<6 {
                    let mid = (low + high) / 2
                    guard let data = jpegData(from: render(edge), quality: mid) else { break }
                    if data.count <= budget {
                        best = data
                        low = mid
                    } else {
                        high = mid
                    }
                }
                chosen = best
                break
            }
            if chosen == nil, let smallest = edges.last {
                // Nothing fits at the quality floor: the smallest edge, below the floor.
                chosen = compressToQualityBudget(render(smallest), targetBytes: budget, encoder: jpegData)
                    ?? jpegData(from: render(smallest), quality: 0.05)
            }
            guard let chosen else { throw PrepError.compressionFailed }
            results[budget] = chosen
        }
        return results
    }

    /// The tier's photo on a path - one JPEG within its byte budget.
    static func prepareForTier(_ image: UIImage, tier: PhotoTier, forGroup group: Bool) throws -> PreparedChatImage {
        let budget = tier.maxBytes(forGroup: group)
        guard let data = try prepareJPEGForTiers(image, budgets: [budget])[budget] else {
            throw PrepError.compressionFailed
        }
        return PreparedChatImage(data: data, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    private static func normalizedAndDownscaled(
        _ image: UIImage,
        maxDimension: CGFloat
    ) throws -> UIImage {
        guard image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            throw PrepError.invalidImage
        }

        let longestEdge = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longestEdge)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return resize(image, to: newSize)
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width >= 1, size.height >= 1 else { return image }

        // Photos can arrive as HDR/extended-sRGB images. Passing those directly to
        // `UIImage.jpegData` makes ImageIO perform an accelerated extended-range conversion;
        // on Mac Catalyst that conversion can abort inside QuartzCore while creating a Metal
        // context. Render once into an explicitly standard-range bitmap so every later JPEG
        // attempt works with ordinary 8-bit color data.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            image.draw(in: bounds)
        }
    }

    /// Binary-searches encoder quality for the highest quality that still fits `targetBytes`.
    /// Returns nil if even the lowest quality tried doesn't fit - the caller should shrink the
    /// image's dimensions and try again rather than degrade quality further.
    private static func compressToQualityBudget(
        _ image: UIImage,
        targetBytes: Int,
        encoder: (UIImage, CGFloat) -> Data?
    ) -> Data? {
        var low: CGFloat = 0.05
        var high: CGFloat = 0.95

        guard let lowestQualityData = encoder(image, low),
              lowestQualityData.count <= targetBytes else {
            return nil
        }

        var best = lowestQualityData
        for _ in 0..<8 {
            let mid = (low + high) / 2
            guard let data = encoder(image, mid) else { break }
            if data.count <= targetBytes {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }

    private static func jpegData(from image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Animated GIFs sent on chain (MESSAGING.md, "GIFs"): picked from Photos (the composer's GIF
/// tile shows only animated images), pasted or dropped. Each `PhotoTier` buys the largest GIF
/// that fits its byte budget: re-encoded at a smaller long edge, then with every second or third
/// frame (a kept frame stays up for the dropped ones' time), so it still plays at its own speed.
/// Re-encoding also leaves out every bit of metadata. The result is always `image/gif`, which
/// every platform decodes.
enum GIFPrep {
    enum GIFError: Error {
        case notAnimated
    }

    /// Longest edges tried, largest first (never larger than the GIF itself).
    private static let edges: [CGFloat] = [480, 400, 360, 320, 280, 240, 200, 160, 128, 96]
    private static let frameSteps = [1, 2, 3]
    /// What is read of a long GIF: a few seconds is what fits on chain anyway.
    private static let maxFrames = 300
    private static let maxSeconds: Double = 30

    /// More than one frame: an animated GIF, WebP, PNG or HEIC sequence.
    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The largest GIF a chat plays. Playing decodes every frame at full size, so a file of a
    /// few KB declaring huge frames could ask for gigabytes. GIFs sent from here are at most
    /// `edges[0]` (480 px) and `maxFrames`, well inside.
    static let maxPlayEdge = 1024
    static let maxPlayFrames = maxFrames

    /// A real GIF (whatever MIME type the message claims), animated and within `maxPlayEdge` and
    /// `maxPlayFrames`. Reads only headers, but call it off the main thread where possible.
    /// Anything else shows its still picture.
    static func isSafeToAnimate(_ data: Data) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif" else {
            return false
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= maxPlayFrames else { return false }
        // The canvas, where the file gives it, and every frame: any one too big refuses it.
        if let file = CGImageSourceCopyProperties(source, options) as? [CFString: Any],
           let gif = file[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            let width = (gif[kCGImagePropertyGIFCanvasPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (gif[kCGImagePropertyGIFCanvasPixelHeight] as? NSNumber)?.intValue ?? 0
            guard max(width, height) <= maxPlayEdge else { return false }
        }
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, max(width, height) <= maxPlayEdge else {
                return false
            }
        }
        return true
    }

    /// How long frame `index` shows, as browsers read it: a delay under 20 ms means 100 ms.
    static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in dictionaries {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let delay = (dictionary[unclampedKey] as? Double) ?? (dictionary[clampedKey] as? Double) ?? 0
            return delay < 0.02 ? 0.1 : delay
        }
        return 0.1
    }

    /// The GIF each budget buys, keyed by budget. A budget nothing fits (a very long GIF at the
    /// smallest size and every third frame) has no entry.
    static func prepareForTiers(_ data: Data, budgets: [Int]) throws -> [Int: Data] {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 1 else {
            throw GIFError.notAnimated
        }
        let largest = edges[0]
        var frames: [(image: CGImage, delay: Double)] = []
        var seconds = 0.0
        for index in 0..<min(CGImageSourceGetCount(source), maxFrames) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: largest
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            let delay = frameDelay(source, at: index)
            frames.append((image, delay))
            seconds += delay
            if seconds >= maxSeconds { break }
        }
        guard frames.count > 1 else { throw GIFError.notAnimated }

        let ownEdge = CGFloat(frames.map { max($0.image.width, $0.image.height) }.max() ?? Int(largest))
        let top = min(ownEdge, largest)
        let candidateEdges = [top] + edges.filter { $0 < top }

        var open = Set(budgets)
        var results: [Int: Data] = [:]
        for edge in candidateEdges {
            let scaled = edge >= ownEdge ? frames.map(\.image) : frames.compactMap { scale($0.image, toLongEdge: edge) }
            guard scaled.count == frames.count else { continue }
            for step in frameSteps {
                guard !open.isEmpty else { return results }
                var kept: [(CGImage, Double)] = []
                for start in stride(from: 0, to: frames.count, by: step) {
                    let delay = frames[start..<min(start + step, frames.count)].reduce(0) { $0 + $1.delay }
                    kept.append((scaled[start], delay))
                }
                guard kept.count > 1, let encoded = encode(kept) else { continue }
                for budget in open where encoded.count <= budget {
                    results[budget] = encoded
                    open.remove(budget)
                }
            }
        }
        return results
    }

    private static func scale(_ image: CGImage, toLongEdge edge: CGFloat) -> CGImage? {
        let long = CGFloat(max(image.width, image.height))
        guard long > 0 else { return nil }
        let factor = edge / long
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A looping GIF of `frames`, nothing but the frames and their delays.
    private static func encode(_ frames: [(CGImage, Double)]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "com.compuserve.gif" as CFString, frames.count, nil) else {
            return nil
        }
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        for (image, delay) in frames {
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Plays an animated GIF from its bytes (SwiftUI's `Image` shows only the first frame). ImageIO
/// decodes one frame at a time, at the file's own timing (`CGAnimateImageDataWithBlock`), so a
/// long GIF costs one frame of memory, not all of them. Only what `GIFPrep.isSafeToAnimate`
/// allows plays; anything else leaves the view empty, so callers check first and show the still.
/// Stops when the view leaves the screen.
struct AnimatedImageView: UIViewRepresentable {
    let data: Data
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = contentMode
        context.coordinator.player.play(data, in: view)
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.player.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let player = ImageAnimationPlayer()
    }
}

/// Runs one animation into a `UIImageView`; `play` with other bytes replaces it, the same bytes
/// keep it going.
final class ImageAnimationPlayer {
    private var generation = 0
    private var playing: Data?
    /// Where the playing bytes live: the same buffer handed in again (every redraw of the chat
    /// while it scrolls) is known at once, without comparing the whole GIF byte by byte.
    private var playingAddress: UnsafeRawPointer?

    private func isPlaying(_ data: Data) -> Bool {
        guard let playing, playing.count == data.count else { return false }
        let address = data.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }
        if let address, address == playingAddress { return true }
        return playing == data
    }

    func play(_ data: Data, in view: UIImageView) {
        guard !isPlaying(data) else { return }
        stop()
        playing = data
        playingAddress = data.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }
        // Callers check this off the main thread already; checked again here because one frame
        // of an unchecked file can be gigabytes. `playing` is set first so it's checked once.
        guard GIFPrep.isSafeToAnimate(data) else { return }
        let current = generation
        _ = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self, weak view] _, image, stop in
            guard let self, let view, self.generation == current else {
                stop.pointee = true
                return
            }
            view.image = UIImage(cgImage: image)
        }
    }

    func stop() {
        generation &+= 1
        playing = nil
        playingAddress = nil
    }
}
