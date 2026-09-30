import Testing
import Foundation
import AVFoundation
@testable import DictAI

/// Real speech engines on a scripted call. Run with DICTAI_E2E=1 in the environment:
/// `DICTAI_E2E=1 xcodebuild test ... -only-testing:TalkTests/CallEndToEndTests`
@Suite(.enabled(if: e2eEnabled, "Set DICTAI_E2E=1 to run end to end tests"))
struct CallEndToEndTests {

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LiveResult] = []
        func add(_ r: LiveResult) { lock.withLock { items.append(r) } }
        var all: [LiveResult] { lock.withLock { items } }
    }

    @Test func liveTranscriberHearsBothChannels() async throws {
        try #require(await LiveSpeechAssets.ensureInstalled(), "Apple speech assets are not installed")
        let call = try ScriptedCall.make()
        let collector = Collector()
        // Two analyzers at once: the spec's "two concurrent analyzers" risk.
        let you = AppleLiveTranscriber(speaker: .you)
        let them = AppleLiveTranscriber(speaker: .them)
        try await you.start { collector.add($0) }
        try await them.start { collector.add($0) }
        let chunk = testSampleRate / 10
        for offset in stride(from: 0, to: call.you.count, by: chunk) {
            let end = min(call.you.count, offset + chunk)
            you.append(.mono16k(Array(call.you[offset..<end])))
            them.append(.mono16k(Array(call.them[offset..<end])))
        }
        await you.finish()
        await them.finish()

        let results = collector.all
        let youText = results.filter { $0.speaker == .you }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        let themText = results.filter { $0.speaker == .them }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        #expect(wordAccuracy(expected: call.youText, actual: youText) >= 0.85, "You: \(youText)")
        #expect(wordAccuracy(expected: call.themText, actual: themText) >= 0.85, "Them: \(themText)")
        #expect(themText.lowercased().contains("next week"))    // last sentence present after finish()
        #expect(results.allSatisfy { $0.start >= 0 && $0.start < seconds(call.you.count) })
    }

    /// Uses the app's downloaded Whisper model directly, without WhisperState.
    struct ContextTranscriber: UtteranceTranscribing {
        let context: WhisperContext
        func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] {
            guard let segments = await context.transcribeSegments(samples: samples, initialPrompt: prompt, beamSize: 5) else {
                throw FakeError.failed
            }
            return segments
        }
    }

    @MainActor
    @Test func finalPassOnScriptedCall() async throws {
        let modelPath = WhisperState.shared.modelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "No Whisper model at \(modelPath)")
        let context = try await WhisperContext.createContext(path: modelPath)
        let call = try ScriptedCall.make()
        var header = sampleHeader()
        header.ended = sampleStart.addingTimeInterval(seconds(call.you.count))
        let doc = try await FinalPass.render(
            channels: [.you: call.you, .them: call.them], header: header,
            using: ContextTranscriber(context: context), timeZone: utc)

        // Collect each speaker's text lines: every line after a "**You** · ..." or
        // "**Them** · ..." heading belongs to that speaker until the next heading.
        var bySpeaker: [String: [String]] = [:]
        var current: String?
        for line in doc.components(separatedBy: "\n") {
            if line.hasPrefix("**You** · ") { current = "you"; continue }
            if line.hasPrefix("**Them** · ") { current = "them"; continue }
            if let current, !line.isEmpty { bySpeaker[current, default: []].append(line) }
        }
        let youText = (bySpeaker["you"] ?? []).joined(separator: " ")
        let themText = (bySpeaker["them"] ?? []).joined(separator: " ")
        #expect(wordAccuracy(expected: call.youText, actual: youText) >= 0.9, "You: \(youText)")
        #expect(wordAccuracy(expected: call.themText, actual: themText) >= 0.9, "Them: \(themText)")
        #expect(!doc.contains("BLANK_AUDIO"))
        #expect(doc.lowercased().contains("next week"))

        // Turns alternate You, Them, You, Them, You, Them.
        let order = doc.components(separatedBy: "\n").compactMap { line -> String? in
            line.hasPrefix("**You**") ? "you" : line.hasPrefix("**Them**") ? "them" : nil
        }
        #expect(order == ["you", "them", "you", "them", "you", "them"])
    }
}
