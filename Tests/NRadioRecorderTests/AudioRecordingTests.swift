import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import NRadioRecorder

final class AudioRecordingTests: XCTestCase {
    func testAppAndMicrophoneAreMixedWithoutClipping() throws {
        let mixer = AudioMixer(sourceCount: 2)
        try mixer.add([0.6, -0.6, 0.8, -0.8], source: .application, atFrame: 0)
        try mixer.add([0.4, -0.4, 0.2, -0.2], source: .microphone, atFrame: 0)
        XCTAssertEqual(mixer.read(until: 2), [0.5, -0.5, 0.5, -0.5])
    }

    func testSingleSourceKeepsFullVolumeAndSilenceKeepsDuration() throws {
        let mixer = AudioMixer(sourceCount: 1)
        try mixer.add([0.75, -0.25], source: .microphone, atFrame: 240)
        let output = mixer.read(until: 480)
        XCTAssertEqual(output.count, 960)
        XCTAssertTrue(output.prefix(480).allSatisfy { $0 == 0 })
        XCTAssertEqual(output[480], 0.75)
        XCTAssertEqual(output[481], -0.25)
        XCTAssertTrue(output.suffix(478).allSatisfy { $0 == 0 })
    }

    func testRingWrapClearsOldSamplesAndRejectsOverflow() throws {
        let mixer = AudioMixer(sourceCount: 1, capacityFrames: 1024)
        try mixer.add([0.5, 0.5], source: .application, atFrame: 0)
        XCTAssertEqual(mixer.read(until: 1024)[0], 0.5)
        XCTAssertTrue(mixer.read(until: 2048).allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try mixer.add([1, 1], source: .application, atFrame: 4096))
        XCTAssertThrowsError(try mixer.add([1], source: .application, atFrame: 2048))
    }

    func testInvalidSamplesAreSafeAndLatePacketsDoNotRewriteOutput() throws {
        let mixer = AudioMixer(sourceCount: 1)
        try mixer.add([.nan, 2, -.infinity, -2], source: .application, atFrame: 0)
        XCTAssertEqual(mixer.read(until: 2), [0, 1, 0, -1])
        try mixer.add([0.5, 0.5], source: .microphone, atFrame: -2)
        XCTAssertEqual(mixer.read(until: 3), [0, 0])
    }

    func testWaveHeadersSupportLongRecordings() {
        let small = WaveHeader.data(audioBytes: 192_000)
        XCTAssertEqual(small.count, 80)
        XCTAssertEqual(String(data: small.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: small[12..<16], encoding: .ascii), "JUNK")
        let large = WaveHeader.data(audioBytes: UInt64(UInt32.max) + 1)
        XCTAssertEqual(large.count, 80)
        XCTAssertEqual(String(data: large.prefix(4), encoding: .ascii), "RF64")
        XCTAssertEqual(String(data: large[12..<16], encoding: .ascii), "ds64")
        XCTAssertEqual(Array(large[76..<80]), [255, 255, 255, 255])
    }

