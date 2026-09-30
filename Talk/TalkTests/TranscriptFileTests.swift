import Testing
import Foundation
@testable import DictAI

struct TranscriptFileTests {

    @Test func headerHasPaddedStatusAndQuotedTitle() {
        let text = TranscriptRenderer.renderHeader(sampleHeader(title: #"Q3: plan "final""#), timeZone: utc)
        let expected = [
            "---",
            #"title: "Q3: plan \"final\"""#,
            #"app: "Zoom""#,
            "started: 2026-09-29T14:30:05Z",
            "channels: you, them",
            "language: en",
            "status: live" + String(repeating: " ", count: 11),
            "---",
            "",
            #"# Q3: plan "final""#,
        ].joined(separator: "\n") + "\n"
        #expect(text == expected)
    }

    @Test func endedHeaderHasDurationAndLiveUnavailable() {
        var h = sampleHeader(status: .final)
        h.ended = sampleStart.addingTimeInterval(1956)
        h.channels = [.you]
        h.liveUnavailable = true
        let text = TranscriptRenderer.renderHeader(h, timeZone: utc)
        #expect(text.contains("ended: 2026-09-29T15:02:41Z\nduration: 00:32:36\n"))
        #expect(text.contains("channels: you\n"))
        #expect(text.contains("live: unavailable\n"))
        #expect(text.contains("status: final          \n"))
    }

    /// Review: a non-finite time from the speech engine must not crash the app.
    @Test func timestampOfNonFiniteTimeIsZero() {
        #expect(TranscriptRenderer.timestamp(.nan) == "00:00:00")
        #expect(TranscriptRenderer.timestamp(.infinity) == "00:00:00")
    }

    @Test func fileNameIsSanitized() {
        #expect(TranscriptFile.sanitizedTitle("Q3: plan/review \"final\"") == "Q3 plan review final")
        #expect(TranscriptFile.sanitizedTitle("  \n ") == "Call")
        #expect(TranscriptFile.sanitizedTitle(String(repeating: "a", count: 200)).count == 80)
        #expect(TranscriptFile.baseName(started: sampleStart, title: "Weekly sync", timeZone: utc)
                == "2026-09-29 1430 Weekly sync")
    }

    @Test func createWritesHeaderAndLivePointer() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        #expect(file.url.lastPathComponent == "2026-09-29 1430 Weekly sync.md")
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("_live.md").path)
        #expect(link == file.url.lastPathComponent)
    }

    @Test func nameCollisionGetsSuffix() throws {
        let dir = makeTempDirectory()
        _ = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        let second = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        #expect(second.url.lastPathComponent == "2026-09-29 1430 Weekly sync (2).md")
    }

    @Test func liveAppendsMatchFinalDocumentLayout() throws {
        let dir = makeTempDirectory()
        let header = sampleHeader()
        let file = try TranscriptFile.create(in: dir, header: header, timeZone: utc)
        try file.append(speaker: .you, at: 4, text: "So I looked at the numbers.")
        try file.append(speaker: .you, at: 7, text: "The drop is on mobile.")
        try file.append(speaker: .them, at: 11, text: "That matches.")
        try file.finishLiveText()
        let expected = TranscriptRenderer.document(header: header, turns: [
            Turn(speaker: .you, start: 4, text: "So I looked at the numbers. The drop is on mobile."),
            Turn(speaker: .them, start: 11, text: "That matches."),
        ], timeZone: utc)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == expected)
    }

    @Test func setStatusChangesOnlyTheHeaderInPlace() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        // Review Focus 1: body text that looks like a status line.
        try file.append(speaker: .you, at: 1, text: "Status: done")
        try file.append(speaker: .them, at: 2, text: "ok")
        let before = try Data(contentsOf: file.url)
        try file.setStatus(.processing)
        let after = try String(contentsOf: file.url, encoding: .utf8)
        #expect(try Data(contentsOf: file.url).count == before.count)
        #expect(after.contains("status: processing     \n---"))
        #expect(after.contains("**You** · 00:00:01\nStatus: done"))
    }

    @Test func rewriteHeaderKeepsBody() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        try file.append(speaker: .you, at: 1, text: "Hello there.")
        var h = sampleHeader(status: .endedLiveOnly)
        h.ended = sampleStart.addingTimeInterval(60)
        try file.rewriteHeader(h, timeZone: utc)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("status: ended-live-only\n"))
        #expect(text.hasSuffix("# Weekly sync\n\n**You** · 00:00:01\nHello there.\n"))
    }

    @Test func replaceAtomicallySwapsContents() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        try file.replaceAtomically(with: "final text\n")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "final text\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func removeLivePointerOnlyRemovesItsOwnLink() throws {
        let dir = makeTempDirectory()
        let first = try TranscriptFile.create(in: dir, header: sampleHeader(title: "First"), timeZone: utc)
        let second = try TranscriptFile.create(in: dir, header: sampleHeader(title: "Second"), timeZone: utc)
        first.removeLivePointer()
        let link = dir.appendingPathComponent("_live.md").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == second.url.lastPathComponent)
        second.removeLivePointer()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil)
    }
}
