import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import os

/// A decoded background bitmap and the part of the image it covers.
struct RenderedBackground: @unchecked Sendable {
    // CGImage is immutable and safe to share across threads.
    let image: CGImage
    /// Covered region in logical image points with a top-left origin.
    let region: CGRect

    var byteCount: Int { image.bytesPerRow * image.height }
}

/// Decodes only the bitmaps that visible displays and previews need, and releases them afterward.
@MainActor
final class BackgroundImageRenderer {
    private let store: BackgroundImageStore
    private let byteBudget: Int
    private var cache: [BackgroundRenderRequest: RenderedBackground] = [:]
    private var recency: [BackgroundRenderRequest] = []
    /// Decodes in progress. Releasing a variant drops its entry, so a late result is not cached.
    private var inFlight: [BackgroundRenderRequest: Task<RenderedBackground?, Never>] = [:]
    private let logger = Logger(subsystem: Log.subsystem, category: "Background")

    init(store: BackgroundImageStore, byteBudget: Int = 160 * 1024 * 1024) {
        self.store = store
        self.byteBudget = byteBudget
    }

    var cachedByteCount: Int { cache.values.reduce(0) { $0 + $1.byteCount } }
    var cachedVariantCount: Int { cache.count }
    var pendingDecodeCount: Int { inFlight.count }

    /// Returns a cached bitmap or decodes one off the main actor. `nil` means fall back to color.
    func image(for request: BackgroundRenderRequest) async -> RenderedBackground? {
        if let cached = cache[request] {
            touch(request)
            return cached
        }
        if let pending = inFlight[request] {
            return await pending.value
        }
        let url = store.url(for: request.image)
        let task = Task.detached(priority: .userInitiated) {
            BackgroundImageDecoder.decode(request, from: url)
        }
        inFlight[request] = task
        let result = await task.value
        let isStillWanted = inFlight[request] == task
        if isStillWanted {
            inFlight[request] = nil
        }
        guard let result else {
            logger.error("Background image unavailable: \(request.image.identifier, privacy: .public)")
            return nil
        }
        if isStillWanted {
            insert(result, for: request)
        }
        return result
    }

    /// Releases every cached variant not in `requests`.
    func retainOnly(_ requests: Set<BackgroundRenderRequest>) {
        cache = cache.filter { requests.contains($0.key) }
        recency.removeAll { !requests.contains($0) }
        inFlight = inFlight.filter { requests.contains($0.key) }
    }

    func removeAll() {
        cache.removeAll()
        recency.removeAll()
        inFlight.removeAll()
    }

    private func insert(_ rendered: RenderedBackground, for request: BackgroundRenderRequest) {
        cache[request] = rendered
        touch(request)
        while cachedByteCount > byteBudget, recency.count > 1 {
            let evicted = recency.removeFirst()
            cache[evicted] = nil
        }
    }

    private func touch(_ request: BackgroundRenderRequest) {
        recency.removeAll { $0 == request }
        recency.append(request)
    }
}

/// ImageIO decoding with explicit pixel limits and orientation correction.
enum BackgroundImageDecoder {
    nonisolated static func decode(_ request: BackgroundRenderRequest, from url: URL) -> RenderedBackground? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let logicalSize = request.image.logicalSize

        switch request.variant {
        case .downsampled(let maxPixelSize):
            guard let image = thumbnail(source, index: index, maxPixelSize: maxPixelSize) else { return nil }
            return RenderedBackground(image: image, region: CGRect(origin: .zero, size: logicalSize))

        case .cropped(let region):
            // Decode once at full size, keep only the visible region, and let the rest be released.
            let longSide = Int(max(logicalSize.width, logicalSize.height))
            guard let full = thumbnail(source, index: index, maxPixelSize: longSide) else { return nil }
            let scaleX = CGFloat(full.width) / logicalSize.width
            let scaleY = CGFloat(full.height) / logicalSize.height
            let pixelRegion = CGRect(
                x: region.cgRect.minX * scaleX,
                y: region.cgRect.minY * scaleY,
                width: region.cgRect.width * scaleX,
                height: region.cgRect.height * scaleY
            ).integral
            guard let cropped = full.cropping(to: pixelRegion), let copy = copyBitmap(cropped) else { return nil }
            return RenderedBackground(image: copy, region: region.cgRect)
        }
    }

    private static func thumbnail(_ source: CGImageSource, index: Int, maxPixelSize: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, index, options)
    }

    /// Copies a cropped image into its own buffer so it does not retain the full decode.
    ///
    /// This uses vImage rather than `CGContext.draw`: drawing makes Core Graphics keep converted
    /// source data in a process-wide cache after the source image is released, which accumulated
    /// across image-backed breaks.
    private static func copyBitmap(_ image: CGImage) -> CGImage? {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ), let pixels = try? vImage.PixelBuffer<vImage.Interleaved8x4>(cgImage: image, cgImageFormat: &format) else {
            return nil
        }
        return pixels.makeCGImage(cgImageFormat: format)
    }
}
