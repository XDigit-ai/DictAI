import Testing
@testable import DictAI

struct DictationClipperTests {
    let sr = DictationClipper.sampleRate

    @Test func cutsAtTheQuietestFrameBeforeTheTarget() {
        // Speech with one dip at 5.5 s; target 7 s, search window 4 to 7 s.
        let audio = tone(5.5) + tone(0.1, amplitude: 0.001) + tone(4.4)
        let clipper = DictationClipper(clipSeconds: 7)
        let clips = clipper.append(audio)
        #expect(clips.count == 1)
        #expect(abs(seconds(clips[0].samples.count) - 5.5) <= 0.03)
        #expect(clips[0].hasSpeech)
        let rest = clipper.flush()
        #expect(rest != nil)
        #expect(abs(seconds(rest!.samples.count) - 4.5) <= 0.03)
        #expect(clipper.flush() == nil)
    }

    @Test func noDipMeansCutAtTheTarget() {
        let clipper = DictationClipper(clipSeconds: 5)
        let clips = clipper.append(tone(12))
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { seconds($0.samples.count) <= 5.0 && seconds($0.samples.count) >= 2.0 })
    }

    @Test func streamingGivesTheSameCutsAsOneShot() {
        let audio = tone(3) + tone(0.1, amplitude: 0.001) + tone(6) + tone(0.1, amplitude: 0.001) + tone(8)
        let whole = DictationClipper(clipSeconds: 7).append(audio)
        let streaming = DictationClipper(clipSeconds: 7)
        var chunks: [DictationClip] = []
        for start in stride(from: 0, to: audio.count, by: 1_000) {
            chunks += streaming.append(Array(audio[start..<min(audio.count, start + 1_000)]))
        }
        #expect(chunks == whole)
    }

    @Test func silenceIsNotSpeech() {
        let clipper = DictationClipper(clipSeconds: 5)
        let clips = clipper.append(silence(5))
        #expect(clips.count == 1)
        #expect(!clips[0].hasSpeech)
        _ = clipper.append(tone(0.5, amplitude: 0.05))
        #expect(clipper.flush()?.hasSpeech == true)
    }
}
