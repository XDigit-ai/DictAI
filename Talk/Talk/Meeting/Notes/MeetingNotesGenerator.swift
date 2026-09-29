import Foundation

/// Generates structured meeting notes by merging user jots with transcript
/// using the configured LLM provider (Ollama, Claude, or OpenAI).
class MeetingNotesGenerator {
    private let enhancementService = AIEnhancementService.shared

    // Maximum transcript length before chunking (approximate token count)
    private let maxChunkChars = 12_000

    // MARK: - Public API

    func generateNotes(
        transcript: String,
        segments: [TranscriptSegment],
        userNotes: String,
        title: String,
        audioSource: String = "mic"
    ) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return userNotes.isEmpty ? "No transcript available." : "## My Notes\n\n\(userNotes)"
        }

        let formattedTranscript = formatTranscript(segments: segments, rawTranscript: transcript, audioSource: audioSource)

        // Choose prompt based on whether user took notes
        let hasUserNotes = !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // For jotAndEnhance, prepend user notes with delimiters to the transcript text
        let textForLLM: String
        if hasUserNotes {
            textForLLM = "<user-notes>\n\(userNotes)\n</user-notes>\n\n\(formattedTranscript)"
        } else {
            textForLLM = formattedTranscript
        }

        if textForLLM.count <= maxChunkChars {
            // Single-pass generation
            let prompt = hasUserNotes
                ? MeetingPrompts.jotAndEnhance(title: title)
                : MeetingPrompts.transcriptOnly(title: title)
            return try await generateWithTimeout(text: textForLLM, prompt: prompt)
        } else {
            // Chunked generation for long meetings
            return try await generateChunked(
                transcript: textForLLM,
                userNotes: userNotes,
                title: title,
                hasUserNotes: hasUserNotes
            )
        }
    }

    func quickRecap(transcript: String, title: String) async throws -> String {
        let truncated = String(transcript.prefix(2000))
        let prompt = MeetingPrompts.quickRecap(title: title)
        return try await generateWithTimeout(text: truncated, prompt: prompt, timeout: 15)
    }

    // MARK: - Private

    private func generateWithTimeout(text: String, prompt: String, timeout: TimeInterval = 60) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.enhancementService.enhance(text, prompt: prompt)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MeetingNotesError.timeout
            }

            guard let result = try await group.next() else {
                throw MeetingNotesError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func generateChunked(
        transcript: String,
        userNotes: String,
        title: String,
        hasUserNotes: Bool
    ) async throws -> String {
        // Split transcript into chunks
        let chunks = splitIntoChunks(transcript, maxSize: maxChunkChars)

        DebugLogger.log("Long transcript (\(transcript.count) chars) split into \(chunks.count) chunks", subsystem: "Meeting")

        // Generate notes for each chunk
        var chunkNotes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let chunkPrompt = hasUserNotes && i == 0
                ? MeetingPrompts.jotAndEnhance(title: title)
                : MeetingPrompts.transcriptOnly(title: "\(title) (part \(i + 1) of \(chunks.count))")

            let notes = try await generateWithTimeout(text: chunk, prompt: chunkPrompt)
            chunkNotes.append(notes)
        }

        // Merge if multiple chunks
        if chunkNotes.count == 1 {
            return chunkNotes[0]
        }

        let combined = chunkNotes.enumerated()
            .map { "### Part \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")

        return try await generateWithTimeout(text: combined, prompt: MeetingPrompts.mergeNotes)
    }

    private func formatTranscript(segments: [TranscriptSegment], rawTranscript: String, audioSource: String) -> String {
        guard !segments.isEmpty else { return rawTranscript }

        // In mic-only mode, omit speaker labels entirely since all segments are
        // labeled [Me] even when multiple people spoke. Including them would
        // mislead the LLM into treating it as a monologue.
        let isMicOnly = audioSource == "mic"

        return segments.map { seg in
            let time = formatTime(seg.startTime)
            if isMicOnly {
                return "\(time) \(seg.text)"
            }
            let speaker = seg.speaker == .me ? "[Me]" : seg.speaker == .other ? "[Other]" : ""
            return "\(time) \(speaker) \(seg.text)"
        }.joined(separator: "\n")
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "[%d:%02d]", m, s)
    }

    private func splitIntoChunks(_ text: String, maxSize: Int) -> [String] {
        guard text.count > maxSize else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxSize {
                chunks.append(remaining)
                break
            }

            // Find a good split point (end of sentence or paragraph)
            let searchEnd = remaining.index(remaining.startIndex, offsetBy: maxSize)
            let searchRange = remaining.index(searchEnd, offsetBy: -200, limitedBy: remaining.startIndex) ?? remaining.startIndex

            var splitAt = searchEnd
            let searchSlice = remaining[searchRange..<searchEnd]
            if let lastNewline = searchSlice.lastIndex(of: "\n") {
                splitAt = remaining.index(after: lastNewline)
            } else if let lastPeriod = searchSlice.lastIndex(of: ".") {
                splitAt = remaining.index(after: lastPeriod)
            }

            chunks.append(String(remaining[remaining.startIndex..<splitAt]))
            remaining = String(remaining[splitAt...])
        }

        return chunks
    }
}

// MARK: - Errors

enum MeetingNotesError: LocalizedError {
    case timeout
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Notes generation timed out"
        case .generationFailed(let reason):
            return "Notes generation failed: \(reason)"
        }
    }
}
