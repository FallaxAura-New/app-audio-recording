@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay, alreadyRecording, noSource, microphoneDenied, microphoneUnavailable, noAudioReceived
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "没有找到可用于建立 App 音频捕获的显示器。"
        case .alreadyRecording: return "已经有一项录音正在进行。"
        case .noSource: return "请至少开启 App 音频或麦克风中的一项。"
        case .microphoneDenied: return "麦克风权限未开启，请在系统设置中允许访问麦克风。"
        case .microphoneUnavailable: return "无法使用所选麦克风，请确认设备仍连接。"
        case .noAudioReceived: return "没有收到音频，请确认所选音频源正在工作。"
        }
    }
}

protocol AudioRecording: AnyObject, Sendable {
    var onFailure: (@Sendable (Error) -> Void)? { get set }
    func start(application: SCRunningApplication?, microphone: AVCaptureDevice?, outputURL: URL, format: RecordingFormat) async throws
    func stop() async throws
}

final class ApplicationAudioRecorder: NSObject, AudioRecording, @unchecked Sendable {
    var onFailure: (@Sendable (Error) -> Void)?
    private let audioQueue = DispatchQueue(label: "com.nradio.recorder.audio", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "com.nradio.recorder.microphone", qos: .userInitiated)
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var microphoneObserver: NSObjectProtocol?
    private var writer: AudioFileWriter?
    private var mixer: AudioMixer?
    private var converters: [AudioSource: PCMConverter] = [:]
    private var flushTimer: DispatchSourceTimer?
    private var startTime = CMTime.zero
    private var isAcceptingSamples = false
    private var terminalError: Error?

    func start(
        application: SCRunningApplication?,
        microphone: AVCaptureDevice?,
        outputURL: URL,
        format: RecordingFormat
    ) async throws {
        guard audioQueue.sync(execute: { writer == nil }) else { throw RecorderError.alreadyRecording }
        guard application != nil || microphone != nil else { throw RecorderError.noSource }
        if microphone != nil {
            let permitted = await AVCaptureDevice.requestAccess(for: .audio)
            guard permitted else { throw RecorderError.microphoneDenied }
        }

        if let application {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw RecorderError.noDisplay }
            let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            stream = capture
        }

