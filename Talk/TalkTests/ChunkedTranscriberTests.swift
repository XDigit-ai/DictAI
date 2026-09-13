import Testing
@testable import DictAI

struct ChunkedTranscriberTests {

    // MARK: - Overlap Deduplication Tests

    @Test func deduplicateExactOverlap() async throws {
        let engine = MeetingAudioEngine()
        let transcriber = ChunkedTranscriber(audioEngine: engine, chunkInterval: 30)

        // First chunk sets the previous words
        let first = transcriber.deduplicateOverlap("Hello world this is a test of the system")
        #expect(first == "Hello world this is a test of the system")

        // Second chunk has overlap with the end of first
        let second = transcriber.deduplicateOverlap("of the system and now we continue talking")
        #expect(second == "and now we continue talking")
    }

    @Test func deduplicateNoOverlap() async throws {
        let engine = MeetingAudioEngine()
        let transcriber = ChunkedTranscriber(audioEngine: engine, chunkInterval: 30)

        let first = transcriber.deduplicateOverlap("The quick brown fox")
        #expect(first == "The quick brown fox")

        let second = transcriber.deduplicateOverlap("jumped over the lazy dog")
        #expect(second == "jumped over the lazy dog")
    }

    @Test func deduplicateCaseInsensitive() async throws {
        let engine = MeetingAudioEngine()
        let transcriber = ChunkedTranscriber(audioEngine: engine, chunkInterval: 30)

        _ = transcriber.deduplicateOverlap("End of the sentence here")
        let result = transcriber.deduplicateOverlap("sentence here and then more words")
        #expect(result == "and then more words")
    }

    @Test func deduplicateEmptyInput() async throws {
        let engine = MeetingAudioEngine()
        let transcriber = ChunkedTranscriber(audioEngine: engine, chunkInterval: 30)

        _ = transcriber.deduplicateOverlap("Some text here")
        let result = transcriber.deduplicateOverlap("")
        #expect(result == "")
    }

    @Test func deduplicateSingleWord() async throws {
        let engine = MeetingAudioEngine()
        let transcriber = ChunkedTranscriber(audioEngine: engine, chunkInterval: 30)

        _ = transcriber.deduplicateOverlap("hello")
        let result = transcriber.deduplicateOverlap("hello world")
        #expect(result == "world")
    }
}
