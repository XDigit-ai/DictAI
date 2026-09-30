import Testing
import Foundation
@testable import DictAI

/// Real Whisper model races between dictation and call final passes.
/// Opt in: TEST_RUNNER_DICTAI_E2E=1.
@MainActor
@Suite(.serialized, .enabled(if: e2eEnabled, "Set DICTAI_E2E=1 to run end to end tests"))
struct WhisperConcurrencyTests {

    func say(_ text: String) throws -> URL {
        let url = makeTempDirectory().appendingPathComponent("say.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try p.run()
        p.waitUntilExit()
        return url
    }

    /// Review Critical 1: a dictation request made while a final pass is running must
    /// get its own words back, never the call's.
    @Test func dictationDuringFinalPassGetsItsOwnText() async throws {
        let whisper = WhisperState.shared
        try #require(whisper.isModelDownloaded, "No Whisper model downloaded")
        await whisper.loadModel()
        try #require(whisper.isModelLoaded)

        let dictation = try say("The purple elephant is dancing in the garden.")
        let callSamples = try Recorder.loadAudioSamples(
            from: try say("Quarterly revenue grew in every region except the north."))

        let finalPass = Task { @MainActor in
            for _ in 0..<6 {
                _ = try? await whisper.transcribeSegments(samples: callSamples, initialPrompt: nil, beamSize: 1)
            }
        }
        for _ in 0..<3 {
            let text = try await whisper.transcribe(audioURL: dictation).lowercased()
            #expect(text.contains("elephant"), "Dictation returned: \(text)")
            #expect(!text.contains("revenue"), "Dictation returned call text: \(text)")
        }
        await finalPass.value
    }

    /// Review Important 2: a final pass that starts while the model is still loading
    /// (app launch recovery) must wait for the load, not fail.
    @Test func transcribeSegmentsWaitsForAnInFlightLoad() async throws {
        let whisper = WhisperState.shared
        try #require(whisper.isModelDownloaded, "No Whisper model downloaded")
        whisper.unloadModel()
        let samples = try Recorder.loadAudioSamples(from: try say("Hello from the recovered call."))

        let load = Task { @MainActor in await whisper.loadModel() }
        await Task.yield()                                   // the load is now in flight
        let segments = try await whisper.transcribeSegments(samples: samples, initialPrompt: nil, beamSize: 1)
        #expect(segments.map(\.text).joined().lowercased().contains("recovered"))
        await load.value
    }
}
