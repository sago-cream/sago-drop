@preconcurrency import AVFoundation
import Foundation

struct PreparedMedia {
    let url: URL
    let isTemporary: Bool

    func cleanUp() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum DiscordUploadLimit: Int64, CaseIterable {
    case free = 20_000_000
    case nitroBasic = 50_000_000
    case nitro = 500_000_000

    var title: String {
        switch self {
        case .free: "Free, 20 MB"
        case .nitroBasic: "Nitro Basic, 50 MB"
        case .nitro: "Nitro, 500 MB"
        }
    }
}

enum DiscordVideoPreset: Equatable {
    case p1080
    case p720

    fileprivate var exportPreset: String {
        switch self {
        case .p1080: AVAssetExportPreset1920x1080
        case .p720: AVAssetExportPreset1280x720
        }
    }
}

struct DiscordPreparedMedia {
    let url: URL
    let wasCompressed: Bool
}

private final class SendableExporter: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

enum MediaPreparation {
    static let maximumUploadBytes: Int64 = 90_000_000
    private static let compressionTargetBytes: Int64 = 80_000_000
    private static let discordSafetyFactor = 0.95
    private static let discord1080pBitsPerSecond = 6_128_000.0
    private static let discord720pBitsPerSecond = 3_128_000.0
    private static let videoExtensions = Set(["mov", "mp4"])

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func prepare(_ sourceURL: URL) async throws -> PreparedMedia {
        let sourceBytes = try fileSize(of: sourceURL)

        guard isVideo(sourceURL) else {
            guard sourceBytes <= maximumUploadBytes else {
                throw MediaError.message("This file is over the 90 MB upload limit")
            }
            return PreparedMedia(url: sourceURL, isTemporary: false)
        }

        let identifier = UUID().uuidString
        let compressedURL = FileManager.default.temporaryDirectory
            .appending(path: "sago-drop-\(identifier)-compressed.mp4")
        do {
            try await export(
                sourceURL,
                to: compressedURL,
                preset: AVAssetExportPreset1920x1080,
                fileLengthLimit: compressionTargetBytes,
                forceVideoEncoding: true
            )
            let outputBytes = try fileSize(of: compressedURL)
            guard outputBytes <= maximumUploadBytes else {
                let megabytes = outputBytes / 1_000_000
                throw MediaError.message("The converted video is still \(megabytes) MB")
            }
            return PreparedMedia(url: compressedURL, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: compressedURL)
            if let mediaError = error as? MediaError { throw mediaError }
            throw MediaError.message("This video could not be converted to MP4")
        }
    }

    static func prepareForDiscord(
        _ sourceURL: URL,
        maximumBytes: Int64
    ) async throws -> DiscordPreparedMedia? {
        let sourceBytes = try fileSize(of: sourceURL)
        guard isVideo(sourceURL) else {
            return sourceBytes <= maximumBytes
                ? DiscordPreparedMedia(url: sourceURL, wasCompressed: false)
                : nil
        }

        let asset = AVURLAsset(url: sourceURL)
        if sourceBytes <= maximumBytes, try await isDiscordCompatible(asset) {
            return DiscordPreparedMedia(url: sourceURL, wasCompressed: false)
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard let preset = discordPreset(
            durationSeconds: durationSeconds,
            maximumBytes: maximumBytes
        ) else { return nil }

        let outputURL = try cachedDiscordOutputURL(for: sourceURL)
        do {
            try await export(
                sourceURL,
                to: outputURL,
                preset: preset.exportPreset,
                fileLengthLimit: Int64(Double(maximumBytes) * discordSafetyFactor),
                forceVideoEncoding: true
            )
            guard try fileSize(of: outputURL) <= maximumBytes else {
                try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
                return nil
            }
            return DiscordPreparedMedia(url: outputURL, wasCompressed: true)
        } catch {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
            return nil
        }
    }

    static func discordPreset(
        durationSeconds: Double,
        maximumBytes: Int64
    ) -> DiscordVideoPreset? {
        guard durationSeconds.isFinite, durationSeconds > 0, maximumBytes > 0 else { return nil }
        let availableBitsPerSecond = Double(maximumBytes) * 8 * discordSafetyFactor / durationSeconds
        if availableBitsPerSecond >= discord1080pBitsPerSecond { return .p1080 }
        if availableBitsPerSecond >= discord720pBitsPerSecond { return .p720 }
        return nil
    }

    static func cleanUpDiscordCache(olderThan age: TimeInterval = 24 * 60 * 60) {
        guard let cacheDirectory = try? discordCacheDirectory(create: false),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        for url in contents {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func export(
        _ sourceURL: URL,
        to outputURL: URL,
        preset: String,
        fileLengthLimit: Int64? = nil,
        forceVideoEncoding: Bool = false
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.message("This video format is not supported")
        }

        exporter.shouldOptimizeForNetworkUse = true
        exporter.metadata = []
        if let fileLengthLimit { exporter.fileLengthLimit = fileLengthLimit }
        if forceVideoEncoding {
            exporter.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        }

        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .mp4)
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            let sendableExporter = SendableExporter(exporter)
            try await withCheckedThrowingContinuation { continuation in
                sendableExporter.value.exportAsynchronously {
                    switch sendableExporter.value.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: sendableExporter.value.error ?? MediaError.message("Video conversion failed"))
                    }
                }
            }
        }

        let movie = AVMutableMovie(url: outputURL, options: nil)
        movie.metadata = []
        try movie.writeHeader(to: outputURL, fileType: .mp4, options: .addMovieHeaderToDestination)
    }

    private static func cachedDiscordOutputURL(for sourceURL: URL) throws -> URL {
        let directory = try discordCacheDirectory(create: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = sourceURL.deletingPathExtension().lastPathComponent + ".mp4"
        return directory.appending(path: filename)
    }

    private static func isDiscordCompatible(_ asset: AVAsset) async throws -> Bool {
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let videoIsCompatible = codec == kCMVideoCodecType_H264
            || codec == kCMVideoCodecType_HEVC
            || codec == kCMVideoCodecType_AV1
        guard videoIsCompatible else { return false }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for track in audioTracks {
            guard let format = try await track.load(.formatDescriptions).first else { return false }
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let audioIsCompatible = codec == kAudioFormatMPEG4AAC
                || codec == kAudioFormatMPEG4AAC_HE
                || codec == kAudioFormatMPEG4AAC_HE_V2
            guard audioIsCompatible else { return false }
        }
        return true
    }

    private static func discordCacheDirectory(create: Bool) throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw MediaError.message("Could not open the app cache")
        }
        let directory = caches
            .appending(path: "dev.hsichen.SagoDrop", directoryHint: .isDirectory)
            .appending(path: "Discord", directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw MediaError.message("Could not read the selected file")
        }
        return Int64(size)
    }
}
