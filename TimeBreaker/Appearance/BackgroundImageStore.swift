import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

enum ImageImportError: Error, Equatable, Sendable {
    case unsupportedFormat
    case unreadable
    case animated
    case dimensionsTooLarge
    case fileTooLarge
    case saveFailed
}

/// Validates imported images and keeps private copies in Application Support.
///
/// The user's original file is only read. Preferences reference the copy by identifier, so moving
/// or deleting the original does not affect the configured background.
struct BackgroundImageStore: Sendable {
    static let maxFileSize = 100 * 1024 * 1024
    static let maxPixelDimension = 16_384
    static let maxPixelCount = 50_000_000
    static let allowedContentTypes: [UTType] = [.png, .jpeg, .heic]

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/Backgrounds` when sandboxed.
    static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Backgrounds", directoryHint: .isDirectory)
    }

    func url(for reference: BackgroundImageReference) -> URL {
        directory.appending(path: reference.identifier, directoryHint: .notDirectory)
    }

    func fileExists(for reference: BackgroundImageReference) -> Bool {
        reference.isValid && FileManager.default.fileExists(atPath: url(for: reference).path(percentEncoded: false))
    }

    /// Validates `source` and saves a private copy. Throws without side effects on failure.
    func importImage(from source: URL) throws(ImageImportError) -> BackgroundImageReference {
        let isScoped = source.startAccessingSecurityScopedResource()
        defer {
            if isScoped { source.stopAccessingSecurityScopedResource() }
        }

        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxFileSize {
            throw .fileTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw .unreadable
        }
        guard data.count <= Self.maxFileSize else { throw .fileTooLarge }

        let inspection = try Self.inspect(data)
        let identifier = "\(UUID().uuidString).\(inspection.fileExtension)"
        let destination = directory.appending(path: identifier, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw .saveFailed
        }
        return BackgroundImageReference(
            identifier: identifier,
            pixelWidth: inspection.width,
            pixelHeight: inspection.height
        )
    }

    /// Deletes stored images other than `identifiers`, e.g. after a replacement is saved.
    func removeImages(keeping identifiers: Set<String>) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where !identifiers.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    struct Inspection: Equatable, Sendable {
        var fileExtension: String
        /// Orientation-corrected dimensions.
        var width: Int
        var height: Int
    }

    /// Checks the actual content type, frame count, dimensions, and decodability.
    static func inspect(_ data: Data) throws(ImageImportError) -> Inspection {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier)
        else {
            throw .unsupportedFormat
        }

        let fileExtension: String
        if type.conforms(to: .png) {
            fileExtension = "png"
        } else if type.conforms(to: .jpeg) {
            fileExtension = "jpg"
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            fileExtension = "heic"
        } else {
            throw .unsupportedFormat
        }

        guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0 else {
            throw .unreadable
        }
        let containerProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        if containerProperties[kCGImagePropertyHEICSDictionary] != nil
            || (fileExtension == "png" && CGImageSourceGetCount(source) > 1) {
            throw .animated
        }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0
        else {
            throw .unreadable
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let width = swapsAxes ? pixelHeight : pixelWidth
        let height = swapsAxes ? pixelWidth : pixelHeight
        guard max(width, height) <= maxPixelDimension, width * height <= maxPixelCount else {
            throw .dimensionsTooLarge
        }

        let probe = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, index, probe) != nil,
              isComplete(data, fileExtension: fileExtension, source: source, index: index)
        else {
            throw .unreadable
        }
        return Inspection(fileExtension: fileExtension, width: width, height: height)
    }

    /// Detects truncated files, which ImageIO otherwise decodes partially without failing.
    private static func isComplete(_ data: Data, fileExtension: String, source: CGImageSource, index: Int) -> Bool {
        switch fileExtension {
        case "png":
            // The IEND chunk terminates every complete PNG stream.
            return data.suffix(64).range(of: Data("IEND".utf8)) != nil
        case "jpg":
            // A cheap subsampled decode reads the whole stream and reports a premature end.
            let options = [kCGImageSourceSubsampleFactor: 8, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            return CGImageSourceCreateImageAtIndex(source, index, options) != nil
                && CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
        default:
            return isoBoxesSpanData(data)
        }
    }

    /// Whether the top-level ISO base media boxes of a HEIF file exactly cover the data.
    static func isoBoxesSpanData(_ data: Data) -> Bool {
        let count = data.count
        var offset = 0
        func readUInt(at position: Int, byteCount: Int) -> UInt64 {
            (0..<byteCount).reduce(UInt64(0)) { $0 << 8 | UInt64(data[data.startIndex + position + $1]) }
        }
        while offset + 8 <= count {
            var size = readUInt(at: offset, byteCount: 4)
            if size == 1 {
                guard offset + 16 <= count else { return false }
                size = readUInt(at: offset + 8, byteCount: 8)
            } else if size == 0 {
                // The last box extends to the end of the file.
                return true
            }
            guard size >= 8, size <= UInt64(count - offset) else { return false }
            offset += Int(size)
        }
        return offset == count
    }
}
