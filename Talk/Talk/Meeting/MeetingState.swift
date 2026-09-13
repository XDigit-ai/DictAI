import SwiftUI
import SwiftData
import Combine
import EventKit

/// Central state manager for meeting recording, transcription, and notes generation.
/// Separate from AppState so both dictation and meeting pipelines can coexist.
@MainActor
class MeetingState: ObservableObject {
    static let shared = MeetingState()

    // Recording state
    @Published var isRecording = false
    @Published var meetingDuration: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var meetingTitle: String = "Untitled Meeting"
    @Published var userNotes: String = ""
    @Published var errorMessage: String?

    // Transcript state
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var isTranscribing = false

    // Notes generation
    @Published var isGeneratingNotes = false
    @Published var lastQuickRecap: String?

    // Bookmarks
    @Published var bookmarks: [MeetingBookmark] = []

    // Settings
    @AppStorage("meetingAudioSource") var audioSource: String = "mic"
    @AppStorage("meetingChunkInterval") var chunkInterval: Double = 30
    @AppStorage("meetingAutoGenerateNotes") var autoGenerateNotes: Bool = true
    @AppStorage("meetingKeepAudio") var keepAudio: Bool = false

    // Internal
    private let audioEngine = MeetingAudioEngine()
    private var chunkedTranscriber: ChunkedTranscriber?
    private var durationTimer: Timer?
    private var currentMeeting: Meeting?
    private var modelContainer: ModelContainer?
    private var terminationObserver: Any?
    private var audioLevelCancellable: AnyCancellable?
    private var systemLevelCancellable: AnyCancellable?

    private init() {
        setupTerminationHandler()
        setupAudioLevelObservers()
    }

    // MARK: - Model Container

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    // MARK: - Meeting Control

