import Foundation

/// Markdown for transcript files. The only place the file format is defined.
nonisolated enum TranscriptRenderer {
    /// Length of the longest status value, `ended-live-only`.
    static let statusWidth = 15

    static func statusValue(_ status: TranscriptStatus) -> String {
        status.rawValue.padding(toLength: statusWidth, withPad: " ", startingAt: 0)
    }

    static func timestamp(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "00:00:00" }        // Int(NaN) would crash
        let total = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func isoDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Front matter plus the `# Title` line, ending with a newline.
    static func renderHeader(_ h: TranscriptHeader, timeZone: TimeZone = .current) -> String {
        let title = h.title.replacingOccurrences(of: "\n", with: " ")
        var lines = [
            "---",
            "title: \(quoted(title))",
            "app: \(quoted(h.app))",
            "started: \(isoDate(h.started, timeZone: timeZone))",
        ]
        if let ended = h.ended {
            lines.append("ended: \(isoDate(ended, timeZone: timeZone))")
            lines.append("duration: \(timestamp(ended.timeIntervalSince(h.started)))")
        }
        lines.append("channels: \(h.channels.map(\.rawValue).joined(separator: ", "))")
        lines.append("language: en")
        if h.liveUnavailable { lines.append("live: unavailable") }
        lines.append("status: \(statusValue(h.status))")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func turnHeading(_ speaker: Speaker, at t: TimeInterval) -> String {
        "**\(speaker.label)** · \(timestamp(t))"
    }

    static func document(header: TranscriptHeader, turns: [Turn], timeZone: TimeZone = .current) -> String {
        renderHeader(header, timeZone: timeZone)
            + turns.map { "\n\(turnHeading($0.speaker, at: $0.start))\n\($0.text)\n" }.joined()
    }
}
