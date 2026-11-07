import AppKit
import AVFoundation
import Foundation

public enum ImportError: Error, Equatable, CustomStringConvertible {
    /// The file has no video track macOS can read.
    case notAVideo(String)
    case exportFailed(String)
    case cancelled
    /// Not enough free space for the converted copy (bytes needed, bytes free).
    case notEnoughSpace(Int64, Int64)

    public var description: String {
        switch self {
        case .notAVideo(let name): "\(name) is not a video macOS can play"
        case .exportFailed(let reason): "the video could not be converted: \(reason)"
        case .cancelled: "the import was cancelled"
        case .notEnoughSpace(let needed, let free): "not enough space: \(needed) bytes needed, \(free) free"
        }
    }
}

/// Adds one of the user's videos to macOS's aerial folder, in the format macOS plays: HEVC in a QuickTime file.
///
/// HEVC `.mov` files are copied as they are, HEVC in another container is rewrapped without re-encoding,
/// anything else is converted with the Mac's own HEVC encoder. The file gets the `SourceURL` attribute that
/// matches its catalog entry (an address that can never be downloaded), and a preview picture.
public struct VideoImporter: Sendable {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public let paths: AerialPaths

    public init(paths: AerialPaths) { self.paths = paths }

    /// Scratch folder for conversions; emptied at launch in case an import was interrupted.
    public static func workFolder(paths: AerialPaths) -> URL {
        paths.appSupport.appending(path: "Import", directoryHint: .isDirectory)
    }

    public static func removeLeftovers(paths: AerialPaths) {
        try? FileManager.default.removeItem(at: workFolder(paths: paths))
    }

    /// Video files directly inside a folder (not in subfolders), sorted by name.
    public static func videos(inFolder folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// - Parameter progress: 0...1, called from any thread.
    /// - Parameter id: the new video's ID; pass it in to know the file before the import ends.
    public func importVideo(
        from source: URL, id: String = UUID().uuidString, name: String? = nil, setID: UUID? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> CustomVideo {
        let asset = AVURLAsset(url: source)
        let title = source.deletingPathExtension().lastPathComponent
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions), let format = formats.first else {
            throw ImportError.notAVideo(source.lastPathComponent)
        }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let isHEVC = codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha
            || codec == FourCharCode(0x6865_7631) // 'hev1'

        // A converted copy is at most about the size of the original; keep 500 MB free on top, as downloads do.
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if let free = AerialDownloader.availableSpace(paths: paths), free < size + 500_000_000 {
            throw ImportError.notEnoughSpace(size + 500_000_000, free)
        }
        try Task.checkCancellation()

        let work = Self.workFolder(paths: paths)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let temporary = work.appending(path: "\(id).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }

        if isHEVC, source.pathExtension.lowercased() == "mov" {
            try FileManager.default.copyItem(at: source, to: temporary)
            progress(1)
        } else {
            try await export(asset, to: temporary, rewrapOnly: isHEVC, progress: progress)
        }

        if Task.isCancelled { throw ImportError.cancelled }
        // The attribute goes on before the move, so a file in macOS's folder is always recognisable as the user's.
        _ = ExtendedAttributes.set(CustomLibrary.sourceURL(for: id).absoluteString, named: "SourceURL", at: temporary)
        try FileManager.default.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        let destination = paths.videoFile(for: id)
        try FileManager.default.moveItem(at: temporary, to: destination)
        await writePreview(of: destination, id: id)
        return CustomVideo(id: id, name: name ?? title, setID: setID)
    }

    private func export(_ asset: AVURLAsset, to url: URL, rewrapOnly: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let preset = rewrapOnly ? AVAssetExportPresetPassthrough : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ImportError.exportFailed("no export session for \(preset)")
        }
        let states = session.states(updateInterval: 0.5)
        let watcher = Task {
            for await state in states {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: url, as: .mov)
        } catch where Task.isCancelled || error is CancellationError {
            throw ImportError.cancelled
        } catch {
            throw ImportError.exportFailed(error.localizedDescription)
        }
        progress(1)
    }

    /// A 640 px frame as the preview macOS shows in System Settings (`thumbnails/<id>.png`).
    public func writePreview(of video: URL, id: String) async {
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: min(6, max(0, duration / 2)), preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
        try? data.write(to: paths.thumbnailFile(for: id), options: .atomic)
    }
}
