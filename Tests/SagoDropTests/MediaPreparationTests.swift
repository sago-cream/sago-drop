import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SagoDrop

@Test func onlyCompletionNoticesCanBeSuppressed() {
    #expect(StatusNotice.completion("Copied").canBeSuppressed)
    #expect(!StatusNotice.attention("Sign in before uploading").canBeSuppressed)
}

@Test func remembersPublicUploadDisclosureAcceptance() throws {
    let suiteName = "SagoDropTests-PublicUploadDisclosure-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(!PublicUploadDisclosure.isAccepted(in: defaults))
    PublicUploadDisclosure.accept(in: defaults)
    #expect(PublicUploadDisclosure.isAccepted(in: defaults))
}

@Test func rejectsOversizedNonVideoBeforeUpload() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-oversized-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(MediaPreparation.maximumUploadBytes + 1))
    try handle.close()

    await #expect(throws: MediaError.self) {
        try await MediaPreparation.prepare(url)
    }
}

@Test func keepsSupportedSmallFilesInPlace() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-small-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("image".utf8).write(to: url)

    let prepared = try await MediaPreparation.prepare(url)

    #expect(prepared.url == url)
    #expect(!prepared.isTemporary)
}

@Test func keepsSmallDiscordAttachmentsInPlace() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-discord-small-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("image".utf8).write(to: url)

    let prepared = try #require(try await MediaPreparation.prepareForDiscord(
        url,
        maximumBytes: DiscordUploadLimit.free.rawValue
    ))

    #expect(prepared.url == url)
    #expect(!prepared.wasCompressed)
}

@Test func routesOversizedImagesToSagoMedia() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-discord-large-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(DiscordUploadLimit.free.rawValue + 1))
    try handle.close()

    let prepared = try await MediaPreparation.prepareForDiscord(
        url,
        maximumBytes: DiscordUploadLimit.free.rawValue
    )

    #expect(prepared == nil)
}

@Test func choosesDiscordQualityWithoutDroppingBelow720p() {
    #expect(MediaPreparation.discordPreset(durationSeconds: 20, maximumBytes: 20_000_000) == .p1080)
    #expect(MediaPreparation.discordPreset(durationSeconds: 30, maximumBytes: 20_000_000) == .p720)
    #expect(MediaPreparation.discordPreset(durationSeconds: 60, maximumBytes: 20_000_000) == nil)

    #expect(MediaPreparation.discordPreset(durationSeconds: 60, maximumBytes: 50_000_000) == .p1080)
    #expect(MediaPreparation.discordPreset(durationSeconds: 120, maximumBytes: 50_000_000) == .p720)
    #expect(MediaPreparation.discordPreset(durationSeconds: 180, maximumBytes: 50_000_000) == nil)
}

@MainActor
@Test func preparesOversizedVideoForDiscordCache() async throws {
    let source = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-discord-source-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: source) }
    try await createTestVideo(at: source)
    let handle = try FileHandle(forWritingTo: source)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(count: 200_000))
    try handle.close()

    let prepared = try #require(try await MediaPreparation.prepareForDiscord(
        source,
        maximumBytes: 100_000
    ))
    defer { try? FileManager.default.removeItem(at: prepared.url.deletingLastPathComponent()) }

    #expect(prepared.wasCompressed)
    #expect(prepared.url.lastPathComponent == source.lastPathComponent)
    #expect((try prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 100_000)
}

@MainActor
@Test func preparesMp4AsANewLocalUpload() async throws {
    let source = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-source-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: source) }
    try await createTestVideo(at: source)

    let prepared = try await MediaPreparation.prepare(source)
    defer { prepared.cleanUp() }

    #expect(prepared.isTemporary)
    #expect(prepared.url != source)
    #expect(prepared.url.pathExtension == "mp4")
    #expect(FileManager.default.fileExists(atPath: prepared.url.path))
    #expect((try prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MediaPreparation.maximumUploadBytes)

    let asset = AVURLAsset(url: prepared.url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    let metadata = try await asset.load(.commonMetadata)
    #expect(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func preparesFullRangeHevcMovForPublicUpload(rotated: Bool) async throws {
    let source = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-portrait-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: source) }
    try await createTestVideo(at: source, fileType: .mov, codec: .hevc,
                              size: CGSize(width: 1316, height: 1462), fullRange: true, rotated: rotated, includeAudio: true)
    let original = AVURLAsset(url: source)
    let originalTrack = try #require(try await original.loadTracks(withMediaType: .video).first)
    let originalFormat = try #require(try await originalTrack.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(originalFormat) == kCMVideoCodecType_HEVC)
    #expect(CMFormatDescriptionGetExtension(originalFormat, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true)

    let prepared = try await MediaPreparation.prepare(source)
    defer { prepared.cleanUp() }
    let asset = AVURLAsset(url: prepared.url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    let size = try await track.load(.naturalSize)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool != true)
    #expect(min(size.width, size.height) <= 1080)
    #expect(max(size.width, size.height) <= 1920)
    #expect((size.width > size.height) == rotated)
    let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC)
    #expect(prepared.url.pathExtension == "mp4")
    let metadata = try await asset.load(.commonMetadata)
    #expect(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).isEmpty)
}

