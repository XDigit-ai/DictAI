import Testing
import Foundation
@testable import DictAI

struct MeetingModelTests {

    // MARK: - Meeting Creation

    @Test func createMeetingDefaults() async throws {
        let meeting = Meeting()
        #expect(meeting.title == "Untitled Meeting")
        #expect(meeting.status == .recording)
        #expect(meeting.transcript.isEmpty)
        #expect(meeting.notes.isEmpty)
        #expect(meeting.userNotes.isEmpty)
        #expect(meeting.duration == 0)
        #expect(meeting.bookmarks.isEmpty)
        #expect(meeting.transcriptSegments.isEmpty)
    }

    @Test func createMeetingCustom() async throws {
        let meeting = Meeting(
            title: "Sprint Planning",
            duration: 3600,
            transcript: "Hello everyone",
            userNotes: "Discuss roadmap",
            status: .complete,
            audioSource: "system+mic"
        )
        #expect(meeting.title == "Sprint Planning")
        #expect(meeting.duration == 3600)
        #expect(meeting.status == .complete)
        #expect(meeting.audioSource == "system+mic")
    }

    // MARK: - Transcript Segments Serialization

    @Test func transcriptSegmentsRoundTrip() async throws {
        let meeting = Meeting()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 30, text: "Hello world", speaker: .me),
            TranscriptSegment(startTime: 30, endTime: 60, text: "Good morning", speaker: .other),
            TranscriptSegment(startTime: 60, endTime: 90, text: "Let's begin", speaker: .unknown)
        ]

        meeting.transcriptSegments = segments

        let loaded = meeting.transcriptSegments
        #expect(loaded.count == 3)
        #expect(loaded[0].text == "Hello world")
        #expect(loaded[0].speaker == .me)
        #expect(loaded[1].text == "Good morning")
        #expect(loaded[1].speaker == .other)
        #expect(loaded[2].speaker == .unknown)
    }

    @Test func emptyTranscriptSegments() async throws {
        let meeting = Meeting()
        #expect(meeting.transcriptSegments.isEmpty)

        meeting.transcriptSegments = []
        #expect(meeting.transcriptSegments.isEmpty)
    }

    // MARK: - Bookmarks Serialization

    @Test func bookmarksRoundTrip() async throws {
        let meeting = Meeting()
        let bookmarks = [
            MeetingBookmark(timestamp: 120, label: "Important decision"),
            MeetingBookmark(timestamp: 300, label: nil),
            MeetingBookmark(timestamp: 600, label: "Action item")
        ]

        meeting.bookmarks = bookmarks

        let loaded = meeting.bookmarks
        #expect(loaded.count == 3)
        #expect(loaded[0].timestamp == 120)
        #expect(loaded[0].label == "Important decision")
        #expect(loaded[1].label == nil)
    }

    // MARK: - Status

    @Test func statusRoundTrip() async throws {
        let meeting = Meeting()
        #expect(meeting.status == .recording)

        meeting.status = .transcribing
        #expect(meeting.statusRaw == "transcribing")
        #expect(meeting.status == .transcribing)

        meeting.status = .generatingNotes
        #expect(meeting.status == .generatingNotes)

        meeting.status = .complete
        #expect(meeting.status == .complete)

        meeting.status = .failed
        #expect(meeting.status == .failed)
    }

    // MARK: - Formatted Duration

    @Test func formattedDuration() async throws {
        let meeting = Meeting(duration: 0)
        #expect(meeting.formattedDuration == "0:00")

        let meeting2 = Meeting(duration: 65)
        #expect(meeting2.formattedDuration == "1:05")

        let meeting3 = Meeting(duration: 3661)
        #expect(meeting3.formattedDuration == "61:01")
    }

    // MARK: - Computed Properties

    @Test func hasNotes() async throws {
        let meeting = Meeting()
        #expect(!meeting.hasNotes)
        meeting.notes = "Some notes"
        #expect(meeting.hasNotes)
    }

    @Test func hasUserNotes() async throws {
        let meeting = Meeting()
        #expect(!meeting.hasUserNotes)
        meeting.userNotes = "  "
        #expect(!meeting.hasUserNotes)
        meeting.userNotes = "Real notes"
        #expect(meeting.hasUserNotes)
    }
}
