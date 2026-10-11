import Combine
import Foundation

nonisolated enum CallNotesError: LocalizedError, Equatable {
    case noTranscript
    case transcriptEmpty
    case llmNotConfigured

    var errorDescription: String? {
        switch self {
        case .noTranscript: return "No call transcript found"
        case .transcriptEmpty: return "The transcript has no text"
        case .llmNotConfigured: return "Set up an LLM provider under Settings, Enhancement"
        }
    }
}

/// Meeting notes made from a transcript with the Enhancement LLM. The transcript is never
/// changed; the notes go to a `<transcript name> Notes.md` file next to it.
@MainActor
final class CallNotes: ObservableObject {
    static let shared = CallNotes(
        generate: { try await AIEnhancementService.shared.generate(text: $0, systemPrompt: $1) },
        isConfigured: { AIEnhancementService.shared.isConfigured })

    static let notesSuffix = " Notes.md"
    /// Transcript text per LLM request. Long calls are summarised in parts, then merged.
    static let chunkCharacters = 6_000

    @Published private(set) var isRunning = false
    @Published private(set) var lastNotesURL: URL?
    @Published private(set) var lastError: String?

    private let generate: (String, String) async throws -> String
    private let isConfigured: () -> Bool

    init(generate: @escaping (String, String) async throws -> String, isConfigured: @escaping () -> Bool = { true }) {
        self.generate = generate
        self.isConfigured = isConfigured
    }

    // MARK: - Entry points

    /// Notes for the most recent transcript in the folder.
    func makeForLatest(in folder: URL = CallSettings.folderURL) async {
        guard let transcript = Self.latestTranscript(in: folder) else {
            lastError = CallNotesError.noTranscript.localizedDescription
            return
        }
        await make(for: transcript)
    }

    /// Writes the notes file for `transcript`. Errors are reported in `lastError`.
    func make(for transcript: URL) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        defer { isRunning = false }
        do {
            lastNotesURL = try await write(for: transcript)
            DebugLogger.log("Notes written: \(lastNotesURL!.lastPathComponent)", subsystem: "Calls")
        } catch {
            lastError = error.localizedDescription
            DebugLogger.log("Notes failed for \(transcript.lastPathComponent): \(error)", subsystem: "Calls")
        }
    }

    func write(for transcript: URL) async throws -> URL {
        guard isConfigured() else { throw CallNotesError.llmNotConfigured }
        let text = try String(contentsOf: transcript, encoding: .utf8)
        let (title, body) = Self.split(text)
        let parts = Self.chunks(of: body)
        guard !parts.isEmpty else { throw CallNotesError.transcriptEmpty }

        var notes: [String] = []
        for part in parts {
            notes.append(try await generate(part, LLMPrompts.callNotes))
        }
        var result = notes[0]
        if notes.count > 1 {
            let joined = notes.enumerated().map { "# Part \($0.offset + 1)\n\n\($0.element)" }.joined(separator: "\n\n")
            if joined.count <= Self.chunkCharacters * 2 {
                result = try await generate(joined, LLMPrompts.callNotesMerge)
            } else {
                result = joined                              // too long to merge in one request
            }
        }

        let url = Self.notesURL(for: transcript)
        let document = "---\ntitle: \(TranscriptRenderer.quoted(title + " Notes"))\n"
            + "transcript: \(TranscriptRenderer.quoted(transcript.lastPathComponent))\n---\n\n"
            + "# \(title) Notes\n\n" + result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try Data(document.utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Pure helpers

    static func notesURL(for transcript: URL) -> URL {
        let base = transcript.deletingPathExtension().lastPathComponent
        return transcript.deletingLastPathComponent().appendingPathComponent(base + notesSuffix)
    }

    static func isNotesFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(notesSuffix)
    }

    /// The newest transcript (not a notes file, not being written) in the folder.
    static func latestTranscript(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return urls
            .filter { $0.pathExtension == "md" && !isNotesFile($0) && $0.lastPathComponent != "_live.md" && !$0.lastPathComponent.hasPrefix(".") }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The `# Title` and the text after it. Files without front matter are all body.
    static func split(_ text: String) -> (title: String, body: String) {
        guard let marker = text.range(of: "\n---\n\n# "),
              let lineEnd = text.range(of: "\n", range: marker.upperBound..<text.endIndex)
        else { return ("Call", text) }
        return (String(text[marker.upperBound..<lineEnd.lowerBound]), String(text[lineEnd.upperBound...]))
    }

    /// Splits the body at turn headings into pieces of at most `limit` characters.
    /// A single turn longer than the limit is split at paragraph, then line, breaks.
    static func chunks(of body: String, limit: Int = chunkCharacters) -> [String] {
        let turns = body.components(separatedBy: "\n\n**").enumerated().map { i, s in
            (i == 0 ? s : "**" + s).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(current) }
            current = ""
        }
        for turn in turns {
            for piece in pieces(of: turn, limit: limit) {
                if !current.isEmpty, current.count + 2 + piece.count > limit { flush() }
                current += (current.isEmpty ? "" : "\n\n") + piece
            }
        }
        flush()
        return out
    }

    private static func pieces(of turn: String, limit: Int) -> [String] {
        guard turn.count > limit else { return [turn] }
        var out: [String] = []
        for paragraph in turn.components(separatedBy: "\n\n") {
            if paragraph.count <= limit {
                out.append(paragraph)
                continue
            }
            var current = ""
            for sentence in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                if !current.isEmpty, current.count + 1 + sentence.count > limit {
                    out.append(current)
                    current = ""
                }
                current += (current.isEmpty ? "" : " ") + sentence
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }
}
