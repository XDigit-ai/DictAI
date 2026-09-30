import AVFoundation
import Speech

nonisolated struct LiveResult: Equatable, Sendable {
    let speaker: Speaker
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let text: String
    let confidence: Double?
}

nonisolated protocol LiveTranscribing: AnyObject, Sendable {
    var speaker: Speaker { get }
    /// Prepares the engine. Buffers appended before this returns are dropped.
    func start(onResult: @escaping @Sendable (LiveResult) -> Void) async throws
    /// Any PCM format. Must be called from one thread at a time.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finalizes everything appended so far and waits for the last results.
    func finish() async
}

nonisolated enum LiveTranscriberError: Error {
    case noAudioFormat
}

nonisolated enum LiveSpeechAssets {
    static let locale = Locale(identifier: "en-US")

    /// Installs the on device English model if needed. False if it cannot be used.
    static func ensureInstalled() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            DebugLogger.log("Speech asset install failed: \(error)", subsystem: "Calls")
            return false
        }
        return await isInstalled()
    }

    static func isInstalled() async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }
}

/// One SpeechAnalyzer and SpeechTranscriber for one channel. Only finalized results
/// are reported, so nothing written to the live file is ever retracted.
nonisolated final class AppleLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let speaker: Speaker

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AudioBufferConverter?
    private var resultsTask: Task<Void, Never>?

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    func start(onResult: @escaping @Sendable (LiveResult) -> Void) async throws {
        let transcriber = SpeechTranscriber(
            locale: LiveSpeechAssets.locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTranscriberError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let speaker = self.speaker

        let task = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let confidences = result.text.runs.compactMap { $0.transcriptionConfidence }
                    let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    onResult(LiveResult(speaker: speaker, start: result.range.start.seconds, text: text, confidence: confidence))
                }
            } catch {
                DebugLogger.log("Live results for \(speaker.rawValue) ended: \(error)", subsystem: "Calls")
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        lock.withLock {
            self.analyzer = analyzer
            self.continuation = continuation
            self.analyzerFormat = format
            self.resultsTask = task
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let analyzerFormat else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AudioBufferConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converted = converter?.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        let (analyzer, continuation, task) = lock.withLock { (self.analyzer, self.continuation, self.resultsTask) }
        continuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            DebugLogger.log("Live finish for \(speaker.rawValue) failed: \(error)", subsystem: "Calls")
        }
        await task?.value
    }
}
