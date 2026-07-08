import SwiftUI

struct MeetingSettingsTab: View {
    @ObservedObject private var meetingState = MeetingState.shared
    @ObservedObject private var permissionManager = PermissionManager.shared

    var body: some View {
        Form {
            Section("Audio Source") {
                Picker("Capture Mode", selection: $meetingState.audioSource) {
                    Text("Microphone Only").tag("mic")
                    Text("System Audio + Microphone").tag("system+mic")
                }

                if meetingState.audioSource == "system+mic" {
                    HStack {
                        Image(systemName: permissionManager.screenRecordingEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(permissionManager.screenRecordingEnabled ? .green : .orange)
                        Text(permissionManager.screenRecordingEnabled ? "Screen Recording permission granted" : "Screen Recording permission required")
                            .font(.caption)

                        if !permissionManager.screenRecordingEnabled {
                            Spacer()
                            Button("Open Settings") {
                                permissionManager.openScreenRecordingSettings()
                            }
                            .font(.caption)
                        }
                    }

                    Text("System audio capture records what other participants say in Zoom, Meet, Teams, etc. Requires Screen Recording permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transcription") {
                HStack {
                    Text("Chunk Interval")
                    Slider(value: $meetingState.chunkInterval, in: 15...60, step: 5) {
                        Text("Interval")
                    }
                    Text("\(Int(meetingState.chunkInterval))s")
                        .monospacedDigit()
                        .frame(width: 30)
                }

                Text("How often audio is sent to Whisper for transcription. Shorter intervals give faster live transcript but use more CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                Toggle("Auto-generate notes when meeting ends", isOn: $meetingState.autoGenerateNotes)

                Text("Uses your configured LLM provider to generate structured notes from the transcript. You can also generate or regenerate notes manually from the meeting detail view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recommended Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("For best meeting transcription quality:", systemImage: "lightbulb")
                        .font(.caption.bold())

                    Text("Use the **small.en** or **medium.en** Whisper model (Settings > Transcription)")
                        .font(.caption)
                    Text("Use **mistral:7b** or a cloud provider for notes generation")
                        .font(.caption)
                    Text("Chunk interval of **30s** balances latency and accuracy")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
