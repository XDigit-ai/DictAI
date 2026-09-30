import Testing
import Foundation
@testable import DictAI

struct FinalPassTests {

    /// Two utterances: speech at 1.0 to 3.0 s and 5.0 to 6.0 s.
    let twoUtterances = silence(1) + tone(2) + silence(2) + tone(1) + silence(1)

    @Test func channelTimesAreUtteranceOffsetPlusSegmentStart() async {
        let fake = FakeTranscriber(responses: [[seg("um, hello there", 0.5)], [seg("second part", 0.2)]])
        let result = await FinalPass.transcribeChannel(twoUtterances, speaker: .them, using: fake)
        #expect(result.items.map(\.text) == ["Hello there", "Second part"])
        #expect(abs(result.items[0].start - 1.2) < 0.05)        // 0.7 s utterance start + 0.5 s
        #expect(abs(result.items[1].start - 4.9) < 0.05)        // 4.7 s + 0.2 s
        #expect(result.attempted == 2 && result.failed == 0)
        #expect(fake.prompts == [nil, "Hello there"])
    }

    @Test func lowConfidenceThankYouIsDropped() async {
        let fake = FakeTranscriber(responses: [[seg("Thank you.", 0, confidence: 0.2)], [seg("Real words", 0)]])
        let result = await FinalPass.transcribeChannel(twoUtterances, speaker: .you, using: fake)
        #expect(result.items.map(\.text) == ["Real words"])
    }

    @Test func mergeOrdersByTimeAndGroupsSpeakers() {
        let turns = FinalPass.mergeIntoTurns([
            TimedText(speaker: .them, start: 5, text: "Them later."),
            TimedText(speaker: .you, start: 1, text: "First."),
            TimedText(speaker: .you, start: 2, text: "Still me."),
            TimedText(speaker: .them, start: 2, text: "Interrupting."),   // tie: you first
            TimedText(speaker: .you, start: 9, text: "Last."),
        ])
        #expect(turns == [
            Turn(speaker: .you, start: 1, text: "First. Still me."),
            Turn(speaker: .them, start: 2, text: "Interrupting. Them later."),
            Turn(speaker: .you, start: 9, text: "Last."),
        ])
    }

    @Test func renderProducesFinalDocument() async throws {
        let fake = FakeTranscriber(responses: [[seg("hello", 0)], [seg("bye now", 0)], [seg("hi", 0)]])
        var header = sampleHeader()
        header.ended = sampleStart.addingTimeInterval(8)
        let doc = try await FinalPass.render(
            channels: [.you: twoUtterances, .them: silence(2) + tone(1) + silence(1)],
            header: header, using: fake, timeZone: utc)
        #expect(doc.contains("status: final          \n"))
        #expect(doc.contains("duration: 00:00:08\n"))
        #expect(doc.hasSuffix("**You** · 00:00:00\nHello\n\n**Them** · 00:00:01\nHi\n\n**You** · 00:00:04\nBye now\n"))
    }

    /// Review Focus 5: no Whisper model means every utterance fails.
    @Test func renderThrowsWhenEveryUtteranceFails() async {
        let fake = FakeTranscriber(responses: [], failAll: true)
        await #expect(throws: FinalPassError.transcriptionUnavailable) {
            _ = try await FinalPass.render(channels: [.you: twoUtterances], header: sampleHeader(), using: fake, timeZone: utc)
        }
    }

    @Test func renderOfSilenceIsAnEmptyFinalTranscript() async throws {
        let fake = FakeTranscriber(responses: [])
        let doc = try await FinalPass.render(channels: [.you: silence(3)], header: sampleHeader(), using: fake, timeZone: utc)
        #expect(doc.hasSuffix("# Weekly sync\n"))
    }
}
