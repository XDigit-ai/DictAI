import Foundation

/// Timer-based chunked transcription engine.
/// Accumulates audio samples from MeetingAudioEngine, then transcribes
/// every `chunkInterval` seconds with VAD gating and overlap deduplication.
class ChunkedTranscriber {
    var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    var onSave: (@Sendable () -> Void)?

    private let audioEngine: MeetingAudioEngine
    let chunkInterval: TimeInterval
    private var timer: Timer?
    private var chunkCount = 0
    private var meetingStartTime = Date()
    private var previousLastWords: [String] = []
    private let dedupLock = NSLock()

    // VAD threshold: skip chunks quieter than this RMS value
    private let vadThreshold: Float = 0.005

    init(audioEngine: MeetingAudioEngine, chunkInterval: TimeInterval = 30) {
        self.audioEngine = audioEngine
        self.chunkInterval = chunkInterval
    }

    func start() {
        meetingStartTime = Date()
        chunkCount = 0
        dedupLock.lock()
        previousLastWords = []
        dedupLock.unlock()

        timer = Timer.scheduledTimer(withTimeInterval: chunkInterval, repeats: true) { [weak self] _ in
            self?.processChunk()
        }
        DebugLogger.log("ChunkedTranscriber started with interval: \(chunkInterval)s", subsystem: "Meeting")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        processChunk()
        DebugLogger.log("ChunkedTranscriber stopped after \(chunkCount) chunks", subsystem: "Meeting")
    }

    // MARK: - Chunk Processing

    private func processChunk() {
        let micSamples = audioEngine.consumeMicSamples()
        let systemSamples = audioEngine.consumeSystemSamples()

        if !micSamples.isEmpty {
            processChannel(samples: micSamples, speaker: .me)
        }

        if !systemSamples.isEmpty {
            processChannel(samples: systemSamples, speaker: .other)
        }

        chunkCount += 1

        // Save to SwiftData every 5 chunks
        if chunkCount % 5 == 0 {
            onSave?()
        }
    }

    private func processChannel(samples: [Float], speaker: SpeakerLabel) {
        let rms = computeRMS(samples)
        guard rms > vadThreshold else {
            DebugLogger.log("Chunk \(chunkCount) skipped (RMS=\(rms) < \(vadThreshold)), speaker=\(speaker.rawValue)", subsystem: "Meeting")
            return
        }

        guard !samples.contains(where: { $0.isNaN || $0.isInfinite }) else {
            DebugLogger.log("Chunk \(chunkCount) skipped: invalid samples", subsystem: "Meeting")
            return
        }

        let chunkStartTime = Double(chunkCount) * chunkInterval
        let chunkIdx = chunkCount

        Task { @MainActor in
            do {
                let text = try await WhisperState.shared.transcribeMeetingChunk(samples: samples)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }

                let deduplicated = self.deduplicateOverlap(cleaned)
                guard !deduplicated.isEmpty else { return }

                let segment = TranscriptSegment(
                    startTime: chunkStartTime,
                    endTime: chunkStartTime + Double(samples.count) / 16000.0,
                    text: deduplicated,
                    speaker: speaker
                )

                self.onSegment?(segment)
            } catch {
                DebugLogger.log("Transcription failed for chunk \(chunkIdx): \(error)", subsystem: "Meeting")
            }
        }
    }

    // MARK: - Overlap Deduplication

    /// Compares the first N words of the new text with the last N words of the
    /// previous chunk to remove duplicate content from overlapping audio.
    func deduplicateOverlap(_ newText: String) -> String {
        let newWords = newText.split(separator: " ").map(String.init)
        guard !newWords.isEmpty else { return newText }

        dedupLock.lock()
        let prevWords = previousLastWords
        dedupLock.unlock()

        let compareCount = min(10, min(newWords.count, prevWords.count))

        if compareCount > 0 {
            var bestMatch = 0
            for length in stride(from: compareCount, through: 1, by: -1) {
                let prevSuffix = Array(prevWords.suffix(length))
                let newPrefix = Array(newWords.prefix(length))

                if prevSuffix.map({ $0.lowercased() }) == newPrefix.map({ $0.lowercased() }) {
                    bestMatch = length
                    break
                }
            }

            if bestMatch > 0 {
                DebugLogger.log("Dedup: removed \(bestMatch) overlapping words", subsystem: "Meeting")
                let remaining = Array(newWords.dropFirst(bestMatch))
                dedupLock.lock()
                previousLastWords = Array(newWords.suffix(min(10, newWords.count)))
                dedupLock.unlock()
                return remaining.joined(separator: " ")
            }
        }

        dedupLock.lock()
        previousLastWords = Array(newWords.suffix(min(10, newWords.count)))
        dedupLock.unlock()
        return newText
    }

    // MARK: - DSP

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }
}
