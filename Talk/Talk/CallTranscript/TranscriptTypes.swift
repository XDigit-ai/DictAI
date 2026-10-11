import Foundation

/// Which side of the call a piece of speech came from.
nonisolated enum Speaker: String, Codable, Sendable, CaseIterable {
    case you
    case them

    var label: String { self == .you ? "You" : "Them" }
}

/// Lifecycle of a transcript file. See the spec's "Agent contract".
nonisolated enum TranscriptStatus: String, Codable, Sendable {
    case live
    case processing
    case `final`
    case endedLiveOnly = "ended-live-only"
}

nonisolated struct TranscriptHeader: Equatable, Codable, Sendable {
    var title: String
    var app: String
    var started: Date
    var ended: Date?
    var channels: [Speaker]
    var liveUnavailable: Bool
    var status: TranscriptStatus
}

/// One speaker paragraph in the transcript.
nonisolated struct Turn: Equatable, Sendable {
    let speaker: Speaker
    let start: TimeInterval
    var text: String
}

/// A cleaned piece of text with its absolute start and end times in the recording.
nonisolated struct TimedText: Equatable, Sendable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    init(speaker: Speaker, start: TimeInterval, end: TimeInterval? = nil, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end ?? start
        self.text = text
    }
}

/// Where a speaker's text is split into paragraphs, so a long turn is not one block.
nonisolated enum Paragraphing {
    /// A pause this long between two pieces of the same speaker starts a new paragraph.
    static let pauseSeconds: TimeInterval = 1.5
    /// A paragraph at least this long ends at the next sentence end.
    static let maxCharacters = 600

    /// True if `next` should start a new paragraph after `paragraph`, given the silence between them.
    static func breaks(after paragraph: String, gap: TimeInterval) -> Bool {
        if gap >= pauseSeconds { return true }
        guard paragraph.count >= maxCharacters, let last = paragraph.last else { return false }
        return ".?!".contains(last)
    }
}
