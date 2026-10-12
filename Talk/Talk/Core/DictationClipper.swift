import Foundation

/// A stretch of dictation audio for one Whisper call.
nonisolated struct DictationClip: Equatable, Sendable {
    let samples: [Float]
    /// False when no 30 ms frame rises above the speech threshold: not worth a Whisper call.
    let hasSpeech: Bool
}

/// Cuts a dictation stream into clips of about `clipSeconds`, at the quietest point in the
/// last few seconds before the target, so a cut rarely lands inside a word.
nonisolated final class DictationClipper {
    static let sampleRate = 16_000
    static let frameLength = sampleRate * 30 / 1000
    /// Max frame RMS below which a clip is silence.
    static let speechThreshold: Float = 0.005

    let targetSamples: Int
    let searchSamples: Int
    private(set) var buffer: [Float] = []

    init(clipSeconds: Double) {
        let seconds = max(2, clipSeconds)
        targetSamples = Int(seconds * Double(Self.sampleRate))
        searchSamples = Int(min(3, seconds / 2) * Double(Self.sampleRate))
    }

    /// Adds audio and returns every clip that is now complete.
    func append(_ samples: [Float]) -> [DictationClip] {
        buffer += samples
        var clips: [DictationClip] = []
        while buffer.count >= targetSamples {
            let cut = Self.quietestCut(in: buffer, from: targetSamples - searchSamples, to: targetSamples)
            clips.append(Self.clip(Array(buffer[..<cut])))
            buffer.removeFirst(cut)
        }
        return clips
    }

    /// The audio left after the last cut, or nil if there is none.
    func flush() -> DictationClip? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : Self.clip(buffer)
    }

    /// Start of the quietest 30 ms frame between `from` and `to`, if it is a real dip
    /// (under half the window's median energy); otherwise `to`. Without that test a steady
    /// voice would be cut at the start of the window every time.
    static func quietestCut(in samples: [Float], from: Int, to: Int) -> Int {
        var energies: [(start: Int, energy: Float)] = []
        var start = from
        while start + frameLength <= to {
            energies.append((start, rms(samples[start..<start + frameLength])))
            start += frameLength
        }
        guard let quietest = energies.min(by: { $0.energy < $1.energy }) else { return max(1, to) }
        let median = energies.map(\.energy).sorted()[energies.count / 2]
        return quietest.energy < median * 0.5 ? max(1, quietest.start) : max(1, to)
    }

    static func clip(_ samples: [Float]) -> DictationClip {
        var speech = false
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frameLength)
            if rms(samples[start..<end]) > speechThreshold {
                speech = true
                break
            }
            start = end
        }
        return DictationClip(samples: samples, hasSpeech: speech)
    }

    private static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }
}
