import Testing
import Foundation
import AVFoundation
@testable import DictAI

/// Needs speakers or headphones, a microphone, and System Audio Recording permission
/// for the test host. Run with DICTAI_HW=1 in the environment.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DICTAI_HW"] == "1"))
struct CallCaptureHardwareTests {

    final class Peaks: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Speaker: Float] = [:]
        private var formats: [Speaker: Double] = [:]
        func add(_ s: Speaker, _ b: AVAudioPCMBuffer) {
            let peak = b.monoSamples.map(abs).max() ?? 0
            lock.withLock {
                values[s] = max(values[s] ?? 0, peak)
                formats[s] = b.format.sampleRate
            }
        }
        subscript(s: Speaker) -> Float { lock.withLock { values[s] ?? 0 } }
        func rate(_ s: Speaker) -> Double? { lock.withLock { formats[s] } }
    }

    @Test func capturesSystemAudioAndMic() async throws {
        let capture = CallAudioCapture()
        let peaks = Peaks()
        capture.onAudio = { peaks.add($0, $1) }
        let channels = try capture.start(appBundleKey: nil)
        #expect(channels == [.you, .them])

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        try await Task.sleep(for: .seconds(3))
        capture.stop()

        #expect(peaks[.them] > 0.01, "No system audio: check System Audio Recording permission")
        #expect(peaks.rate(.you) == 16_000)
        #expect(peaks.rate(.them) == 16_000)
    }
}
