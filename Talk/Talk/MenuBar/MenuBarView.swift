import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var whisperState: WhisperState
    @EnvironmentObject var meetingState: MeetingState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status Section
            statusSection

            Divider()
                .padding(.vertical, 8)

            // Meeting Section
            meetingSection

            Divider()
                .padding(.vertical, 8)

            // Mode Toggle
            modeSection

            Divider()
                .padding(.vertical, 8)

            // Last Transcription
            if !appState.lastProcessedText.isEmpty {
                lastTranscriptionSection
                Divider()
                    .padding(.vertical, 8)
            }

            // Actions
            actionsSection
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform.circle")
                    .foregroundStyle(appState.isRecording ? .red : .primary)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // Recording indicator
            if appState.isRecording {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.8)

                    Text("Recording: \(appState.formattedDuration)")
                        .font(.caption)
                        .monospacedDigit()

                    Spacer()

                    Button("Cancel") {
                        appState.cancelRecording()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
                .padding(8)
                .background(.red.opacity(0.1))
                .cornerRadius(6)
            }

            // Processing indicator
            if appState.isProcessing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(appState.processingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.orange.opacity(0.1))
                .cornerRadius(6)
            }

            // Error indicator
            if let error = appState.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Error")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            appState.lastError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(8)
                .background(.red.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var statusTitle: String {
        if appState.isRecording {
            return "Recording..."
        } else if appState.isProcessing {
            return "Processing..."
        } else if !whisperState.isModelLoaded {
            return "Loading Model..."
        } else {
            return "Ready"
        }
    }

    private var statusSubtitle: String {
        if !permissionManager.allPermissionsGranted {
            return "Permissions required"
        }
        let simple = HotkeyManager.shared.simpleHotkey.description
        let agent = HotkeyManager.shared.agentHotkey.description
        return "\(simple) = Dictate, \(agent) = Agent"
    }

    // MARK: - Meeting Section

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if meetingState.isRecording {
                // Active meeting
                HStack {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text("Meeting: \(meetingState.formattedDuration)")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Button("Stop") {
                        meetingState.stopMeeting()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.orange.opacity(0.1))
                .cornerRadius(6)

                Button {
                    AppDelegate.shared?.showMeetingRecordingWindow()
                } label: {
                    Label("Open Meeting Window", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            } else if meetingState.isGeneratingNotes {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Generating meeting notes...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Start meeting / quick recap
                Button {
                    meetingState.startMeeting()
                    DispatchQueue.main.async {
                        AppDelegate.shared?.showMeetingRecordingWindow()
                    }
                } label: {
                    Label("Start Meeting", systemImage: "person.2.wave.2")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .disabled(!whisperState.isModelLoaded)

                if let recap = meetingState.lastQuickRecap {
                    Text(recap)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(6)
                        .background(.quaternary)
                        .cornerRadius(4)
                }
            }

            Button {
                openMeetingsWindow()
            } label: {
                Label("View Meetings", systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }

    private func openMeetingsWindow() {
        DispatchQueue.main.async {
            AppDelegate.shared?.showMeetingsWindow(nil)
        }
    }

    // MARK: - Mode Section

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processing Mode")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $appState.processingMode) {
                ForEach(ProcessingMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(appState.processingMode.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Last Transcription

    private var lastTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last Transcription")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(appState.lastProcessedText)
                .font(.caption)
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .cornerRadius(6)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.lastProcessedText, forType: .string)
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Settings
            SettingsLink {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Divider()
                .padding(.vertical, 4)

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit DictAI", systemImage: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
        .environmentObject(PermissionManager.shared)
        .environmentObject(WhisperState.shared)
        .environmentObject(MeetingState.shared)
}
