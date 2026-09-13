import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @State private var isRegenerating = false
    @State private var regenerateTask: Task<Void, Never>?
    @State private var showCopiedToast = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left: Transcript
                transcriptPane
                    .frame(width: geo.size.width * 0.5)

                Divider()

                // Right: Notes
                notesPane
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItemGroup {
                if isRegenerating {
                    ProgressView()
                        .scaleEffect(0.7)
                    Button("Cancel") {
                        regenerateTask?.cancel()
                        regenerateTask = nil
                        isRegenerating = false
                    }
                } else {
                    Button {
                        regenerateNotes()
                    } label: {
                        Label("Regenerate Notes", systemImage: "arrow.clockwise")
                    }
                    .disabled(meeting.transcript.isEmpty)
                }

                Menu {
                    Button {
                        copyNotes()
                    } label: {
                        Label("Copy Notes", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        copyAsEmail()
                    } label: {
                        Label("Copy as Email", systemImage: "envelope")
                    }

                    Button {
                        exportMarkdown()
                    } label: {
                        Label("Export Markdown", systemImage: "arrow.down.doc")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Transcript Pane

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Transcript", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                Text(meeting.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if meeting.transcriptSegments.isEmpty && !meeting.transcript.isEmpty {
                // Raw transcript fallback
                ScrollView {
                    Text(meeting.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if meeting.transcriptSegments.isEmpty {
                ContentUnavailableView("No Transcript", systemImage: "waveform.slash",
                    description: Text("No transcript was recorded for this meeting."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(meeting.transcriptSegments) { segment in
                            segmentRow(segment)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let isBookmarked = meeting.bookmarks.contains { bookmark in
            abs(bookmark.timestamp - segment.startTime) < 5
        }

        return HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(formatTime(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)

            // Speaker badge
            Text(segment.speaker == .me ? "Me" : segment.speaker == .other ? "Other" : "")
                .font(.caption2.bold())
                .foregroundStyle(segment.speaker == .me ? .blue : .green)
                .frame(width: 35, alignment: .leading)

            // Text
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .background(isBookmarked ? Color.orange.opacity(0.05) : Color.clear)
    }

    // MARK: - Notes Pane

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                if meeting.hasUserNotes {
                    Text("Jot-enhanced")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding()

            Divider()

            if meeting.notes.isEmpty && !isRegenerating {
                VStack(spacing: 12) {
                    ContentUnavailableView("No Notes Yet", systemImage: "sparkles",
                        description: Text("Generate notes from the transcript."))

                    if !meeting.transcript.isEmpty {
                        Button("Generate Notes") {
                            regenerateNotes()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ScrollView {
                    Text(LocalizedStringKey(meeting.notes))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Actions

    private func regenerateNotes() {
        isRegenerating = true
        regenerateTask = Task {
            do {
                let generator = MeetingNotesGenerator()
                let notes = try await generator.generateNotes(
                    transcript: meeting.transcript,
                    segments: meeting.transcriptSegments,
                    userNotes: meeting.userNotes,
                    title: meeting.title,
                    audioSource: meeting.audioSource
                )
                if !Task.isCancelled {
                    meeting.notes = notes
                    meeting.status = .complete
                }
            } catch {
                if !Task.isCancelled {
                    DebugLogger.log("Notes regeneration failed: \(error)", subsystem: "Meeting")
                }
            }
            isRegenerating = false
        }
    }

    private func copyNotes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.notes, forType: .string)
        showCopied()
    }

    private func copyAsEmail() {
        let email = """
        Subject: Meeting Notes - \(meeting.title)

        Hi,

        Here are the notes from our meeting on \(meeting.formattedDate):

        \(meeting.notes)

        Best regards
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
        showCopied()
    }

    private func exportMarkdown() {
        let markdown = """
        ---
        title: \(meeting.title)
        date: \(ISO8601DateFormatter().string(from: meeting.date))
        duration: \(meeting.formattedDuration)
        ---

        # \(meeting.title)

        **Date:** \(meeting.formattedDate)
        **Duration:** \(meeting.formattedDuration)

        \(meeting.notes)

        ---

        ## Full Transcript

        \(meeting.transcript)
        """

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(meeting.title.replacingOccurrences(of: " ", with: "-")).md"

        if panel.runModal() == .OK, let url = panel.url {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func showCopied() {
        withAnimation { showCopiedToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showCopiedToast = false }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }
}
