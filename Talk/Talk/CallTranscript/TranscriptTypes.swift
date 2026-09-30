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

/// A cleaned piece of text with its absolute start time in the recording.
nonisolated struct TimedText: Equatable, Sendable {
    let speaker: Speaker
    let start: TimeInterval
    let text: String
}
