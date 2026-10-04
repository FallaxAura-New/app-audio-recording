import Foundation

enum AudioSource: Hashable { case application, microphone }

enum AudioMixerError: LocalizedError {
    case invalidBuffer
    case timingOverflow
    var errorDescription: String? {
        switch self {
        case .invalidBuffer: return "收到的音频不是有效的双声道 PCM。"
        case .timingOverflow: return "音频时间戳超出混音缓冲范围，录音已安全停止。"
        }
    }
}

/// Timestamp-aligned bounded ring buffer. Missing source packets become silence,
/// so one silent source never shortens or stalls the other source's recording.
final class AudioMixer {
    static let sampleRate = 48_000
    private let capacityFrames: Int
    private let gain: Float
    private var ring: [Float]
    private var sourceEnds: [AudioSource: Int64] = [:]
    private(set) var outputFrame: Int64 = 0
    private(set) var receivedFrames: Int64 = 0

    init(sourceCount: Int, capacityFrames: Int = sampleRate * 4) {
        self.capacityFrames = capacityFrames
        gain = sourceCount > 1 ? 0.5 : 1
        ring = [Float](repeating: 0, count: capacityFrames * 2)
    }

    func add(_ samples: [Float], source: AudioSource, atFrame timestampFrame: Int64) throws {
        guard samples.count.isMultiple(of: 2) else { throw AudioMixerError.invalidBuffer }
        let frames = samples.count / 2
        var start = timestampFrame
        // Resampling can change packet length by a few frames; avoid tiny
        // discontinuities while preserving meaningful pauses.
        if let previous = sourceEnds[source], abs(previous - start) <= 96 { start = previous }
        guard start < outputFrame + Int64(capacityFrames),
              start + Int64(frames) <= outputFrame + Int64(capacityFrames) else {
            throw AudioMixerError.timingOverflow
        }
        sourceEnds[source] = start + Int64(frames)
        receivedFrames += Int64(frames)
        for frame in 0..<frames {
            let absolute = start + Int64(frame)
            guard absolute >= outputFrame else { continue }
            let slot = Int(absolute % Int64(capacityFrames)) * 2
            for channel in 0..<2 {
                let sample = samples[frame * 2 + channel]
                ring[slot + channel] += (sample.isFinite ? sample : 0) * gain
            }
        }
    }

    func read(until endFrame: Int64, maximumFrames: Int = 4096) -> [Float] {
        let frames = Int(max(0, min(Int64(maximumFrames), endFrame - outputFrame)))
        var output = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let slot = Int(outputFrame % Int64(capacityFrames)) * 2
            output[frame * 2] = max(-1, min(1, ring[slot]))
            output[frame * 2 + 1] = max(-1, min(1, ring[slot + 1]))
            ring[slot] = 0
            ring[slot + 1] = 0
            outputFrame += 1
        }
        return output
    }
}
