import Foundation
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
