import AVFoundation
import CoreAudio

nonisolated enum ProcessTapError: Error {
    case badFormat
}

/// Captures the audio output of chosen processes through a Core Audio process tap
/// read via a private aggregate device. Needs NSAudioCaptureUsageDescription; the
/// first use shows the System Audio Recording permission prompt.
nonisolated final class ProcessTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ai.xdigit.dictai.processtap", qos: .userInitiated)

    /// `processes` nil taps all system audio except DictAI. The buffer passed to
    /// `onBuffer` is only valid during the call; copy or convert it synchronously.
    func start(processes: [AudioObjectID]?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description: CATapDescription
        if let processes, !processes.isEmpty {
            description = CATapDescription(monoMixdownOfProcesses: processes)
        } else {
            let own = CoreAudioHelpers.processObjectID(for: getpid()).map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try checkStatus(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        var asbd = try CoreAudioHelpers.tapFormat(tap)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw ProcessTapError.badFormat
        }

        let outputUID = try CoreAudioHelpers.defaultOutputDeviceUID()
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DictAI Call Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try checkStatus(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate), "create aggregate device")
            aggregateID = aggregate

            var proc: AudioDeviceIOProcID?
            try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                onBuffer(buffer)
            }, "create IO proc")
            procID = proc
            try checkStatus(AudioDeviceStart(aggregate, proc), "start aggregate device")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
