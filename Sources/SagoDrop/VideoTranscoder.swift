@preconcurrency import AVFoundation
import Foundation

// Reader and writer callbacks, including cancellation, share one serial queue.
private final class VideoEncodingSession: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let streams: [(AVAssetReaderOutput, AVAssetWriterInput)]
    private let queue = DispatchQueue(label: "dev.hsichen.SagoDrop.video-encoding")
    private var continuation: CheckedContinuation<Void, Error>?
    private var remaining: Int
    private var finishedInputs = Set<Int>()
    private var cancelled = false

    init(reader: AVAssetReader, writer: AVAssetWriter, streams: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
        self.reader = reader
        self.writer = writer
        self.streams = streams
        remaining = streams.count
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    guard !self.cancelled else { self.fail(CancellationError()); return }
                    guard self.writer.startWriting(), self.reader.startReading() else {
                        self.fail(self.writer.error ?? self.reader.error ?? MediaError.message("Couldn’t start video conversion"))
                        return
                    }
                    self.writer.startSession(atSourceTime: .zero)
                    for index in self.streams.indices {
                        self.streams[index].1.requestMediaDataWhenReady(on: self.queue) {
                            self.transfer(index)
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.fail(CancellationError())
            }
        }
    }

    private func transfer(_ index: Int) {
        guard continuation != nil, !finishedInputs.contains(index) else { return }
        let (output, input) = streams[index]
        while input.isReadyForMoreMediaData {
            let appended: Bool? = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                return input.append(sample)
            }
            if let appended {
                guard appended else {
                    fail(writer.error ?? MediaError.message("Couldn’t encode video"))
                    return
                }
            } else {
                guard reader.status != .failed, reader.status != .cancelled else {
                    fail(reader.error ?? MediaError.message("Couldn’t read video"))
                    return
                }
                finishedInputs.insert(index)
                input.markAsFinished()
                remaining -= 1
                if remaining == 0 {
                    writer.finishWriting {
                        self.queue.async {
                            guard let continuation = self.continuation else { return }
                            self.continuation = nil
                            if self.writer.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: self.writer.error ?? MediaError.message("Video conversion failed")) }
                        }
                    }
                }
                return
            }
        }
    }

    private func fail(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        reader.cancelReading()
        writer.cancelWriting()
        continuation.resume(throwing: error)
    }
}

enum VideoTranscoder {
    static func outputSize(for size: CGSize, maximumSize: CGSize) -> CGSize {
        let bounds = size.height > size.width
            ? CGSize(width: maximumSize.height, height: maximumSize.width)
            : maximumSize
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2),
                      height: max(2, floor(size.height * scale / 2) * 2))
    }

    static func export(_ source: URL, to destination: URL, maximumSize: CGSize, maximumBytes: Int64) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.message("This file has no readable video track")
        }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw MediaError.message("This video has no playable duration") }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard rect.width > 0, rect.height > 0 else { throw MediaError.message("This video has invalid dimensions") }
        let size = outputSize(for: rect.size, maximumSize: maximumSize)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: size.width / rect.width, y: size.height / rect.height)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = size
        composition.frameDuration = CMTime(seconds: 1 / Double(frameRate > 0 ? min(frameRate, 60) : 30), preferredTimescale: 60_000)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = []
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioBitRate = audioTracks.isEmpty ? 0 : 128_000
        let budget = Double(maximumBytes) * 8 * 0.95 / seconds - Double(audioBitRate)
        guard budget > 0 else { throw MediaError.message("This video is too long for the upload limit") }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(min(6_000_000, budget))],
        ])
        var streams: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        if !audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitRate,
            ])
            streams.append((audioOutput, audioInput))
        }
        for (output, input) in streams {
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw MediaError.message("This video format could not be converted to MP4")
            }
            reader.add(output)
            writer.add(input)
        }
        try await VideoEncodingSession(reader: reader, writer: writer, streams: streams).run()
    }
}
