import AVFoundation
import CoreAudio

nonisolated enum CallCaptureError: Error {
    case noMicrophone
}

nonisolated protocol CallCapturing: AnyObject {
    /// 16 kHz mono Float32 buffers, delivered on audio threads.
    var onAudio: (@Sendable (Speaker, AVAudioPCMBuffer) -> Void)? { get set }
    /// Starts capture and returns the channels that actually started.
    /// `appBundleKey` nil taps all system audio except DictAI.
    func start(appBundleKey: String?) throws -> [Speaker]
    func stop()
}

/// You: microphone with echo cancellation. Them: process tap on the call app.
nonisolated final class CallAudioCapture: CallCapturing, @unchecked Sendable {
    var onAudio: (@Sendable (Speaker, AVAudioPCMBuffer) -> Void)?

    private var engine: AVAudioEngine?
    private let tap = ProcessTap()
    private var micConverter: AudioBufferConverter?
    private var tapConverter: AudioBufferConverter?

    func start(appBundleKey: String?) throws -> [Speaker] {
        try startMicrophone()
        var channels: [Speaker] = [.you]
        do {
            let processes = appBundleKey.map(Self.processObjects(matching:))
            try tap.start(processes: processes) { [weak self] buffer in
                guard let self else { return }
                if self.tapConverter == nil {
                    self.tapConverter = AudioBufferConverter(from: buffer.format, to: AudioBufferConverter.whisperFormat)
                }
                guard let out = self.tapConverter?.convert(buffer) else { return }
                self.onAudio?(.them, out)
            }
            channels.append(.them)
        } catch {
            DebugLogger.log("System audio tap failed: \(error). Recording the microphone only.", subsystem: "Calls")
        }
        return channels
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tap.stop()
        micConverter = nil
        tapConverter = nil
    }

    /// Every process whose bundle ID is the key or starts with "key." (helper processes).
    static func processObjects(matching key: String) -> [AudioObjectID] {
        CoreAudioHelpers.processObjectIDs().filter { object in
            guard let id = CoreAudioHelpers.bundleID(of: object) else { return false }
            return id == key || id.hasPrefix(key + ".")
        }
    }

    private func startMicrophone() throws {
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            DebugLogger.log("Mic with voice processing failed: \(error). Retrying without.", subsystem: "Calls")
            stop()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing needs the output side of the engine to exist.
            engine.mainMixerNode.outputVolume = 0
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CallCaptureError.noMicrophone }
        micConverter = AudioBufferConverter(from: format, to: AudioBufferConverter.whisperFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let out = self.micConverter?.convert(buffer) else { return }
            self.onAudio?(.you, out)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }
}