@MainActor
@Test func convertsSmallMovToMp4ForDiscord() async throws {
    let source = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-discord-\(UUID().uuidString).MOV")
    defer { try? FileManager.default.removeItem(at: source) }
    try await createTestVideo(at: source, fileType: .mov)
    let prepared = try #require(try await MediaPreparation.prepareForDiscord(source, maximumBytes: 20_000_000))
    defer { try? FileManager.default.removeItem(at: prepared.url.deletingLastPathComponent()) }
    #expect(prepared.wasCompressed)
    #expect(prepared.url.pathExtension == "mp4")
    #expect(prepared.url != source)
    let asset = AVURLAsset(url: prepared.url)
    #expect(try await asset.load(.isPlayable))
}

@MainActor
@Test func keepsCompatibleMp4ForDiscord() async throws {
    let source = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-discord-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: source) }
    try await createTestVideo(at: source)
    let prepared = try #require(try await MediaPreparation.prepareForDiscord(source, maximumBytes: 20_000_000))
    #expect(!prepared.wasCompressed)
    #expect(prepared.url == source)
}

@MainActor
@Test func acceptsLocallyPreparedVideoFormats() {
    let model = UploadModel()

    #expect(model.accepts([URL(fileURLWithPath: "/tmp/recording.mov")]))
    #expect(model.accepts([URL(fileURLWithPath: "/tmp/recording.mp4")]))
    #expect(model.accepts([URL(fileURLWithPath: "/tmp/image.png")]))
    #expect(!model.accepts([URL(fileURLWithPath: "/tmp/recording.webm")]))
    #expect(!model.accepts([URL(fileURLWithPath: "/tmp/archive.zip")]))
}

@Test func usesCounterRotatingGearsWhilePreparingVideo() {
    #expect(MenuBarState.converting.symbolName == "gearshape.2")
    let rotations = PreparingGearMotion.rotations(at: 1)
    #expect(rotations.large > 0)
    #expect(rotations.small < 0)
    #expect(abs(rotations.small) > rotations.large)
}

@MainActor
@Test func createsTextClipboardFileWithoutOverwriting() throws {
    let pasteboard = NSPasteboard(name: .init("SagoDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("hello clipboard", forType: .string)
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-clipboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try #require(try ClipboardFile.create(from: pasteboard, in: directory))
    let second = try #require(try ClipboardFile.create(from: pasteboard, in: directory))

    #expect(first.lastPathComponent == "Clipboard.txt")
    #expect(second.lastPathComponent == "Clipboard 2.txt")
    #expect(try String(contentsOf: first, encoding: .utf8) == "hello clipboard")
}

@MainActor
@Test func preservesPngClipboardData() throws {
    let pasteboard = NSPasteboard(name: .init("SagoDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let png = Data([0x89, 0x50, 0x4e, 0x47])
    pasteboard.setData(png, forType: .png)
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-clipboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try #require(try ClipboardFile.create(from: pasteboard, in: directory))

    #expect(file.pathExtension == "png")
    #expect(try Data(contentsOf: file) == png)
}

@MainActor
@Test func savesAppSpecificClipboardData() throws {
    let pasteboard = NSPasteboard(name: .init("SagoDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let payload = Data("opaque object".utf8)
    pasteboard.setData(payload, forType: .init("dev.hsichen.sago-test-object"))
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-clipboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try #require(try ClipboardFile.create(from: pasteboard, in: directory))

    #expect(file.pathExtension == "data")
    #expect(try Data(contentsOf: file) == payload)
}

@MainActor
private func createTestVideo(
    at url: URL, fileType: AVFileType = .mp4, codec: AVVideoCodecType = .h264,
    size: CGSize = CGSize(width: 640, height: 480), fullRange: Bool = false, rotated: Bool = false,
    includeAudio: Bool = false
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = "Private title" as NSString
    writer.metadata = [title]
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
    )
    if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
    guard writer.canAdd(input) else { throw MediaError.message("Could not create test video") }
    writer.add(input)
    let audioInput = includeAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]) : nil
    if let audioInput {
        #expect(writer.canAdd(audioInput))
        writer.add(audioInput)
    }
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else {
        throw MediaError.message("Could not create test video frame")
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if CVPixelBufferIsPlanar(pixelBuffer) {
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
            }
        }
    } else if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    }
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        throw writer.error ?? MediaError.message("Could not write test video frame")
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    input.markAsFinished()
    if let audioInput {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 4800 * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 4800 * 4, flags: 0, blockBufferOut: &block) == noErr)
        let audioBlock = try #require(block)
        #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: audioBlock, offsetIntoDestination: 0, dataLength: 4800 * 4) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: audioBlock,
            formatDescription: try #require(format), sampleCount: 4800, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr)
        #expect(audioInput.append(try #require(sample)))
        audioInput.markAsFinished()
    }
    await writer.finishWriting()
    if let error = writer.error { throw error }
}
