import Testing
@testable import DictAI

struct SpeechSegmenterTests {
    let frame = 0.03

    /// Words of 250 ms separated by 50 ms gaps that are quiet but not silent, like real speech.
    func speech(_ seconds: Double) -> [Float] {
        var audio: [Float] = []
        while Double(audio.count) < seconds * Double(testSampleRate) {
            audio += tone(0.25) + tone(0.05, amplitude: 0.005)
        }
        return Array(audio.prefix(Int(seconds * Double(testSampleRate))))
    }

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
        let audio = silence(2) + speech(25.5) + tone(0.1, amplitude: 0.001) + speech(19.4) + silence(2)
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

    /// Phrases of loud and soft words with short pauses, for minutes. A floor that averages in
    /// every frame under its threshold climbs into the soft words and then drops most of the
    /// call; the quietest frame nearby must stay the floor.
    @Test func longSpeechWithSoftWordsIsKeptWhole() {
        var audio = silence(2)
        for _ in 0..<40 {                                   // 40 phrases, 3.3 s each
            for _ in 0..<5 {
                audio += tone(0.2, amplitude: 0.1) + tone(0.3, amplitude: 0.012) + tone(0.06, amplitude: 0.004)
            }
            audio += tone(0.5, amplitude: 0.004)            // pause: 0.0028 rms, under the floor times 3
        }
        audio += silence(2)
        let u = SpeechSegmenter.segment(audio)
        let covered = u.reduce(0) { $0 + $1.samples.count }
        #expect(seconds(covered) >= 0.95 * 40 * 3.3)
        #expect(abs(seconds(u.first!.startSample) - 1.7) <= frame)
        #expect(abs(seconds(u.last!.endSample) - (2 + 40 * 3.3 + 0.2)) <= 2 * frame)
    }

    @Test func windowMinimumTracksTheQuietestNearbyFrame() {
        let values: [Float] = [5, 3, 4, 1, 6, 2, 7]
        #expect(SpeechSegmenter.windowMinimum(values, radius: 1) == [3, 3, 1, 1, 1, 2, 2])
        #expect(SpeechSegmenter.windowMinimum(values, radius: 0) == values)
        #expect(SpeechSegmenter.windowMinimum([], radius: 3) == [])
    }

    @Test func silenceGivesNothing() {
        #expect(SpeechSegmenter.segment(silence(5)).isEmpty)
        #expect(SpeechSegmenter.segment([]).isEmpty)
    }
}
