import Testing
@testable import DictAI

struct TranscriptCleanerTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let input: String
        let confidence: Double?
        let expected: String
        var testDescription: String { "\"\(input)\" -> \"\(expected)\"" }
    }

    static let junk: [Case] = [
        Case(input: "[BLANK_AUDIO]", confidence: nil, expected: ""),
        Case(input: "So (upbeat music) we start", confidence: nil, expected: "So we start"),
        Case(input: "Thanks for watching!", confidence: nil, expected: ""),
        Case(input: "Subtitles by the Amara.org community", confidence: nil, expected: ""),
        Case(input: "Thank you.", confidence: 0.2, expected: ""),
        Case(input: "Okay. Okay. Okay. Okay.", confidence: nil, expected: "Okay."),
    ]

    static let fillers: [Case] = [
        Case(input: "Um, so we start", confidence: nil, expected: "So we start"),
        Case(input: "I think, uh, we should go", confidence: nil, expected: "I think, we should go"),
        Case(input: "I think umm we're done", confidence: nil, expected: "I think we're done"),
        Case(input: "Er, I think so", confidence: nil, expected: "I think so"),
        Case(input: "Hmm.", confidence: nil, expected: ""),
    ]

    static let stutters: [Case] = [
        Case(input: "I I I think the the plan works", confidence: nil, expected: "I think the plan works"),
        Case(input: "We should we should go", confidence: nil, expected: "We should go"),
        Case(input: "I, I think so", confidence: nil, expected: "I think so"),
    ]

    static let layout: [Case] = [
        Case(input: "hello , world . next", confidence: nil, expected: "Hello, world. Next"),
        Case(input: "  lots   of    space  ", confidence: nil, expected: "Lots of space"),
    ]

    /// Real speech that must come out exactly as it went in.
    static let mustNotChange: [Case] = [
        Case(input: "Thank you.", confidence: 0.9, expected: "Thank you."),
        Case(input: "Thank you.", confidence: nil, expected: "Thank you."),
        Case(input: "Okay. Okay.", confidence: nil, expected: "Okay. Okay."),
        Case(input: "Mm-hmm, yes.", confidence: nil, expected: "Mm-hmm, yes."),
        Case(input: "Uh-huh.", confidence: nil, expected: "Uh-huh."),
        Case(input: "I like it, you know.", confidence: nil, expected: "I like it, you know."),
        Case(input: "I had had enough.", confidence: nil, expected: "I had had enough."),
        Case(input: "I know that that is true.", confidence: nil, expected: "I know that that is true."),
        Case(input: "No. No. That's wrong.", confidence: nil, expected: "No. No. That's wrong."),
        Case(input: "It grew 3.5 percent in the U.S. market.", confidence: nil, expected: "It grew 3.5 percent in the U.S. market."),
        Case(input: "Well, so the numbers are fine.", confidence: nil, expected: "Well, so the numbers are fine."),
        // Review: a repeat across a clause boundary is real speech, not a stutter.
        Case(input: "If you can, can you send it?", confidence: nil, expected: "If you can, can you send it?"),
        Case(input: "Whatever you do, do it well.", confidence: nil, expected: "Whatever you do, do it well."),
        Case(input: "I said no, no one came.", confidence: nil, expected: "I said no, no one came."),
        // Review: "ER" and "err" are words, not fillers.
        Case(input: "He went to the ER.", confidence: nil, expected: "He went to the ER."),
        Case(input: "Err on the side of caution.", confidence: nil, expected: "Err on the side of caution."),
    ]

    @Test(arguments: junk) func removesJunk(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: fillers) func removesFillers(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: stutters) func collapsesStutters(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: layout) func tidiesLayout(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: mustNotChange) func keepsRealSpeech(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }
}
