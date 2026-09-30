import Foundation
import AVFoundation
@testable import DictAI

let utc = TimeZone(identifier: "UTC")!

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictai-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 2026-09-29 14:30:05 UTC.
let sampleStart = Date(timeIntervalSince1970: 1_790_692_205)

func sampleHeader(title: String = "Weekly sync", status: TranscriptStatus = .live) -> TranscriptHeader {
    TranscriptHeader(
        title: title, app: "Zoom", started: sampleStart, ended: nil,
        channels: [.you, .them], liveUnavailable: false, status: status
    )
}

// MARK: - Synthetic audio (16 kHz)

let testSampleRate = 16_000

func seconds(_ sample: Int) -> Double { Double(sample) / Double(testSampleRate) }

func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(testSampleRate)))
}

func tone(_ seconds: Double, amplitude: Float = 0.1, frequency: Double = 220) -> [Float] {
    let count = Int(seconds * Double(testSampleRate))
    return (0..<count).map { i in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / Double(testSampleRate)))
    }
}

/// Deterministic uniform noise whose RMS ramps linearly from `rmsFrom` to `rmsTo`.
func noise(_ seconds: Double, rmsFrom: Float, rmsTo: Float, seed: UInt64 = 42) -> [Float] {
    let count = Int(seconds * Double(testSampleRate))
    var state = seed
    return (0..<count).map { i in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24) * 2 - 1          // -1...1
        let rms = rmsFrom + (rmsTo - rmsFrom) * Float(i) / Float(max(1, count - 1))
        return unit * rms * Float(3).squareRoot()                         // uniform RMS = a / sqrt(3)
    }
}

// MARK: - Fakes

enum FakeError: Error { case failed }

/// Returns scripted segments, one response per call, and records the prompts it was given.
final class FakeTranscriber: UtteranceTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[WhisperSegment]]
    private let failAll: Bool
    private(set) var prompts: [String?] = []

    init(responses: [[WhisperSegment]], failAll: Bool = false) {
        self.responses = responses
        self.failAll = failAll
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] {
        try lock.withLock {
            prompts.append(prompt)
            if failAll { throw FakeError.failed }
            return responses.isEmpty ? [] : responses.removeFirst()
        }
    }
}

func seg(_ text: String, _ start: TimeInterval, confidence: Double? = 0.9) -> WhisperSegment {
    WhisperSegment(text: text, start: start, end: start + 1, confidence: confidence)
}

// MARK: - Scripted call for end to end tests


let e2eEnabled = ProcessInfo.processInfo.environment["DICTAI_E2E"] == "1"

struct ScriptedCall {
    static let youLines = [
        "Good morning, thanks for joining the call today.",
        "I looked at the numbers from last week and the drop is mostly on mobile.",
        "Yes, I will send you the full breakdown after this call.",
    ]
    static let themLines = [
        "Happy to be here. What did you find?",
        "That matches what the support team told us on Monday.",
        "Perfect. Talk to you next week then.",
    ]

    let you: [Float]
    let them: [Float]
    var youText: String { Self.youLines.joined(separator: " ") }
    var themText: String { Self.themLines.joined(separator: " ") }

    /// Voices each line with `say` and lays the turns out alternately with 1 s gaps,
    /// starting with You at 0.5 s. Both channels have the same length.
    static func make() throws -> ScriptedCall {
        let dir = makeTempDirectory()
        func voice(_ text: String, _ name: String) throws -> [Float] {
            let url = dir.appendingPathComponent("\(name).wav")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
            try p.run()
            p.waitUntilExit()
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            return buffer.monoSamples
        }
        var you: [Float] = silence(0.5)
        var them: [Float] = silence(0.5)
        for i in 0..<youLines.count {
            let y = try voice(youLines[i], "you\(i)")
            you += y + silence(1)
            them += silence(seconds(y.count) + 1)
            let t = try voice(themLines[i], "them\(i)")
            them += t + silence(1)
            you += silence(seconds(t.count) + 1)
        }
        let length = max(you.count, them.count)
        you += [Float](repeating: 0, count: length - you.count)
        them += [Float](repeating: 0, count: length - them.count)
        return ScriptedCall(you: you, them: them)
    }
}

func words(_ s: String) -> [String] {
    let cleaned = String(s.lowercased().map { (c: Character) -> Character in
        c.isLetter || c.isNumber || c == "'" ? c : " "
    })
    return cleaned.split(separator: " ").map { String($0) }
}

/// 1 minus word error rate, floored at 0.
func wordAccuracy(expected: String, actual: String) -> Double {
    let e = words(expected), a = words(actual)
    guard !e.isEmpty else { return a.isEmpty ? 1 : 0 }
    var previous = Array(0...a.count)
    for i in 1...e.count {
        var current = [i] + [Int](repeating: 0, count: a.count)
        for j in 1...max(1, a.count) where j <= a.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (e[i - 1] == a[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return max(0, 1 - Double(previous[a.count]) / Double(e.count))
}
