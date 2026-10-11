import Foundation

nonisolated struct Utterance: Equatable, Sendable {
    let startSample: Int
    let samples: [Float]
    var endSample: Int { startSample + samples.count }
}

nonisolated struct SegmenterConfig: Sendable {
    var sampleRate = 16_000
    var frameMs = 30
    var startSpeechMs = 150
    var endSilenceMs = 700
    var preRollMs = 300
    var postRollMs = 200
    var minSpeechMs = 400
    var maxUtteranceSec = 28.0
    var mergeGapSec = 1.0
    var capSearchSec = 3.0
    var noiseFactor: Float = 3
    var minThreshold: Float = 0.002
    /// Seconds of audio either side of a frame over which the noise floor is the quietest frame.
    var floorWindowSec = 3.0
}

/// Splits a recorded channel into utterances at natural pauses, for the final pass.
/// Energy based: a minimum tracking noise floor, hysteresis on speech start and end,
/// merging of close utterances and a hard cap just under Whisper's 30 s window.
nonisolated enum SpeechSegmenter {

    static func segment(_ samples: [Float], config c: SegmenterConfig = .init()) -> [Utterance] {
        let frameLen = c.sampleRate * c.frameMs / 1000
        guard samples.count >= frameLen else { return [] }
        let energies = frameEnergies(samples, frameLen: frameLen)
        let voiced = voicedFlags(energies, config: c)
        let preRoll = c.preRollMs / c.frameMs
        let postRoll = c.postRollMs / c.frameMs
        let minFrames = c.minSpeechMs / c.frameMs

        var ranges: [Range<Int>] = speechSpans(voiced, config: c).compactMap { span in
            guard span.last - span.first + 1 >= minFrames else { return nil }
            let start = max(0, (span.first - preRoll) * frameLen)
            let end = min(samples.count, (span.last + 1 + postRoll) * frameLen)
            return start..<end
        }
        ranges = merge(ranges, config: c)
        ranges = ranges.flatMap { split($0, energies: energies, frameLen: frameLen, config: c) }
        return ranges.map { Utterance(startSample: $0.lowerBound, samples: Array(samples[$0])) }
    }

    static func frameEnergies(_ samples: [Float], frameLen: Int) -> [Float] {
        stride(from: 0, to: samples.count, by: frameLen).map { start in
            let end = min(samples.count, start + frameLen)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    /// Speech when energy exceeds `max(floor * noiseFactor, minThreshold)`. The floor is the
    /// quietest frame within `floorWindowSec` either side, so it follows slowly changing noise
    /// but cannot climb into speech: a speaker who talks for minutes still leaves gaps between
    /// words that are quieter than the words. (An averaging floor fed by every frame under the
    /// threshold runs away during long speech and silences most of a call.)
    static func voicedFlags(_ energies: [Float], config c: SegmenterConfig) -> [Bool] {
        let floors = windowMinimum(energies, radius: Int(c.floorWindowSec * 1000 / Double(c.frameMs)))
        return zip(energies, floors).map { e, floor in e > max(floor * c.noiseFactor, c.minThreshold) }
    }

    /// Minimum of `values[i - radius ... i + radius]` for each `i`, clipped at the ends. O(n).
    static func windowMinimum(_ values: [Float], radius: Int) -> [Float] {
        guard !values.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: values.count)
        var deque: [Int] = []       // indices with increasing values; front is the window minimum
        var head = 0
        for j in 0..<values.count + radius {
            if j < values.count {
                while deque.count > head, values[deque.last!] >= values[j] { deque.removeLast() }
                deque.append(j)
            }
            let i = j - radius
            guard i >= 0 else { continue }
            while deque[head] < i - radius { head += 1 }
            out[i] = values[deque[head]]
        }
        return out
    }

    /// Inclusive first and last voiced frame of each utterance.
    static func speechSpans(_ voiced: [Bool], config c: SegmenterConfig) -> [(first: Int, last: Int)] {
        let startFrames = max(1, c.startSpeechMs / c.frameMs)
        let endFrames = max(1, c.endSilenceMs / c.frameMs)
        var spans: [(first: Int, last: Int)] = []
        var run = 0
        var silent = 0
        var current: (first: Int, last: Int)?
        for (i, v) in voiced.enumerated() {
            if var span = current {
                if v {
                    span.last = i
                    current = span
                    silent = 0
                } else {
                    silent += 1
                    if silent >= endFrames {
                        spans.append(span)
                        current = nil
                        silent = 0
                        run = 0
                    }
                }
            } else {
                run = v ? run + 1 : 0
                if run >= startFrames {
                    current = (i - run + 1, i)
                    run = 0
                }
            }
        }
        if let span = current { spans.append(span) }
        return spans
    }

    static func merge(_ ranges: [Range<Int>], config c: SegmenterConfig) -> [Range<Int>] {
        let gap = Int(c.mergeGapSec * Double(c.sampleRate))
        let maxLen = Int(c.maxUtteranceSec * Double(c.sampleRate))
        var out: [Range<Int>] = []
        for r in ranges {
            guard let last = out.last else {
                out.append(r)
                continue
            }
            if r.lowerBound - last.upperBound < gap, r.upperBound - last.lowerBound <= maxLen {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else if r.lowerBound < last.upperBound {
                out.append(last.upperBound..<r.upperBound)   // rolls overlapped: no shared samples
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Cuts anything longer than the cap at the quietest frame in the last `capSearchSec`.
    static func split(_ r: Range<Int>, energies: [Float], frameLen: Int, config c: SegmenterConfig) -> [Range<Int>] {
        let maxLen = Int(c.maxUtteranceSec * Double(c.sampleRate))
        let search = Int(c.capSearchSec * Double(c.sampleRate))
        var out: [Range<Int>] = []
        var start = r.lowerBound
        while r.upperBound - start > maxLen {
            let windowEnd = start + maxLen
            let firstFrame = (windowEnd - search) / frameLen
            let lastFrame = min(energies.count - 1, windowEnd / frameLen - 1)
            var cutFrame = lastFrame
            if firstFrame <= lastFrame {
                cutFrame = (firstFrame...lastFrame).min { energies[$0] < energies[$1] } ?? lastFrame
            }
            let cut = max(start + 1, min(windowEnd, cutFrame * frameLen))
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<r.upperBound)
        return out
    }
}
