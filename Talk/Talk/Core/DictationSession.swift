import Foundation

/// One push to talk take. In live mode, clips go to Whisper while the user is still
/// talking and the text so far is reported through `onText`; `finish` only has the last
/// clip left to do. Otherwise the whole take is transcribed once at the end.
@MainActor
final class DictationSession {
    typealias Transcribe = @Sendable (_ samples: [Float], _ prompt: String?) async throws -> String

    /// Characters of earlier text given to Whisper as context for the next clip.
    static let promptCharacters = 200
    /// Whisper wants at least a second of audio; shorter clips are padded with silence.
    static let minimumSamples = DictationClipper.sampleRate

    let live: Bool
    var onText: ((String) -> Void)?
    private(set) var texts: [String] = []
    var text: String { texts.joined(separator: " ") }

    private let clipper: DictationClipper
    private let transcribe: Transcribe
    private var all: [Float] = []
    private var pending: [DictationClip] = []
    private var worker: Task<Void, Never>?
    private var failure: Error?
    private var cancelled = false

    init(live: Bool, clipSeconds: Double, transcribe: @escaping Transcribe) {
        self.live = live
        self.clipper = DictationClipper(clipSeconds: clipSeconds)
        self.transcribe = transcribe
    }

    func append(_ samples: [Float]) {
        guard !cancelled else { return }
        if live {
            for clip in clipper.append(samples) { enqueue(clip) }
        } else {
            all += samples
        }
    }

    /// The full text. Waits for clips still being transcribed.
    func finish() async throws -> String {
        if live {
            if let clip = clipper.flush() { enqueue(clip) }
            while let worker { await worker.value }
            if let failure { throw failure }
            return text
        }
        return try await transcribe(Self.padded(all), nil)
    }

    func cancel() {
        cancelled = true
        pending.removeAll()
        worker?.cancel()
    }

    private func enqueue(_ clip: DictationClip) {
        guard clip.hasSpeech else { return }
        pending.append(clip)
        pump()
    }

    private func pump() {
        guard worker == nil, failure == nil, !pending.isEmpty else { return }
        let clip = pending.removeFirst()
        let prompt = text.isEmpty ? nil : String(text.suffix(Self.promptCharacters))
        worker = Task {
            do {
                let piece = try await transcribe(Self.padded(clip.samples), prompt)
                if !piece.isEmpty, !cancelled {
                    texts.append(piece)
                    onText?(text)
                }
            } catch {
                if !cancelled { failure = error }
            }
            worker = nil
            pump()
        }
    }

    static func padded(_ samples: [Float]) -> [Float] {
        samples.count >= minimumSamples
            ? samples : samples + [Float](repeating: 0, count: minimumSamples - samples.count)
    }
}
