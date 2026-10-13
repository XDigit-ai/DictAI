import Foundation
import Testing
@testable import DictAI

@MainActor
struct DictationSessionTests {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var prompts: [String?] = []
        var sampleCounts: [Int] = []
    }

    func session(live: Bool, clipSeconds: Double = 5, calls: Calls, fail: Bool = false) -> DictationSession {
        DictationSession(live: live, clipSeconds: clipSeconds) { samples, prompt in
            calls.lock.lock()
            calls.prompts.append(prompt)
            calls.sampleCounts.append(samples.count)
            let n = calls.prompts.count
            calls.lock.unlock()
            try await Task.sleep(for: .milliseconds(10))
            if fail { throw FakeError.failed }
            return "clip \(n)"
        }
    }

    @Test func liveClipsAreTranscribedInOrderWithEarlierTextAsPrompt() async throws {
        let calls = Calls()
        let s = session(live: true, calls: calls)
        var seen: [String] = []
        s.onText = { seen.append($0) }
        // 12 s of speech: two 5 s clips while talking, 2 s left for finish.
        for start in stride(from: 0, to: 12, by: 1) { s.append(tone(1, amplitude: 0.1)); _ = start }
        let text = try await s.finish()
        #expect(text == "clip 1 clip 2 clip 3")
        #expect(calls.prompts == [nil, "clip 1", "clip 1 clip 2"])
        #expect(seen == ["clip 1", "clip 1 clip 2", "clip 1 clip 2 clip 3"])
    }

    @Test func silentClipsAreSkippedAndShortOnesPadded() async throws {
        let calls = Calls()
        let s = session(live: true, calls: calls)
        s.append(silence(5))                        // a whole silent clip
        s.append(tone(0.4, amplitude: 0.1))          // short remainder
        let text = try await s.finish()
        #expect(text == "clip 1")
        #expect(calls.sampleCounts == [DictationSession.minimumSamples])
    }

    @Test func nonLiveTranscribesEverythingOnceAtTheEnd() async throws {
        let calls = Calls()
        let s = session(live: false, calls: calls)
        var seen: [String] = []
        s.onText = { seen.append($0) }
        s.append(tone(12, amplitude: 0.1))
        #expect(calls.prompts.isEmpty)
        let text = try await s.finish()
        #expect(text == "clip 1")
        #expect(calls.sampleCounts == [12 * DictationClipper.sampleRate])
        #expect(seen.isEmpty)
    }

    @Test func aFailedClipFailsFinish() async {
        let calls = Calls()
        let s = session(live: true, calls: calls, fail: true)
        s.append(tone(6, amplitude: 0.1))
        await #expect(throws: FakeError.self) { try await s.finish() }
    }

    @Test func cancelDropsPendingClips() async throws {
        let calls = Calls()
        let s = session(live: true, calls: calls)
        s.append(tone(11, amplitude: 0.1))
        s.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.text.isEmpty)
        #expect(calls.prompts.count <= 1)
    }
}
