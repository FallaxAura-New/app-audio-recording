import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case alreadyRecording
    case writerSetupFailed
    case noAudioReceived
    case writingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "没有找到可用于建立音频捕获的显示器。"
        case .alreadyRecording:
            return "已经有一项录音正在进行。"
        case .writerSetupFailed:
            return "无法创建 MP4 音频写入器。"
        case .noAudioReceived:
            return "没有收到所选软件的声音，请确认直播正在播放。"
        case .writingFailed(let message):
            return "写入 MP4 失败：\(message)"
        }
    }
}

final class ApplicationAudioRecorder: NSObject, @unchecked Sendable {
    private final class WriterContext: @unchecked Sendable {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput

        init(writer: AVAssetWriter, input: AVAssetWriterInput) {
            self.writer = writer
            self.input = input
        }
    }

    private let audioQueue = DispatchQueue(label: "com.nradio.recorder.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writerContext: WriterContext?
    private var didStartSession = false
    private var receivedAudio = false
    private var isAcceptingSamples = false

    func start(application: SCRunningApplication, outputURL: URL) async throws {
        guard stream == nil else { throw RecorderError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(
            display: display,
            including: [application],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        CrashResilientMP4.configure(writer)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerSetupFailed }
        writer.add(input)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        self.writerContext = WriterContext(writer: writer, input: input)
        self.stream = stream
        didStartSession = false
        receivedAudio = false
        isAcceptingSamples = true

        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw error
        }
    }

    func stop() async throws {
        guard let stream, let writerContext else { return }

        try await stream.stopCapture()
        isAcceptingSamples = false

        return try await withCheckedThrowingContinuation { continuation in
            audioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecorderError.writerSetupFailed)
                    return
                }

                guard self.receivedAudio, self.didStartSession else {
                    writerContext.writer.cancelWriting()
                    self.reset()
                    continuation.resume(throwing: RecorderError.noAudioReceived)
                    return
                }

                writerContext.input.markAsFinished()
                writerContext.writer.finishWriting {
                    let status = writerContext.writer.status
                    let message = writerContext.writer.error?.localizedDescription ?? "未知错误"
                    self.reset()
                    if status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RecorderError.writingFailed(message))
                    }
                }
            }
        }
    }

    private func reset() {
        isAcceptingSamples = false
        stream = nil
        writerContext = nil
        didStartSession = false
        receivedAudio = false
    }
}

extension ApplicationAudioRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              isAcceptingSamples,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writerContext else { return }

        let writer = writerContext.writer
        let audioInput = writerContext.input

        if !didStartSession {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            didStartSession = true
        }

        guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
        if audioInput.append(sampleBuffer) {
            receivedAudio = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The UI owns finalization. This delegate is intentionally kept lightweight.
    }
}
