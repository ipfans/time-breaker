import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TimeBreaker

@Suite("Image layout")
struct ImageLayoutTests {
    let display = CGSize(width: 1512, height: 982)

    @Test func stretchFillsTheDisplay() {
        let rect = ImageLayoutCalculator.imageRect(layout: .stretch, imageSize: CGSize(width: 400, height: 400), in: display)
        #expect(rect == CGRect(origin: .zero, size: display))
    }

    @Test func centerKeepsLogicalSizeAndCentersSmallImages() {
        let rect = ImageLayoutCalculator.imageRect(layout: .center, imageSize: CGSize(width: 400, height: 300), in: display)
        #expect(rect == CGRect(x: 556, y: 341, width: 400, height: 300))
    }

    @Test func centerClipsLargeImagesToTheMiddle() {
        let image = CGSize(width: 3000, height: 2000)
        let rect = ImageLayoutCalculator.imageRect(layout: .center, imageSize: image, in: display)
        #expect(rect == CGRect(x: -744, y: -509, width: 3000, height: 2000))

        let visible = ImageLayoutCalculator.visibleImageRegion(layout: .center, imageSize: image, in: display)
        #expect(visible == CGRect(x: 744, y: 509, width: 1512, height: 982))
    }

    @Test func scaleToFitLetterboxesAWideImage() {
        let rect = ImageLayoutCalculator.imageRect(layout: .scaleToFit, imageSize: CGSize(width: 3000, height: 1000), in: display)
        #expect(rect.width == 1512)
        #expect(abs(rect.height - 504) < 0.001)
        #expect(abs(rect.minY - 239) < 0.001)
        #expect(rect.minX == 0)
    }

    @Test func scaleToFitPillarboxesAPortraitImageOnALandscapeDisplay() {
        let rect = ImageLayoutCalculator.imageRect(layout: .scaleToFit, imageSize: CGSize(width: 1000, height: 2000), in: display)
        #expect(rect.height == 982)
        #expect(rect.width == 491)
        #expect(abs(rect.midX - 756) < 0.001)
    }

    @Test func scaleToFitEnlargesSmallImages() {
        let rect = ImageLayoutCalculator.imageRect(layout: .scaleToFit, imageSize: CGSize(width: 151.2, height: 98.2), in: display)
        #expect(abs(rect.width - 1512) < 0.001)
        #expect(abs(rect.height - 982) < 0.001)
    }

    @Test func portraitDisplayLaysOutIndependently() {
        let portrait = CGSize(width: 1440, height: 2560)
        let rect = ImageLayoutCalculator.imageRect(layout: .scaleToFit, imageSize: CGSize(width: 1600, height: 900), in: portrait)
        #expect(rect.width == 1440)
        #expect(abs(rect.height - 810) < 0.001)
    }

    @Test func stretchRequestsEnoughPixelsForBothAxes() {
        let variant = ImageLayoutCalculator.renderRequest(
            layout: .stretch,
            imageSize: CGSize(width: 4000, height: 3000),
            container: display,
            backingScale: 2
        )
        // Width needs 3024 px; height needs 1964 px of a 3:4 axis, i.e. a 2619 px long side.
        #expect(variant == .downsampled(maxPixelSize: 3024))
    }

    @Test func stretchCapsExtremeAspectMismatches() {
        // A 1:4 portrait image stretched across a landscape display would need a 12096 px decode.
        let variant = ImageLayoutCalculator.renderRequest(
            layout: .stretch,
            imageSize: CGSize(width: 4000, height: 16000),
            container: display,
            backingScale: 2
        )
        #expect(variant == .downsampled(maxPixelSize: 4536))
    }

    @Test func requestsNeverExceedTheImageItself() {
        let small = CGSize(width: 640, height: 480)
        #expect(ImageLayoutCalculator.renderRequest(layout: .stretch, imageSize: small, container: display, backingScale: 2) == .downsampled(maxPixelSize: 640))
        #expect(ImageLayoutCalculator.renderRequest(layout: .scaleToFit, imageSize: small, container: display, backingScale: 2) == .downsampled(maxPixelSize: 640))
    }

    @Test func scaleToFitRequestMatchesPlacedSizeAndScale() {
        let variant = ImageLayoutCalculator.renderRequest(
            layout: .scaleToFit,
            imageSize: CGSize(width: 6000, height: 2000),
            container: CGSize(width: 2560, height: 1440),
            backingScale: 1
        )
        #expect(variant == .downsampled(maxPixelSize: 2560))
    }

    @Test func centerDecodesSmallImagesWholeAndCropsLargeOnes() {
        let small = ImageLayoutCalculator.renderRequest(layout: .center, imageSize: CGSize(width: 800, height: 600), container: display, backingScale: 2)
        #expect(small == .downsampled(maxPixelSize: 800))

        let large = ImageLayoutCalculator.renderRequest(layout: .center, imageSize: CGSize(width: 3000, height: 2000), container: display, backingScale: 2)
        #expect(large == .cropped(PixelRect(x: 744, y: 509, width: 1512, height: 982)))
    }

