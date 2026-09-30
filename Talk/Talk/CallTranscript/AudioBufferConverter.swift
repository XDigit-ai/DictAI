import AVFoundation

/// Streaming format conversion. Keeps resampler state between buffers, so it must
/// be used for one continuous stream from one thread at a time.
nonisolated final class AudioBufferConverter {
    /// Whisper's input format, and the format of every captured channel.
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.inputFormat = input
        self.outputFormat = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return out
    }
}

extension AVAudioPCMBuffer {
    /// First channel as Float samples. Expects a Float32 buffer.
    nonisolated var monoSamples: [Float] {
        guard let data = floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(frameLength)))
    }

    nonisolated static func mono16k(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioBufferConverter.whisperFormat,
            frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { dst.update(from: base, count: samples.count) }
            }
        }
        return buffer
    }
}