    func startMeeting() {
        guard !isRecording else { return }

        // Ensure Whisper model is loaded
        guard WhisperState.shared.isModelLoaded else {
            errorMessage = "Whisper model not loaded. Loading now..."
            Task {
                await WhisperState.shared.loadModel()
                if WhisperState.shared.isModelLoaded {
                    errorMessage = nil
                    startMeeting()
                } else {
                    errorMessage = "Failed to load Whisper model. Check Settings > Transcription."
                }
            }
            return
        }

        DebugLogger.log("Starting meeting", subsystem: "Meeting")

        // Reset state
        meetingDuration = 0
        liveSegments = []
        bookmarks = []
        userNotes = ""
        errorMessage = nil
        lastQuickRecap = nil

        // Auto-fill title from calendar
        autoFillTitleFromCalendar()

        // Create SwiftData meeting record
        let meeting = Meeting(
            title: meetingTitle,
            audioSource: audioSource
        )
        currentMeeting = meeting

        if let container = modelContainer {
            let context = ModelContext(container)
            context.insert(meeting)
            try? context.save()
        }

        // Start audio capture
        do {
            let useSystem = audioSource == "system+mic"
            try audioEngine.startCapture(withSystemAudio: useSystem)
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
            DebugLogger.log("Audio start failed: \(error)", subsystem: "Meeting")
            return
        }

        // Start chunked transcription
        let transcriber = ChunkedTranscriber(
            audioEngine: audioEngine,
            chunkInterval: chunkInterval
        )
        transcriber.onSegment = { [weak self] segment in
            Task { @MainActor in
                self?.liveSegments.append(segment)
                self?.currentMeeting?.transcriptSegments = self?.liveSegments ?? []
                self?.currentMeeting?.transcript = self?.liveSegments.map(\.text).joined(separator: " ") ?? ""
            }
        }
        transcriber.onSave = { [weak self] in
            Task { @MainActor in
                self?.saveMeeting()
            }
        }
        transcriber.start()
        chunkedTranscriber = transcriber

        // Start duration timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.meetingDuration += 1.0
            }
        }

        isRecording = true

        // Show dock icon so the meeting window is accessible via Cmd+Tab
        NSApp.setActivationPolicy(.regular)

        DebugLogger.log("Meeting started: \(meetingTitle)", subsystem: "Meeting")
    }

    func stopMeeting() {
        guard isRecording else { return }

        DebugLogger.log("Stopping meeting", subsystem: "Meeting")
        isRecording = false

        // Sync editable fields to the model
        currentMeeting?.title = meetingTitle
        currentMeeting?.userNotes = userNotes
        currentMeeting?.bookmarks = bookmarks

        // Stop everything
        durationTimer?.invalidate()
        durationTimer = nil
        chunkedTranscriber?.stop()
        chunkedTranscriber = nil
        audioEngine.stopCapture()

        // Final transcription of remaining audio
        Task {
            await finalizeTranscription()
            // Restore dock icon preference after processing completes
            AppState.shared.updateDockIconVisibility()
        }
    }

    func cancelMeeting() {
        guard isRecording else { return }

        isRecording = false
        durationTimer?.invalidate()
        durationTimer = nil
        chunkedTranscriber?.stop()
        chunkedTranscriber = nil
        audioEngine.stopCapture()

        // Delete the meeting record
        if let meeting = currentMeeting, let container = modelContainer {
            let context = ModelContext(container)
            context.delete(meeting)
            try? context.save()
        }
        currentMeeting = nil

        DebugLogger.log("Meeting cancelled", subsystem: "Meeting")
    }

    func addBookmark(label: String? = nil) {
        let bookmark = MeetingBookmark(timestamp: meetingDuration, label: label)
        bookmarks.append(bookmark)
        currentMeeting?.bookmarks = bookmarks
        DebugLogger.log("Bookmark added at \(meetingDuration)s", subsystem: "Meeting")
    }

    // MARK: - Notes Generation

    func generateNotes(for meeting: Meeting? = nil) async {
        let target = meeting ?? currentMeeting
        guard let target else { return }

        isGeneratingNotes = true
        target.status = .generatingNotes
        saveMeeting()

        do {
            let generator = MeetingNotesGenerator()
            let notes = try await generator.generateNotes(
                transcript: target.transcript,
                segments: target.transcriptSegments,
                userNotes: target.userNotes,
                title: target.title,
                audioSource: target.audioSource
            )
            target.notes = notes
            target.status = .complete

            // Generate quick recap for menu bar
            let recap = try? await generator.quickRecap(
                transcript: target.transcript,
                title: target.title
            )
            lastQuickRecap = recap

            DebugLogger.log("Notes generated successfully", subsystem: "Meeting")
        } catch {
            DebugLogger.log("Notes generation failed: \(error)", subsystem: "Meeting")
            // Fallback: raw transcript with user notes
            if !target.userNotes.isEmpty {
                target.notes = "## My Notes\n\n\(target.userNotes)\n\n## Transcript\n\n\(target.transcript)"
            } else {
                target.notes = target.transcript
            }
            target.status = .complete
        }

        isGeneratingNotes = false
        saveMeeting()
    }

    // MARK: - Private

    private func finalizeTranscription() async {
        guard let meeting = currentMeeting else { return }

        isTranscribing = true
        meeting.duration = meetingDuration
        meeting.userNotes = userNotes
        meeting.bookmarks = bookmarks
        meeting.status = .transcribing

        // Process any remaining audio
        let remainingMic = audioEngine.consumeMicSamples()
        if remainingMic.count > 800 { // > 50ms of audio at 16kHz
            if let segment = await transcribeChunk(samples: remainingMic, startTime: meetingDuration) {
                liveSegments.append(segment)
            }
        }

        meeting.transcriptSegments = liveSegments
        meeting.transcript = liveSegments.map(\.text).joined(separator: " ")
        isTranscribing = false

        saveMeeting()

        // Auto-generate notes if enabled
        if autoGenerateNotes && !meeting.transcript.isEmpty {
            await generateNotes(for: meeting)
        } else {
            meeting.status = .complete
            saveMeeting()
        }

        DebugLogger.log("Meeting finalized. Segments: \(liveSegments.count), transcript length: \(meeting.transcript.count)", subsystem: "Meeting")
    }

    private func transcribeChunk(samples: [Float], startTime: TimeInterval) async -> TranscriptSegment? {
        // Validate samples
        guard !samples.isEmpty, !samples.contains(where: { $0.isNaN || $0.isInfinite }) else {
            return nil
        }

        do {
            let text = try await WhisperState.shared.transcribeMeetingChunk(samples: samples)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return TranscriptSegment(
                startTime: startTime,
                endTime: startTime + Double(samples.count) / 16000.0,
                text: cleaned,
                speaker: .me // Mic audio defaults to "me"
            )
        } catch {
            DebugLogger.log("Chunk transcription failed: \(error)", subsystem: "Meeting")
            return nil
        }
    }

    private func saveMeeting() {
        guard let meeting = currentMeeting, let container = modelContainer else { return }
        // Sync editable fields before saving
        meeting.title = meetingTitle
        meeting.userNotes = userNotes
        meeting.bookmarks = bookmarks
        let context = ModelContext(container)
        try? context.save()
    }

    private func autoFillTitleFromCalendar() {
        let calendar = CalendarIntegration.shared
        let events = calendar.getTodayEvents()
        let now = Date()

        // Find event that is happening now or starting within 5 minutes
        let currentEvent = events.first { event in
            event.startDate <= now && event.endDate >= now
        } ?? events.first { event in
            let minutesUntilStart = event.startDate.timeIntervalSince(now) / 60
            return minutesUntilStart >= 0 && minutesUntilStart <= 5
        }

        if let event = currentEvent, let title = event.title, !title.isEmpty {
            meetingTitle = title
            DebugLogger.log("Auto-filled title from calendar: \(title)", subsystem: "Meeting")
        }
    }

    private func setupTerminationHandler() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.isRecording {
                    self.isRecording = false
                    self.chunkedTranscriber?.stop()
                    self.audioEngine.stopCapture()
                    self.currentMeeting?.duration = self.meetingDuration
                    self.currentMeeting?.userNotes = self.userNotes
                    self.currentMeeting?.bookmarks = self.bookmarks
                    self.currentMeeting?.transcriptSegments = self.liveSegments
                    self.currentMeeting?.transcript = self.liveSegments.map(\.text).joined(separator: " ")
                    self.currentMeeting?.status = .complete
                    self.saveMeeting()
                    DebugLogger.log("Partial meeting saved on app termination", subsystem: "Meeting")
                }
            }
        }
    }

    private func setupAudioLevelObservers() {
        audioLevelCancellable = audioEngine.$micLevel
            .receive(on: RunLoop.main)
            .assign(to: \.micLevel, on: self)
        systemLevelCancellable = audioEngine.$systemLevel
            .receive(on: RunLoop.main)
            .assign(to: \.systemLevel, on: self)
    }

    // MARK: - Formatted Duration

    var formattedDuration: String {
        let hours = Int(meetingDuration) / 3600
        let minutes = (Int(meetingDuration) % 3600) / 60
        let seconds = Int(meetingDuration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
