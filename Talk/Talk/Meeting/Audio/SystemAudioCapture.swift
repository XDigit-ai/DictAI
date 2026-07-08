import Foundation
import ScreenCaptureKit
import AVFoundation

/// Captures system audio output using ScreenCaptureKit (macOS 14+).
/// This captures what other apps are playing (Zoom, Meet, etc.) while
/// excluding our own app's audio output.
actor SystemAudioCapture {
    private var stream: SCStream?
    private var delegate: AudioStreamDelegate?
    private var isRunning = false

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) async throws {
        guard !isRunning else { return }

        // Get available content to capture
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Find any display to capture audio from
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayFound
        }

        // Create a filter that captures the display but we only want audio
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        // We only need audio, not video
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Exclude our own app's audio
        config.excludesCurrentProcessAudio = true
        // Minimize video overhead since we only need audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum

        let audioDelegate = AudioStreamDelegate(onSamples: onSamples)
        let captureStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try captureStream.addStreamOutput(audioDelegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await captureStream.startCapture()

        self.stream = captureStream
        self.delegate = audioDelegate
        self.isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        Task {
            try? await stream?.stopCapture()
        }
        stream = nil
        delegate = nil
        isRunning = false
    }
}

// MARK: - Stream Delegate

private final class AudioStreamDelegate: NSObject, SCStreamOutput, Sendable {
    let onSamples: @Sendable ([Float]) -> Void

    init(onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // Get audio buffer list
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == noErr, let data = dataPointer, length > 0 else { return }

        // Convert to Float samples based on the format
        let samples: [Float]
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Already float
            let floatCount = length / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
            samples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
        } else if asbd.pointee.mBitsPerChannel == 16 {
            // Int16 PCM
            let int16Count = length / MemoryLayout<Int16>.size
            let int16Pointer = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: int16Count)
            samples = (0..<int16Count).map { Float(int16Pointer[$0]) / Float(Int16.max) }
        } else {
            return
        }

        // Validate samples
        guard !samples.isEmpty, !samples.contains(where: { $0.isNaN || $0.isInfinite }) else { return }

        onSamples(samples)
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplayFound
    case permissionDenied
    case captureStartFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture"
        case .permissionDenied:
            return "Screen Recording permission is required for system audio capture"
        case .captureStartFailed:
            return "Failed to start system audio capture"
        }
    }
}