    @Test func centerSizeIsIndependentOfDecodedResolution() {
        // A downsampled bitmap still covers the full logical image, so it draws at logical size.
        let imageSize = CGSize(width: 400, height: 300)
        let frame = BackgroundCanvas.drawRect(layout: .center, imageSize: imageSize, region: CGRect(origin: .zero, size: imageSize), container: display)
        #expect(frame.size == imageSize)
    }

    @Test func croppedRegionDrawsExactlyOverTheVisibleArea() {
        let imageSize = CGSize(width: 3000, height: 2000)
        let region = CGRect(x: 744, y: 509, width: 1512, height: 982)
        let frame = BackgroundCanvas.drawRect(layout: .center, imageSize: imageSize, region: region, container: display)
        #expect(frame == CGRect(origin: .zero, size: display))
    }
}

@Suite("Image import and decoding")
struct BackgroundImageStoreTests {
    // MARK: Fixtures

    static func imageData(width: Int, height: Int, type: UTType, orientation: Int? = nil, frames: Int = 1, alpha: Bool = false, noise: Bool = false) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise {
            // Varied content keeps compressed data spread across the whole file.
            for y in stride(from: 0, to: height, by: 2) {
                context.setFillColor(CGColor(red: CGFloat(y % 255) / 255, green: CGFloat(y * 7 % 255) / 255, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: 0, y: y, width: width, height: 2))
            }
        }
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        if frames > 1 {
            properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: 0.1]
        }
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func write(_ data: Data, name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    // MARK: Import

    @Test func importsAPrivateCopyAndLeavesTheOriginalUntouched() throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let original = Self.imageData(width: 120, height: 80, type: .png, alpha: true)
        let source = try write(original, name: "photo.png", in: sourceDirectory)

        let reference = try store.importImage(from: source)

        #expect(reference.pixelWidth == 120)
        #expect(reference.pixelHeight == 80)
        #expect(reference.isValid)
        #expect(try Data(contentsOf: store.url(for: reference)) == original)
        #expect(try Data(contentsOf: source) == original)

        // The copy survives deletion of the original.
        try FileManager.default.removeItem(at: source)
        #expect(store.fileExists(for: reference))
    }

    @Test func importNormalizesOrientationOfLogicalSize() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let source = try write(Self.imageData(width: 400, height: 200, type: .jpeg, orientation: 6), name: "rotated.jpg", in: try makeTemporaryDirectory())

        let reference = try store.importImage(from: source)
        #expect(reference.pixelWidth == 200)
        #expect(reference.pixelHeight == 400)
        #expect(reference.identifier.hasSuffix(".jpg"))
    }

    @Test func importsHEIC() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let source = try write(Self.imageData(width: 64, height: 48, type: .heic), name: "image.heic", in: try makeTemporaryDirectory())
        let reference = try store.importImage(from: source)
        #expect(reference.identifier.hasSuffix(".heic"))
        #expect(reference.logicalSize == CGSize(width: 64, height: 48))
    }

    @Test func detectsTheRealFormatRegardlessOfExtension() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let gif = try write(Self.imageData(width: 10, height: 10, type: .gif), name: "fake.png", in: try makeTemporaryDirectory())
        #expect(throws: ImageImportError.unsupportedFormat) { try store.importImage(from: gif) }
    }

    @Test func rejectsTIFF() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let tiff = try write(Self.imageData(width: 10, height: 10, type: .tiff), name: "image.tiff", in: try makeTemporaryDirectory())
        #expect(throws: ImageImportError.unsupportedFormat) { try store.importImage(from: tiff) }
    }

    @Test func rejectsNonImageData() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let junk = try write(Data("definitely not an image".utf8), name: "junk.jpg", in: try makeTemporaryDirectory())
        #expect(throws: ImageImportError.unsupportedFormat) { try store.importImage(from: junk) }
    }

    @Test(arguments: [UTType.png, .jpeg, .heic])
    func rejectsTruncatedImages(type: UTType) throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let full = Self.imageData(width: 600, height: 400, type: type, noise: true)
        let truncated = try write(full.prefix(full.count * 2 / 3), name: "cut", in: try makeTemporaryDirectory())
        #expect(throws: ImageImportError.unreadable) { try store.importImage(from: truncated) }
    }

    @Test func rejectsAnimatedPNG() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let animated = try write(Self.imageData(width: 20, height: 20, type: .png, frames: 2), name: "anim.png", in: try makeTemporaryDirectory())
        #expect(throws: ImageImportError.animated) { try store.importImage(from: animated) }
    }

    @Test func rejectsOversizedDimensions() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let wide = try write(Self.imageData(width: BackgroundImageStore.maxPixelDimension + 1, height: 1, type: .png), name: "wide.png", in: try makeTemporaryDirectory())
        #expect(throws: ImageImportError.dimensionsTooLarge) { try store.importImage(from: wide) }
    }

    @Test func rejectsMissingFiles() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let missing = try makeTemporaryDirectory().appending(path: "gone.png")
        #expect(throws: ImageImportError.unreadable) { try store.importImage(from: missing) }
    }

    @Test func failedImportsLeaveNoFilesBehind() throws {
        let directory = try makeTemporaryDirectory()
        let store = BackgroundImageStore(directory: directory)
        let junk = try write(Data("nope".utf8), name: "junk.png", in: try makeTemporaryDirectory())
        _ = try? store.importImage(from: junk)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    @Test func removesReplacedImages() throws {
        let directory = try makeTemporaryDirectory()
        let store = BackgroundImageStore(directory: directory)
        let sources = try makeTemporaryDirectory()
        let first = try store.importImage(from: try write(Self.imageData(width: 8, height: 8, type: .png), name: "a.png", in: sources))
        let second = try store.importImage(from: try write(Self.imageData(width: 9, height: 9, type: .png), name: "b.png", in: sources))

        store.removeImages(keeping: [second.identifier])
        #expect(!store.fileExists(for: first))
        #expect(store.fileExists(for: second))
    }

    // MARK: Decoding

    @Test func decodingAppliesOrientationAndPixelLimit() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let source = try write(Self.imageData(width: 800, height: 400, type: .jpeg, orientation: 6), name: "r.jpg", in: try makeTemporaryDirectory())
        let reference = try store.importImage(from: source)

        let request = BackgroundRenderRequest(image: reference, variant: .downsampled(maxPixelSize: 200))
        let rendered = try #require(BackgroundImageDecoder.decode(request, from: store.url(for: reference)))
        #expect(rendered.image.width == 100)
        #expect(rendered.image.height == 200)
        #expect(rendered.region == CGRect(x: 0, y: 0, width: 400, height: 800))
    }

    @Test func decodingCropKeepsOnlyTheVisibleRegion() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let source = try write(Self.imageData(width: 1000, height: 800, type: .png), name: "big.png", in: try makeTemporaryDirectory())
        let reference = try store.importImage(from: source)

        let region = PixelRect(x: 250, y: 200, width: 500, height: 400)
        let rendered = try #require(BackgroundImageDecoder.decode(BackgroundRenderRequest(image: reference, variant: .cropped(region)), from: store.url(for: reference)))
        #expect(rendered.image.width == 500)
        #expect(rendered.image.height == 400)
        #expect(rendered.region == region.cgRect)
    }

    @Test func missingAssetDecodesToNilSoTheColorIsUsed() throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let reference = BackgroundImageReference(identifier: "\(UUID().uuidString).png", pixelWidth: 10, pixelHeight: 10)
        #expect(!store.fileExists(for: reference))
        #expect(BackgroundImageDecoder.decode(BackgroundRenderRequest(image: reference, variant: .downsampled(maxPixelSize: 10)), from: store.url(for: reference)) == nil)
    }

    @MainActor
    @Test func rendererReusesAndReleasesVariants() async throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let reference = try store.importImage(from: try write(Self.imageData(width: 400, height: 300, type: .png), name: "x.png", in: try makeTemporaryDirectory()))
        let renderer = BackgroundImageRenderer(store: store)
        let small = BackgroundRenderRequest(image: reference, variant: .downsampled(maxPixelSize: 100))
        let large = BackgroundRenderRequest(image: reference, variant: .downsampled(maxPixelSize: 400))

        let first = try #require(await renderer.image(for: small))
        let second = try #require(await renderer.image(for: small))
        #expect(first.image === second.image)
        _ = await renderer.image(for: large)
        #expect(renderer.cachedVariantCount == 2)

        renderer.retainOnly([large])
        #expect(renderer.cachedVariantCount == 1)
        renderer.removeAll()
        #expect(renderer.cachedVariantCount == 0)
        #expect(renderer.cachedByteCount == 0)
    }

    @MainActor
    @Test func decodesFinishingAfterReleaseAreNotCached() async throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let reference = try store.importImage(from: try write(Self.imageData(width: 3000, height: 3000, type: .png, noise: true), name: "big.png", in: try makeTemporaryDirectory()))
        let renderer = BackgroundImageRenderer(store: store)
        let request = BackgroundRenderRequest(image: reference, variant: .downsampled(maxPixelSize: 3000))

        let decode = Task { await renderer.image(for: request) }
        while renderer.pendingDecodeCount == 0, renderer.cachedVariantCount == 0 {
            await Task.yield()
        }
        try #require(renderer.pendingDecodeCount == 1, "The decode finished before it could be released")
        renderer.removeAll()

        #expect(await decode.value != nil)
        #expect(renderer.cachedVariantCount == 0)
        #expect(renderer.pendingDecodeCount == 0)
    }

    @MainActor
    @Test func rendererStaysWithinItsByteBudget() async throws {
        let store = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let reference = try store.importImage(from: try write(Self.imageData(width: 400, height: 400, type: .png), name: "x.png", in: try makeTemporaryDirectory()))
        let renderer = BackgroundImageRenderer(store: store, byteBudget: 400 * 400 * 4)
        for size in [100, 200, 300, 400] {
            _ = await renderer.image(for: BackgroundRenderRequest(image: reference, variant: .downsampled(maxPixelSize: size)))
        }
        #expect(renderer.cachedByteCount <= 400 * 400 * 4 + 64 * 400)
        #expect(renderer.cachedVariantCount == 1)
    }
}
