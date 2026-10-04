import AVFoundation
import CoreMedia

final class PCMConverter {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let description = sampleBuffer.formatDescription,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic) else { throw AudioFileError.invalidPCM }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioFileError.invalidPCM
        }
        input.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
        )
        guard status == noErr else { throw AudioFileError.invalidPCM }
        return try convert(input)
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        if sourceFormat != input.format {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter,
              let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate) + 64)
              ) else { throw AudioFileError.invalidPCM }
        var inputCursor: AVAudioFrameCount = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requested, inputStatus in
            if inputCursor >= input.frameLength {
                inputStatus.pointee = .noDataNow
                return nil
            }
            let count = min(requested, input.frameLength - inputCursor)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            chunk.frameLength = count
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for index in 0..<sourceBuffers.count {
                let bytesPerFrame = Int(sourceBuffers[index].mDataByteSize) / Int(input.frameLength)
                if let source = sourceBuffers[index].mData, let destination = destinationBuffers[index].mData {
                    memcpy(destination, source.advanced(by: Int(inputCursor) * bytesPerFrame), Int(count) * bytesPerFrame)
                }
            }
            inputCursor += count
            inputStatus.pointee = .haveData
            return chunk
        }
        if status == .error { throw error ?? AudioFileError.invalidPCM as NSError }
        guard let data = output.floatChannelData?[0] else { throw AudioFileError.invalidPCM }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength) * 2))
    }
}
