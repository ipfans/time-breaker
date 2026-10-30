import CoreGraphics

/// Places a background image within one display, independently of every other display.
enum ImageLayoutCalculator {
    /// The rectangle, in container points, occupied by the whole image.
    ///
    /// - Parameter imageSize: Logical image size in points. For Center this is the
    ///   orientation-corrected pixel size, regardless of any downsampled decode.
    static func imageRect(layout: ImageLayout, imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        switch layout {
        case .stretch:
            return CGRect(origin: .zero, size: container)
        case .center:
            return CGRect(
                x: (container.width - imageSize.width) / 2,
                y: (container.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
        case .scaleToFit:
            let scale = min(container.width / imageSize.width, container.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return CGRect(
                x: (container.width - size.width) / 2,
                y: (container.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    /// The portion of the image, in image points with a top-left origin, visible in the container.
    static func visibleImageRegion(layout: ImageLayout, imageSize: CGSize, in container: CGSize) -> CGRect {
        let placed = imageRect(layout: layout, imageSize: imageSize, in: container)
        let visible = placed.intersection(CGRect(origin: .zero, size: container))
        guard !visible.isNull, placed.width > 0, placed.height > 0 else { return .zero }
        let scaleX = imageSize.width / placed.width
        let scaleY = imageSize.height / placed.height
        return CGRect(
            x: (visible.minX - placed.minX) * scaleX,
            y: (visible.minY - placed.minY) * scaleY,
            width: visible.width * scaleX,
            height: visible.height * scaleY
        )
    }

    /// Describes the bitmap needed to render a layout on one display.
    static func renderRequest(
        layout: ImageLayout,
        imageSize: CGSize,
        container: CGSize,
        backingScale: CGFloat
    ) -> BackgroundRenderRequest.Variant {
        let fullRegion = CGRect(origin: .zero, size: imageSize)
        let longSide = max(imageSize.width, imageSize.height)
        guard longSide > 0 else { return .downsampled(maxPixelSize: 1) }

        switch layout {
        case .stretch:
            // Axes scale independently. A uniform decode reaching the display's pixel size on
            // both axes is used as is; extreme aspect mismatches are capped and slightly softened
            // instead of decoding a much larger bitmap.
            let needed = max(
                container.width * backingScale * longSide / imageSize.width,
                container.height * backingScale * longSide / imageSize.height
            )
            let cap = max(container.width, container.height) * backingScale * 1.5
            return .downsampled(maxPixelSize: pixelSize(min(needed, cap), cap: longSide))
        case .scaleToFit:
            let placed = imageRect(layout: layout, imageSize: imageSize, in: container)
            let needed = max(placed.width, placed.height) * backingScale
            return .downsampled(maxPixelSize: pixelSize(needed, cap: longSide))
        case .center:
            // One image pixel maps to one point, so no detail beyond full size is ever needed.
            let region = visibleImageRegion(layout: layout, imageSize: imageSize, in: container).integral
            if region.contains(fullRegion) || region.size == fullRegion.size {
                return .downsampled(maxPixelSize: Int(longSide.rounded(.up)))
            }
            return .cropped(PixelRect(region.intersection(fullRegion)))
        }
    }

    private static func pixelSize(_ needed: CGFloat, cap: CGFloat) -> Int {
        Int(min(needed, cap).rounded(.up)).clamped(to: 1...Int.max)
    }
}

/// A decoded bitmap request for one image, layout, and display.
struct BackgroundRenderRequest: Hashable, Sendable {
    enum Variant: Hashable, Sendable {
        /// The oriented image, decoded with its longest side at most this many pixels.
        case downsampled(maxPixelSize: Int)
        /// Only this region of the oriented full-size image, in image pixels.
        case cropped(PixelRect)
    }

    var image: BackgroundImageReference
    var variant: Variant
}

/// An integral rectangle in image pixels with a top-left origin.
struct PixelRect: Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
