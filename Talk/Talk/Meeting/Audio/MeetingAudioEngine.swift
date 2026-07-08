import AVFoundation
import Combine
import Foundation

/// Manages mic and system audio capture for meetings.
/// Phase 1: mic-only via AVAudioEngine for raw buffer access.
/// Phase 2: adds SystemAudioCapture for dual-channel recording.
class MeetingAudioEngine: ObservableObject {
    @MainActor @Published var micLevel: Float = 0
    @MainActor @Published var systemLevel: Float = 0
    @MainActor @Published var isCapturing = false

    private var audioEngine: AVAudioEngine?
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []
    private let samplesLock = NSLock()
    private var systemCapture: SystemAudioCapture?
    private var useSystemAudio = false

    // MARK: - Start/Stop

    @MainActor
    func startCapture(withSystemAudio: Bool = false) throws {
        useSystemAudio = withSystemAudio
        let engine = AVAudioEngine()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw MeetingAudioError.noMicrophone
        }

        // Install a tap on the mic input for raw audio samples
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        try engine.start()

        audioEngine = engine
        isCapturing = true

        DebugLogger.log("Audio engine started. Mic format: \(inputFormat)", subsystem: "MeetingAudio")

        // System audio capture (if requested and available)
        if withSystemAudio {
            Task { [weak self] in
                await self?.startSystemCapture()
            }
        }
    }

    @MainActor
    func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isCapturing = false

        let capture = systemCapture
        systemCapture = nil
        Task {
            await capture?.stop()
        }

        DebugLogger.log("Audio engine stopped", subsystem: "MeetingAudio")
    }

    // MARK: - Sample Access (thread-safe)

    /// Returns and clears accumulated mic samples since last call.
    func consumeMicSamples() -> [Float] {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        let samples = micSamples
        micSamples.removeAll(keepingCapacity: true)
        return samples
    }

    /// Returns and clears accumulated system audio samples since last call.
    func consumeSystemSamples() -> [Float] {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        let samples = systemSamples
        systemSamples.removeAll(keepingCapacity: true)
        return samples
    }

    // MARK: - Private

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // Resample to 16kHz if needed
        let resampled: [Float]
        if abs(inputFormat.sampleRate - 16000) < 1 {
            resampled = samples
        } else {
            resampled = resample(samples, from: inputFormat.sampleRate, to: 16000)
        }

        samplesLock.lock()
        micSamples.append(contentsOf: resampled)
        samplesLock.unlock()

        // Compute level on the captured samples
        let rms = computeRMS(samples)
        Task { @MainActor [weak self] in
            self?.micLevel = rms
        }
    }

    private func startSystemCapture() async {
        let capture = SystemAudioCapture()
        await MainActor.run { self.systemCapture = capture }
        do {
            try await capture.start { [weak self] samples in
                guard let self else { return }
                self.samplesLock.lock()
                self.systemSamples.append(contentsOf: samples)
                self.samplesLock.unlock()

                let rms = self.computeRMS(samples)
                Task { @MainActor [weak self] in
                    self?.systemLevel = rms
                }
            }
            DebugLogger.log("System audio capture started", subsystem: "MeetingAudio")
        } catch {
            DebugLogger.log("System audio capture failed: \(error). Continuing mic-only.", subsystem: "MeetingAudio")
            await MainActor.run {
                self.useSystemAudio = false
            }
        }
    }

    // MARK: - DSP Helpers

    private func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        let ratio = outputRate / inputRate
        let outputCount = Int(Double(input.count) * ratio)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))
            if idx + 1 < input.count {
                output[i] = input[idx] * (1 - frac) + input[idx + 1] * frac
            } else if idx < input.count {
                output[i] = input[idx]
            }
        }
        return output
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        return min(1.0, rms * 10)
    }
}

// MARK: - Errors

enum MeetingAudioError: LocalizedError {
    case noMicrophone
    case captureSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "Microphone is not available"
        case .captureSetupFailed(let reason):
            return "Audio capture setup failed: \(reason)"
        }
    }
}
