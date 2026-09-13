import SwiftUI

/// Floating window shown during an active meeting.
/// Transitions through states: recording -> processing -> done.
struct MeetingRecordingView: View {
    @EnvironmentObject var meetingState: MeetingState

    var body: some View {
        VStack(spacing: 0) {
            if meetingState.isRecording {
                recordingView
            } else if meetingState.isTranscribing || meetingState.isGeneratingNotes {
                processingView
            } else {
                completedView
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(.background)
    }

    // MARK: - Recording State

    private var recordingView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(0.8)

                TextField("Meeting Title", text: $meetingState.meetingTitle)
                    .textFieldStyle(.plain)
                    .font(.headline)

                Spacer()

                Text(meetingState.formattedDuration)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                audioLevels
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Notepad + transcript
            HSplitView {
                notepadSection
                    .frame(minWidth: 200)
                transcriptSection
                    .frame(minWidth: 200)
            }

            Divider()

            // Footer
            HStack {
                Button {
                    meetingState.addBookmark()
                } label: {
                    Label("Bookmark", systemImage: "bookmark.fill")
                        .font(.caption)
                }
                .keyboardShortcut("b", modifiers: .command)
                .help("Bookmark this moment (Cmd+B)")

                if !meetingState.bookmarks.isEmpty {
                    Text("\(meetingState.bookmarks.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2))
                        .cornerRadius(4)
                }

                Spacer()

                if let error = meetingState.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Button(role: .destructive) {
                    meetingState.stopMeeting()
                } label: {
                    Label("Stop Meeting", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Processing State

    private var processingView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(meetingState.isTranscribing ? "Transcribing remaining audio..." : "Generating meeting notes...")
                .font(.headline)

            Text(meetingState.meetingTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(meetingState.liveSegments.count) segments, \(meetingState.formattedDuration)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Completed State

    private var completedView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Meeting Ended")
                .font(.headline)

            Text(meetingState.meetingTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("\(meetingState.liveSegments.count) segments transcribed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Duration: \(meetingState.formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let recap = meetingState.lastQuickRecap {
                    Text(recap)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }

            HStack(spacing: 12) {
                Button("View Meeting") {
                    AppDelegate.shared?.showMeetingsWindow(nil)
                    closeWindow()
                }
                .buttonStyle(.borderedProminent)

                Button("Close") {
                    closeWindow()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subviews

    private var audioLevels: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                AudioLevelBar(level: meetingState.micLevel)
                    .frame(width: 40, height: 8)
            }

            if meetingState.audioSource == "system+mic" {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    AudioLevelBar(level: meetingState.systemLevel)
                        .frame(width: 40, height: 8)
                }
            }
        }
    }

    private var notepadSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notes", systemImage: "pencil.line")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            TextEditor(text: $meetingState.userNotes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Live Transcript", systemImage: "text.quote")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(meetingState.liveSegments.count) segments")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if meetingState.liveSegments.isEmpty {
                VStack {
                    Spacer()
                    Text("Transcript will appear here as you speak...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(meetingState.liveSegments.suffix(10)) { segment in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(formatTime(segment.startTime))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 30, alignment: .trailing)

                                    if segment.speaker != .unknown {
                                        Text(segment.speaker == .me ? "Me" : "Other")
                                            .font(.caption2.bold())
                                            .foregroundStyle(segment.speaker == .me ? .blue : .green)
                                    }

                                    Text(segment.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: meetingState.liveSegments.count) { _, _ in
                        if let last = meetingState.liveSegments.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func closeWindow() {
        AppDelegate.shared?.hideMeetingRecordingWindow()
    }
}

// MARK: - Audio Level Bar

struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}