        var createdOutput = false
        do {
            if let microphone {
                microphoneSession = try await configureMicrophone(microphone)
                microphoneObserver = NotificationCenter.default.addObserver(
                    forName: .AVCaptureSessionRuntimeError, object: microphoneSession, queue: nil
                ) { [weak self] notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error ?? RecorderError.microphoneUnavailable
                    self?.audioQueue.async { [weak self] in self?.fail(error) }
                }
            }
            let newWriter = try AudioFileWriter(url: outputURL, format: format)
            createdOutput = true
            audioQueue.sync {
                writer = newWriter
                mixer = AudioMixer(sourceCount: (application == nil ? 0 : 1) + (microphone == nil ? 0 : 1))
                converters = [:]
                terminalError = nil
                startTime = CMClockGetTime(CMClockGetHostTimeClock())
                isAcceptingSamples = true
                let timer = DispatchSource.makeTimerSource(queue: audioQueue)
                timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
                timer.setEventHandler { [weak self] in
                    guard let self, self.isAcceptingSamples else { return }
                    do {
                        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), self.startTime).seconds
                        try self.flush(until: Int64(max(0, elapsed - 0.3) * 48_000))
                    } catch { self.fail(error) }
                }
                flushTimer = timer
                timer.resume()
            }
            if let stream { try await stream.startCapture() }
            if let session = microphoneSession {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    microphoneQueue.async {
                        session.startRunning()
                        if session.isRunning { continuation.resume() }
                        else { continuation.resume(throwing: RecorderError.microphoneUnavailable) }
                    }
                }
            }
        } catch {
            if let stream { try? await stream.stopCapture() }
            await stopMicrophone()
            let empty = audioQueue.sync { () -> Bool in
                let noFrames = (mixer?.receivedFrames ?? 0) == 0
                try? writer?.finish()
                resetAudioState()
                return noFrames
            }
            resetCaptureState()
            if createdOutput && empty { try? FileManager.default.removeItem(at: outputURL) }
            throw error
        }
    }

    func stop() async throws {
        guard audioQueue.sync(execute: { writer != nil }) else { return }
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        audioQueue.sync { flushTimer?.cancel(); flushTimer = nil }
        var captureError: Error?
        if let stream {
            do { try await stream.stopCapture() } catch { captureError = error }
        }
        await stopMicrophone()
        let finalCaptureError = captureError
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            audioQueue.async { [self] in
                isAcceptingSamples = false
                var failure = terminalError ?? finalCaptureError
                do {
                    let end = max(0, CMTimeSubtract(stopTime, startTime).seconds)
                    try flush(until: Int64(end * 48_000))
                    try writer?.finish()
                    if mixer?.receivedFrames == 0 { failure = failure ?? RecorderError.noAudioReceived }
                } catch { failure = failure ?? error }
                resetAudioState()
                continuation.resume(returning: failure.map { .failure($0) } ?? .success(()))
            }
        }
        resetCaptureState()
        try result.get()
    }

    private func configureMicrophone(_ device: AVCaptureDevice) async throws -> AVCaptureSession {
        try await withCheckedThrowingContinuation { continuation in
            microphoneQueue.async { [self] in
                do {
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw RecorderError.microphoneUnavailable }
                    session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: audioQueue)
                    guard session.canAddOutput(output) else { throw RecorderError.microphoneUnavailable }
                    session.addOutput(output)
                    session.commitConfiguration()
                    continuation.resume(returning: session)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func stopMicrophone() async {
        guard let session = microphoneSession else { return }
        await withCheckedContinuation { continuation in
            microphoneQueue.async { session.stopRunning(); continuation.resume() }
        }
    }

    private func flush(until endFrame: Int64) throws {
        guard let mixer, let writer else { return }
        while mixer.outputFrame < endFrame { try writer.append(mixer.read(until: endFrame)) }
    }

    private func consume(_ buffer: CMSampleBuffer, source: AudioSource) {
        guard isAcceptingSamples, buffer.isValid, CMSampleBufferDataIsReady(buffer), let mixer else { return }
        do {
            let converter = converters[source] ?? PCMConverter()
            converters[source] = converter
            let samples = try converter.convert(buffer)
            guard !samples.isEmpty else { return }
            var timestamp = buffer.presentationTimeStamp
            if source == .microphone, let clock = microphoneSession?.synchronizationClock {
                timestamp = CMSyncConvertTime(timestamp, from: clock, to: CMClockGetHostTimeClock())
            }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            var offset = CMTimeSubtract(timestamp, startTime).seconds
            if !offset.isFinite || abs(CMTimeSubtract(timestamp, now).seconds) > 2 {
                offset = CMTimeSubtract(now, startTime).seconds - Double(samples.count / 2) / 48_000
            }
            try mixer.add(samples, source: source, atFrame: Int64((offset * 48_000).rounded()))
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        guard isAcceptingSamples, terminalError == nil else { return }
        terminalError = error
        isAcceptingSamples = false
        flushTimer?.cancel()
        onFailure?(error)
    }

    private func resetAudioState() {
        flushTimer?.cancel()
        flushTimer = nil
        isAcceptingSamples = false
        writer = nil
        mixer = nil
        converters = [:]
        terminalError = nil
    }

    private func resetCaptureState() {
        stream = nil
        microphoneSession = nil
        if let microphoneObserver { NotificationCenter.default.removeObserver(microphoneObserver) }
        microphoneObserver = nil
    }
}

extension ApplicationAudioRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if outputType == .audio { consume(sampleBuffer, source: .application) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        audioQueue.async { [weak self] in self?.fail(error) }
    }
}

extension ApplicationAudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        consume(sampleBuffer, source: .microphone)
    }
}