    func testWaveCheckpointIsReadableBeforeFinishAndExistingFileIsNeverOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NRadio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileWriter(url: url, format: .wav)
        try writer.append([Float](repeating: 0.25, count: 96_000))
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.length, 48_000)
        XCTAssertEqual(reader.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 2)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try AudioFileWriter(url: url, format: .wav))
        XCTAssertEqual(try Data(contentsOf: url), before)
        try writer.finish()
        try writer.finish()
    }

    func testMono44100InputIsConvertedToStereo48000() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        input.frameLength = 4410
        for frame in 0..<4410 { input.floatChannelData![0][frame] = 0.4 * sin(Float(frame) * 2 * .pi * 440 / 44_100) }
        let output = try PCMConverter().convert(input)
        XCTAssertGreaterThan(output.count, 9000)
        XCTAssertLessThanOrEqual(output.count, 9728)
        for frame in 0..<(output.count / 2) {
            XCTAssertEqual(output[frame * 2], output[frame * 2 + 1], accuracy: 0.00001)
        }
        XCTAssertGreaterThan(output.map { abs($0) }.max() ?? 0, 0.3)
    }

    func testAllThreeModesWriteRealWavAndMp3Audio() async throws {
        let explicitDirectory = ProcessInfo.processInfo.environment["NRADIO_TEST_OUTPUT_DIR"]
        let directory = explicitDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("NRadio-QA-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if explicitDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        for sources: [AudioSource] in [[.application], [.microphone], [.application, .microphone]] {
            let mode = sources.count == 2 ? "mixed" : sources[0] == .application ? "app" : "microphone"
            for format in RecordingFormat.allCases {
                let url = directory.appendingPathComponent("\(mode).\(format.rawValue)")
                let writer = try AudioFileWriter(url: url, format: format)
                let mixer = AudioMixer(sourceCount: sources.count)
                for start in stride(from: 0, to: 144_000, by: 960) {
                    for source in sources {
                        let frequency: Float = source == .application ? 440 : 880
                        var samples = [Float]()
                        for frame in start..<(start + 960) {
                            let sample = 0.4 * sin(Float(frame) * 2 * .pi * frequency / 48_000)
                            samples.append(contentsOf: [sample, sample])
                        }
                        try mixer.add(samples, source: source, atFrame: Int64(start))
                    }
                    try writer.append(mixer.read(until: Int64(start + 960)))
                }
                try writer.finish()
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                XCTAssertEqual(duration.seconds, 3, accuracy: 0.08)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                XCTAssertEqual(audioTracks.count, 1)
                XCTAssertTrue(videoTracks.isEmpty)
            }
        }
    }

    func testStreamingResamplingDoesNotDropFramesBetweenPackets() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let converter = PCMConverter()
        var frames = 0
        for _ in 0..<100 {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
            input.frameLength = 441
            for frame in 0..<441 { input.floatChannelData![0][frame] = 0.25 }
            let output = try converter.convert(input)
            frames += output.count / 2
        }
        XCTAssertEqual(Double(frames), 48_000, accuracy: 96)
    }

    @MainActor
    func testNoSourcesOrUnavailableSelectionCannotStart() {
        let model = RecorderViewModel()
        model.applicationEnabled = false
        model.microphoneEnabled = false
        XCTAssertFalse(model.canStart)
        model.microphoneEnabled = true
        model.selectedMicrophoneID = "disconnected"
        XCTAssertFalse(model.canStart)
        model.microphoneEnabled = false
        model.applicationEnabled = true
        model.selectedApplicationID = "not-running"
        XCTAssertFalse(model.canStart)
    }

    @MainActor
    func testQuitWaitsForExistingSaveInsteadOfStoppingTwice() async {
        let recorder = DeferredRecorder()
        let model = RecorderViewModel(recorder: recorder)
        model.isRecording = true
        let saving = Task { await model.toggleRecording() }
        await recorder.waitUntilStopping()
        let quitting = Task { await model.prepareForTermination() }
        await Task.yield()
        XCTAssertTrue(model.isRecording)
        recorder.completeStop()
        await saving.value
        await quitting.value
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.status, "录音已保存。")
    }

    @MainActor
    func testCaptureFailureCannotOverwriteSaveErrorWithSuccess() async {
        let recorder = DeferredRecorder()
        let model = RecorderViewModel(recorder: recorder)
        model.isRecording = true
        let saving = Task { await model.toggleRecording() }
        await recorder.waitUntilStopping()
        recorder.onFailure?(NSError(domain: "RecordingTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频源断开"]))
        await Task.yield()
        recorder.completeStop(error: NSError(domain: "RecordingTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "磁盘已满"]))
        await saving.value
        await Task.yield()
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(model.status.contains("磁盘已满"))
        XCTAssertFalse(model.status.contains("已保存"))
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isLoading)
    }
}

/// Simulates a pending save without accessing microphone or screen permissions.
private final class DeferredRecorder: AudioRecording, @unchecked Sendable {
    var onFailure: (@Sendable (Error) -> Void)?
    private let lock = NSLock()
    private var savedContinuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var stops = 0
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }

    func start(application: SCRunningApplication?, microphone: AVCaptureDevice?, outputURL: URL, format: RecordingFormat) async throws {
        XCTFail("This test must not start capture.")
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            stops += 1
            savedContinuation = continuation
            let waiting = startedContinuation
            startedContinuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    func waitUntilStopping() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stops > 0 { lock.unlock(); continuation.resume() }
            else { startedContinuation = continuation; lock.unlock() }
        }
    }

    func completeStop(error: Error? = nil) {
        lock.lock()
        let continuation = savedContinuation
        savedContinuation = nil
        lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}
