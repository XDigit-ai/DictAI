import Foundation
import Testing
@testable import DictAI

@MainActor
struct CallNotesTests {
    let transcript = """
    ---
    title: "Weekly sync"
    app: "Zoom"
    started: 2026-10-11T19:17:33+04:00
    channels: you, them
    language: en
    status: final          
    ---

    # Weekly sync

    **You** · 00:00:01
    Let's start with the budget.

    **Them** · 00:00:05
    We agreed to cut it by ten percent. Sam owns the plan.

    """

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesNotesFileNextToTheTranscript() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("2026-10-11 1917 Weekly sync.md")
        try transcript.write(to: url, atomically: true, encoding: .utf8)
        var prompts: [String] = []
        let notes = CallNotes(generate: { text, prompt in
            prompts.append(prompt)
            #expect(text.hasPrefix("**You** · 00:00:01"))
            #expect(text.contains("Sam owns the plan."))
            return "## Summary\nBudget cut by ten percent.\n"
        })
        let out = try await notes.write(for: url)
        #expect(out.lastPathComponent == "2026-10-11 1917 Weekly sync Notes.md")
        let written = try String(contentsOf: out, encoding: .utf8)
        #expect(written.hasPrefix("---\ntitle: \"Weekly sync Notes\"\ntranscript: \"2026-10-11 1917 Weekly sync.md\"\n---\n\n# Weekly sync Notes\n\n## Summary"))
        #expect(written.hasSuffix("ten percent.\n"))
        #expect(prompts == [LLMPrompts.callNotes])
    }

    @Test func longTranscriptsAreSummarisedInPartsThenMerged() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("Long call.md")
        let long = String(repeating: "**Them** · 00:00:05\n" + String(repeating: "Point. ", count: 500) + "\n\n", count: 5)
        try ("---\ntitle: \"Long call\"\n---\n\n# Long call\n\n" + long).write(to: url, atomically: true, encoding: .utf8)
        var prompts: [String] = []
        let notes = CallNotes(generate: { text, prompt in
            prompts.append(prompt)
            #expect(text.count <= CallNotes.chunkCharacters * 2)
            return prompt == LLMPrompts.callNotesMerge ? "merged" : "part"
        })
        let out = try await notes.write(for: url)
        #expect(prompts.count == 6)                                        // 5 turns of 3520 chars, 1 merge
        #expect(prompts.last == LLMPrompts.callNotesMerge)
        #expect(try String(contentsOf: out, encoding: .utf8).hasSuffix("# Long call Notes\n\nmerged\n"))
    }

    @Test func chunksKeepTurnsTogetherAndSplitOversizedOnes() {
        let body = "**You** · 00:00:01\naaa\n\n**Them** · 00:00:02\nbbb\n\n**You** · 00:00:03\n" + String(repeating: "word ", count: 30)
        let chunks = CallNotes.chunks(of: body, limit: 60)
        #expect(chunks[0] == "**You** · 00:00:01\naaa\n\n**Them** · 00:00:02\nbbb")
        #expect(chunks.count >= 4)
        #expect(chunks.allSatisfy { $0.count <= 60 })
        #expect(chunks.joined(separator: " ").filter { $0 == "w" }.count == 30)   // nothing lost
    }

    @Test func latestTranscriptSkipsNotesAndLivePointer() throws {
        let dir = try folder()
        let fm = FileManager.default
        let old = dir.appendingPathComponent("2026-10-10 0900 Old.md")
        let new = dir.appendingPathComponent("2026-10-11 0900 New.md")
        try "a".write(to: old, atomically: true, encoding: .utf8)
        try "b".write(to: new, atomically: true, encoding: .utf8)
        try "n".write(to: dir.appendingPathComponent("2026-10-11 0900 New Notes.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("_live.md"), withDestinationURL: new)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: new.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.appendingPathComponent("2026-10-11 0900 New Notes.md").path)
        #expect(CallNotes.latestTranscript(in: dir)?.resolvingSymlinksInPath() == new.resolvingSymlinksInPath())
    }

    @Test func unconfiguredProviderIsReported() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("Call.md")
        try transcript.write(to: url, atomically: true, encoding: .utf8)
        let notes = CallNotes(generate: { _, _ in "x" }, isConfigured: { false })
        await notes.make(for: url)
        #expect(notes.lastError == CallNotesError.llmNotConfigured.localizedDescription)
        #expect(notes.lastNotesURL == nil)
    }
}
