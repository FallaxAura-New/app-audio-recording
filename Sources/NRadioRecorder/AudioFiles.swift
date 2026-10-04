import Darwin
import Foundation

enum RecordingFormat: String, CaseIterable, Identifiable {
    case wav, mp3
    var id: String { rawValue }
    var label: String { self == .wav ? "WAV · 无损音频" : "MP3 · 小体积" }
}

enum AudioFileError: LocalizedError {
    case encoderUnavailable
    case encodingFailed(Int32)
    case invalidPCM

    var errorDescription: String? {
        switch self {
        case .encoderUnavailable: return "MP3 编码器不可用。请使用完整的应用包，或在开发环境安装 LAME。"
        case .encodingFailed(let code): return "MP3 编码失败（\(code)），已写入的录音仍保留。"
        case .invalidPCM: return "音频数据格式无效。"
        }
    }
}

/// Reserves a ds64-sized JUNK chunk so long WAV recordings can become RF64
/// without moving the already-written audio.
enum WaveHeader {
    static let size = 80
    static func data(audioBytes: UInt64, sampleRate: UInt32 = 48_000, channels: UInt16 = 2) -> Data {
        var data = Data()
        let blockAlign = channels * 2
        let riffBytes = audioBytes + UInt64(size - 8)
        let rf64 = riffBytes > UInt64(UInt32.max)
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u64(_ value: UInt64) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text(rf64 ? "RF64" : "RIFF"); u32(rf64 ? .max : UInt32(riffBytes)); text("WAVE")
        text(rf64 ? "ds64" : "JUNK"); u32(28)
        u64(riffBytes); u64(audioBytes); u64(audioBytes / UInt64(blockAlign)); u32(0)
        text("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * UInt32(blockAlign)); u16(blockAlign); u16(16)
        text("data"); u32(rf64 ? .max : UInt32(audioBytes))
        return data
    }
}

private final class LameLibrary {
    typealias Init = @convention(c) () -> OpaquePointer?
    typealias SetInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias InitParams = @convention(c) (OpaquePointer?) -> Int32
    typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    typealias Flush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    typealias Close = @convention(c) (OpaquePointer?) -> Int32
    let handle: UnsafeMutableRawPointer
    let initialize: Init
    let sampleRate: SetInt
    let channels: SetInt
    let bitrate: SetInt
    let quality: SetInt
    let writeTag: SetInt
    let initializeParams: InitParams
    let encode: Encode
    let flush: Flush
    let close: Close

    init() throws {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libmp3lame.dylib").path,
            "/opt/homebrew/opt/lame/lib/libmp3lame.dylib",
            "/usr/local/opt/lame/lib/libmp3lame.dylib"
        ].compactMap { $0 }
        guard let loaded = candidates.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            throw AudioFileError.encoderUnavailable
        }
        func function<T>(_ name: String, as type: T.Type) throws -> T {
            guard let symbol = dlsym(loaded, name) else { throw AudioFileError.encoderUnavailable }
            return unsafeBitCast(symbol, to: type)
        }
        do {
            initialize = try function("lame_init", as: Init.self)
            sampleRate = try function("lame_set_in_samplerate", as: SetInt.self)
            channels = try function("lame_set_num_channels", as: SetInt.self)
            bitrate = try function("lame_set_brate", as: SetInt.self)
            quality = try function("lame_set_quality", as: SetInt.self)
            writeTag = try function("lame_set_bWriteVbrTag", as: SetInt.self)
            initializeParams = try function("lame_init_params", as: InitParams.self)
            encode = try function("lame_encode_buffer_interleaved_ieee_float", as: Encode.self)
            flush = try function("lame_encode_flush", as: Flush.self)
            close = try function("lame_close", as: Close.self)
            handle = loaded
        } catch {
            dlclose(loaded)
            throw error
        }
    }

    deinit { dlclose(handle) }
}

/// Writes one mixed stereo stream. WAV headers and both formats' audio are
/// flushed every second; MP3 is encoded while recording rather than at Stop.
final class AudioFileWriter {
    let format: RecordingFormat
    private let file: FileHandle
    private var lame: LameLibrary?
    private var encoder: OpaquePointer?
    private var audioBytes: UInt64 = 0
    private var framesSinceFlush = 0
    private var finished = false

    init(url: URL, format: RecordingFormat) throws {
        self.format = format
        var library: LameLibrary?
        var initializedEncoder: OpaquePointer?
        if format == .mp3 {
            let loaded = try LameLibrary()
            guard let state = loaded.initialize() else { throw AudioFileError.encoderUnavailable }
            guard loaded.sampleRate(state, 48_000) == 0,
                  loaded.channels(state, 2) == 0,
                  loaded.bitrate(state, 192) == 0,
                  loaded.quality(state, 3) == 0,
                  loaded.writeTag(state, 0) == 0,
                  loaded.initializeParams(state) == 0 else {
                _ = loaded.close(state)
                throw AudioFileError.encoderUnavailable
            }
            library = loaded
            initializedEncoder = state
        }
        // Exclusive creation prevents a same-name recording from being overwritten.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if let state = initializedEncoder, let loaded = library { _ = loaded.close(state) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lame = library
        encoder = initializedEncoder
        if format == .wav { try file.write(contentsOf: WaveHeader.data(audioBytes: 0)) }
    }

    func append(_ samples: [Float]) throws {
        guard !finished, samples.count.isMultiple(of: 2) else { throw AudioFileError.invalidPCM }
        if format == .wav {
            var bytes = Data(capacity: samples.count * 2)
            for sample in samples {
                let bounded = sample.isFinite ? max(-1, min(1, sample)) : 0
                var value = Int16((bounded * 32767).rounded()).littleEndian
                withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
            }
            try file.write(contentsOf: bytes)
            audioBytes += UInt64(bytes.count)
        } else if let lame, let encoder {
            let frames = samples.count / 2
            var output = [UInt8](repeating: 0, count: Int(1.25 * Double(frames)) + 7200)
            let count = samples.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { buffer in
                    lame.encode(encoder, input.baseAddress, Int32(frames), buffer.baseAddress, Int32(buffer.count))
                }
            }
            guard count >= 0 else { throw AudioFileError.encodingFailed(count) }
            try file.write(contentsOf: output.prefix(Int(count)))
        }
        framesSinceFlush += samples.count / 2
        if framesSinceFlush >= 48_000 {
            try checkpoint()
            framesSinceFlush = 0
        }
    }

    func checkpoint() throws {
        if format == .wav {
            let end = try file.offset()
            try file.seek(toOffset: 0)
            try file.write(contentsOf: WaveHeader.data(audioBytes: audioBytes))
            try file.seek(toOffset: end)
        }
        try file.synchronize()
    }

    func finish() throws {
        guard !finished else { return }
        defer {
            finished = true
            if let lame, let encoder { _ = lame.close(encoder) }
            encoder = nil
            try? file.close()
        }
        if let lame, let encoder {
            var output = [UInt8](repeating: 0, count: 7200)
            let count = output.withUnsafeMutableBufferPointer {
                lame.flush(encoder, $0.baseAddress, Int32($0.count))
            }
            guard count >= 0 else { throw AudioFileError.encodingFailed(count) }
            try file.write(contentsOf: output.prefix(Int(count)))
        }
        try checkpoint()
    }

    deinit { try? finish() }
}
