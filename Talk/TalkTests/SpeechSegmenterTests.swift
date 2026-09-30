import Testing
@testable import DictAI

struct SpeechSegmenterTests {
    let frame = 0.03

    @Test func splitsAtLongPausesWithPreRoll() {
        let audio = silence(1) + tone(2) + silence(2) + tone(1) + silence(1)
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 2)
        #expect(abs(seconds(u[0].startSample) - 0.7) <= frame)     // 1.0 s minus 300 ms pre roll
        #expect(abs(seconds(u[1].startSample) - 4.7) <= frame)
        #expect(abs(seconds(u[0].endSample) - 3.2) <= frame)       // 3.0 s plus 200 ms post roll
    }

    @Test func mergesUtterancesLessThanOneSecondApart() {
        let audio = silence(1) + tone(1) + silence(0.8) + tone(1) + silence(1)
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 1)
        #expect(abs(seconds(u[0].endSample) - 4.0) <= frame)
    }

    @Test func dropsShortBlips() {
        let audio = silence(1) + tone(0.3) + silence(1)
        #expect(SpeechSegmenter.segment(audio).isEmpty)
    }

    @Test func capsLongUtterancesAtTheQuietestPoint() {
        // Speech from 2.0 s to 47.0 s with a near silent dip at 27.5 to 27.6 s.
        let audio = silence(2) + tone(25.5) + tone(0.1, amplitude: 0.001) + tone(19.4) + silence(2)
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 2)
        #expect(u.allSatisfy { seconds($0.samples.count) <= 28.0 })
        #expect(seconds(u[0].endSample) >= 27.5 - frame && seconds(u[0].endSample) <= 27.6 + frame)
        #expect(u[1].startSample == u[0].endSample)
    }

    @Test func risingNoiseFloorDoesNotStartSpeech() {
        var audio = noise(20, rmsFrom: 0.001, rmsTo: 0.004)
        let burst = tone(1, amplitude: 0.1)
        let at = 10 * testSampleRate
        for i in 0..<burst.count { audio[at + i] += burst[i] }
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 1)
        #expect(abs(seconds(u[0].startSample) - 9.7) <= 2 * frame)
    }

    @Test func silenceGivesNothing() {
        #expect(SpeechSegmenter.segment(silence(5)).isEmpty)
        #expect(SpeechSegmenter.segment([]).isEmpty)
    }
}
