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
}
