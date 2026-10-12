import AVFoundation
import Foundation
import Combine

/// Microphone capture for dictation. Delivers 16 kHz mono samples as they arrive,
/// with a 0 to 1 level for the visualizer.
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    private var engine: AVAudioEngine?
    private var converter: AudioBufferConverter?

    private override init() {
        super.init()
    }

    // MARK: - Recording Control

    func startRecording(onSamples: @escaping @Sendable ([Float], Float) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecorderError.noMicrophone }
        let converter = AudioBufferConverter(from: format, to: AudioBufferConverter.whisperFormat)
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [converter] buffer, _ in
            guard let out = converter?.convert(buffer) else { return }
            let samples = out.monoSamples
            onSamples(samples, Self.level(of: samples))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stopRecording() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    func cancelRecording() {
        stopRecording()
    }

    // MARK: - Audio Level

    /// RMS in dB mapped from -60 dB...0 dB to 0...1, like AVAudioRecorder's average power.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let minDb: Float = -60
        return max(0, min(1, (db - minDb) / (-minDb)))
    }

    // MARK: - Audio File Conversion

    /// Converts audio file to Float32 samples at 16kHz for Whisper
    static func loadAudioSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)

        // Create a format for 16kHz mono Float32
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw RecorderError.formatCreationFailed
        }

        // Create converter
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw RecorderError.converterCreationFailed
        }

        // Calculate output frame count
        let ratio = 16000.0 / file.processingFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(file.length) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCount) else {
            throw RecorderError.bufferCreationFailed
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                outStatus.pointee = .noDataNow
                return nil
            }

            do {
                try file.read(into: inputBuffer)
                outStatus.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            throw error
        }

        // Extract Float32 samples
        guard let floatData = outputBuffer.floatChannelData?[0] else {
            throw RecorderError.sampleExtractionFailed
        }

        return Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case noMicrophone
    case formatCreationFailed
    case converterCreationFailed
    case bufferCreationFailed
    case sampleExtractionFailed

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone input available"
        case .formatCreationFailed:
            return "Failed to create audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .sampleExtractionFailed:
            return "Failed to extract audio samples"
        }
    }
}
