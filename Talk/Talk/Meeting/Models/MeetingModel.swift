import Foundation
import SwiftData

// MARK: - Meeting Status

enum MeetingStatus: String, Codable {
    case recording
    case transcribing
    case generatingNotes
    case complete
    case failed
}

// MARK: - Speaker Label

enum SpeakerLabel: String, Codable {
    case me
    case other
    case unknown
}

// MARK: - Transcript Segment

struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: SpeakerLabel

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: SpeakerLabel = .unknown) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

// MARK: - Meeting Bookmark

struct MeetingBookmark: Codable, Identifiable {
    let id: UUID
    let timestamp: TimeInterval
    let label: String?

    init(timestamp: TimeInterval, label: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.label = label
    }
}

// MARK: - Meeting Model

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var transcript: String
    var transcriptSegmentsData: Data?
    var userNotes: String
    var notes: String
    var notesTemplate: String
    var statusRaw: String
    var audioSource: String
    var bookmarksData: Data?

    init(
        title: String = "Untitled Meeting",
        date: Date = Date(),
        duration: TimeInterval = 0,
        transcript: String = "",
        userNotes: String = "",
        notes: String = "",
        notesTemplate: String = "general",
        status: MeetingStatus = .recording,
        audioSource: String = "mic"
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.duration = duration
        self.transcript = transcript
        self.userNotes = userNotes
        self.notes = notes
        self.notesTemplate = notesTemplate
        self.statusRaw = status.rawValue
        self.audioSource = audioSource
    }

    // MARK: - Computed Properties

    var status: MeetingStatus {
        get { MeetingStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var transcriptSegments: [TranscriptSegment] {
        get {
            guard let data = transcriptSegmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
        }
        set {
            transcriptSegmentsData = try? JSONEncoder().encode(newValue)
        }
    }

    var bookmarks: [MeetingBookmark] {
        get {
            guard let data = bookmarksData else { return [] }
            return (try? JSONDecoder().decode([MeetingBookmark].self, from: data)) ?? []
        }
        set {
            bookmarksData = try? JSONEncoder().encode(newValue)
        }
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var hasNotes: Bool {
        !notes.isEmpty
    }

    var hasUserNotes: Bool {
        !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
