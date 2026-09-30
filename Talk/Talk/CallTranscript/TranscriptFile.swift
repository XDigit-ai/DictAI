import Foundation

nonisolated enum TranscriptFileError: Error {
    case statusLineMissing
    case malformed
}

/// The only writer of transcript files. Used from one serial queue at a time.
nonisolated final class TranscriptFile: @unchecked Sendable {
    static let livePointerName = "_live.md"

    let url: URL
    private(set) var lastSpeaker: Speaker?
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
    }

    // MARK: - Creating

    /// Creates a new transcript with a unique name in `folder` and points `_live.md` at it.
    static func create(in folder: URL, header: TranscriptHeader, timeZone: TimeZone = .current) throws -> TranscriptFile {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = baseName(started: header.started, title: header.title, timeZone: timeZone)
        let file = try create(at: uniqueURL(in: folder, base: base), header: header, timeZone: timeZone)
        file.pointLiveLink()
        return file
    }

    /// Writes a header to an exact path (used by crash recovery). Does not touch `_live.md`.
    static func create(at url: URL, header: TranscriptHeader, timeZone: TimeZone = .current) throws -> TranscriptFile {
        try Data(TranscriptRenderer.renderHeader(header, timeZone: timeZone).utf8).write(to: url)
        return TranscriptFile(url: url)
    }

    static func baseName(started: Date, title: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(formatter.string(from: started)) \(sanitizedTitle(title))"
    }

    static func sanitizedTitle(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
        let collapsed = replaced.split(separator: " ").joined(separator: " ")
        let limited = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? "Call" : limited
    }

    static func uniqueURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).md")
            n += 1
        }
        return candidate
    }

    // MARK: - Live pointer

    var livePointerURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(Self.livePointerName)
    }

    func pointLiveLink() {
        let fm = FileManager.default
        try? fm.removeItem(at: livePointerURL)
        // Relative destination, so the link survives the folder being moved.
        try? fm.createSymbolicLink(atPath: livePointerURL.path, withDestinationPath: url.lastPathComponent)
    }

    func removeLivePointer() {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: livePointerURL.path)) == url.lastPathComponent {
            try? fm.removeItem(at: livePointerURL)
        }
    }

    // MARK: - Live writing

    /// Appends text. Continues the current paragraph when the speaker is unchanged.
    func append(speaker: Speaker, at time: TimeInterval, text: String) throws {
        guard !text.isEmpty else { return }
        let chunk: String
        if speaker == lastSpeaker {
            chunk = " " + text
        } else {
            let separator = lastSpeaker == nil ? "" : "\n"
            chunk = separator + "\n" + TranscriptRenderer.turnHeading(speaker, at: time) + "\n" + text
        }
        try writeAtEnd(chunk)
        lastSpeaker = speaker
    }

    /// Ends the last paragraph with a newline, matching `TranscriptRenderer.document`.
    func finishLiveText() throws {
        guard lastSpeaker != nil else { return }
        try writeAtEnd("\n")
        lastSpeaker = nil
    }

    private func writeAtEnd(_ string: String) throws {
        let h = try openHandle()
        try h.seekToEnd()
        try h.write(contentsOf: Data(string.utf8))
        try h.synchronize()
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let h = try FileHandle(forWritingTo: url)
        handle = h
        return h
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    // MARK: - Status and replacement

    /// Overwrites the padded status value in place. The file length never changes.
    func setStatus(_ status: TranscriptStatus) throws {
        let data = try Data(contentsOf: url)
        // The header is first in the file, so the first match is the header's line.
        guard let range = data.range(of: Data("\nstatus: ".utf8)) else {
            throw TranscriptFileError.statusLineMissing
        }
        let h = try openHandle()
        try h.seek(toOffset: UInt64(range.upperBound))
        try h.write(contentsOf: Data(TranscriptRenderer.statusValue(status).utf8))
        try h.synchronize()
    }

    /// Everything after the `# Title` line.
    func body() throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let titleMarker = text.range(of: "\n---\n\n# "),
              let lineEnd = text.range(of: "\n", range: titleMarker.upperBound..<text.endIndex)
        else { throw TranscriptFileError.malformed }
        return String(text[lineEnd.upperBound...])
    }

    /// Replaces the header and keeps the body. Only used once the file is no longer live.
    func rewriteHeader(_ header: TranscriptHeader, timeZone: TimeZone = .current) throws {
        var body = try self.body()
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        try replaceAtomically(with: TranscriptRenderer.renderHeader(header, timeZone: timeZone) + body)
    }

    /// Writes to a temporary file in the same folder, then swaps it in.
    func replaceAtomically(with contents: String) throws {
        close()
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try Data(contents.utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
