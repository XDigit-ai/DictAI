import Foundation

nonisolated protocol UtteranceTranscribing: Sendable {
    func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment]
}

/// Final pass transcription through the app's shared Whisper model.
nonisolated struct WhisperFinalTranscriber: UtteranceTranscribing {
    func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] {
        do {
            return try await WhisperState.shared.transcribeSegments(samples: samples, initialPrompt: prompt, beamSize: 5)
        } catch WhisperError.modelNotLoaded {
            throw FinalPassError.transcriptionUnavailable
        }
    }
}

nonisolated enum FinalPassError: Error, Equatable {
    /// Every utterance failed, for example because no Whisper model could be loaded.
    case transcriptionUnavailable
}

/// Transcribes complete recordings after the call and renders the final document.
nonisolated enum FinalPass {
    static let promptCharacters = 200

    struct ChannelResult: Sendable {
        var items: [TimedText] = []
        var attempted = 0
        var failed = 0
        /// The transcriber cannot work at all (no model); nothing more was attempted.
        var unavailable = false
    }

    static func transcribeChannel(
        _ samples: [Float], speaker: Speaker, using transcriber: UtteranceTranscribing, sampleRate: Int = 16_000
    ) async -> ChannelResult {
        var result = ChannelResult()
        var context = ""
        for utterance in SpeechSegmenter.segment(samples) {
            result.attempted += 1
            let prompt = context.isEmpty ? nil : String(context.suffix(promptCharacters))
            let segments: [WhisperSegment]
            do {
                segments = try await transcriber.transcribe(samples: utterance.samples, prompt: prompt)
            } catch FinalPassError.transcriptionUnavailable {
                result.failed += 1
                result.unavailable = true
                break
            } catch {
                result.failed += 1
                DebugLogger.log("Final pass failed at sample \(utterance.startSample): \(error)", subsystem: "Calls")
                continue
            }
            let offset = Double(utterance.startSample) / Double(sampleRate)
            for segment in segments {
                let text = TranscriptCleaner.clean(segment.text, confidence: segment.confidence)
                guard !text.isEmpty else { continue }
                result.items.append(TimedText(speaker: speaker, start: offset + segment.start, text: text))
                context += (context.isEmpty ? "" : " ") + text
            }
        }
        return result
    }

    /// Sorted by start time (ties: You first), consecutive same speaker text joined.
    static func mergeIntoTurns(_ items: [TimedText]) -> [Turn] {
        let sorted = items.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.speaker != b.element.speaker { return a.element.speaker == .you }
            return a.offset < b.offset
        }.map(\.element)
        var turns: [Turn] = []
        for item in sorted {
            if let last = turns.last, last.speaker == item.speaker {
                turns[turns.count - 1].text += " " + item.text
            } else {
                turns.append(Turn(speaker: item.speaker, start: item.start, text: item.text))
            }
        }
        return turns
    }

    static func render(
        channels: [Speaker: [Float]], header: TranscriptHeader,
        using transcriber: UtteranceTranscribing, timeZone: TimeZone = .current
    ) async throws -> String {
        var items: [TimedText] = []
        var attempted = 0
        var failed = 0
        for speaker in Speaker.allCases {
            guard let samples = channels[speaker] else { continue }
            let result = await transcribeChannel(samples, speaker: speaker, using: transcriber)
            if result.unavailable { throw FinalPassError.transcriptionUnavailable }
            items += result.items
            attempted += result.attempted
            failed += result.failed
        }
        if attempted > 0, failed == attempted { throw FinalPassError.transcriptionUnavailable }
        var finalHeader = header
        finalHeader.status = .final
        return TranscriptRenderer.document(header: finalHeader, turns: mergeIntoTurns(items), timeZone: timeZone)
    }
}
