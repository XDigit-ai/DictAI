import Testing
import Foundation
@testable import DictAI

struct MeetingNotesGeneratorTests {

    // MARK: - Prompt Construction

    @Test func jotAndEnhancePromptIncludesTitle() async throws {
        let prompt = MeetingPrompts.jotAndEnhance(title: "Sprint Planning")
        #expect(prompt.contains("Sprint Planning"))
        #expect(prompt.contains("bold"))
        #expect(prompt.contains("<user-notes>"))
        #expect(prompt.contains("Output ONLY"))
    }

    @Test func transcriptOnlyPromptIncludesTitle() async throws {
        let prompt = MeetingPrompts.transcriptOnly(title: "Q4 Review")
        #expect(prompt.contains("Q4 Review"))
        #expect(prompt.contains("Summary"))
        #expect(prompt.contains("Key Points"))
        #expect(prompt.contains("Action Items"))
        #expect(!prompt.contains("Discussion Highlights"))
        #expect(prompt.contains("Output ONLY"))
        #expect(prompt.contains("Ignore transcription errors"))
    }

    @Test func mergeNotesPromptPreventsMetaCommentary() async throws {
        let prompt = MeetingPrompts.mergeNotes
        #expect(prompt.contains("Do NOT include any commentary"))
        #expect(prompt.contains("Start directly with ## Summary"))
    }

    @Test func quickRecapPromptIsShort() async throws {
        let prompt = MeetingPrompts.quickRecap(title: "Weekly Sync")
        #expect(prompt.contains("Weekly Sync"))
        #expect(prompt.contains("single sentence"))
        #expect(prompt.contains("100 characters"))
    }

    // MARK: - Transcript Formatting

    @Test func formatTranscriptWithSegments() async throws {
        let generator = MeetingNotesGenerator()
        let notes = try await generator.generateNotes(
            transcript: "",
            segments: [],
            userNotes: "",
            title: "Test"
        )
        #expect(notes == "No transcript available.")
    }

    @Test func generateNotesWithUserNotesNoTranscript() async throws {
        let generator = MeetingNotesGenerator()
        let notes = try await generator.generateNotes(
            transcript: "",
            segments: [],
            userNotes: "Remember to follow up on the proposal",
            title: "Test"
        )
        #expect(notes.contains("Remember to follow up on the proposal"))
    }

    @Test func emptyTranscriptReturnsPlaceholder() async throws {
        let generator = MeetingNotesGenerator()
        let notes = try await generator.generateNotes(
            transcript: "   ",
            segments: [],
            userNotes: "",
            title: "Empty Meeting"
        )
        #expect(notes == "No transcript available.")
    }
}
