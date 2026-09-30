import AppKit
import SwiftUI

struct CallTranscriptSettingsTab: View {
    @AppStorage(CallSettings.folderKey) private var folderPath = CallSettings.defaultFolder.path
    @AppStorage(CallSettings.autoDetectKey) private var autoDetect = true
    @AppStorage(CallSettings.keepAudioKey) private var keepAudio = false

    var body: some View {
        Form {
            Section("Transcripts folder") {
                HStack {
                    Text(folderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                    Button("Open") { NSWorkspace.shared.open(CallSettings.folderURL) }
                }
                Text("Each call is saved as a Markdown file here. While a call is being transcribed, _live.md in this folder points to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calls") {
                Toggle("Offer to transcribe when a call starts", isOn: $autoDetect)
                Toggle("Keep call audio next to transcripts", isOn: $keepAudio)
            }

            Section("Permissions") {
                Text("The first call asks for System Audio Recording permission, which lets DictAI hear the other side of the call. If you declined it, allow DictAI under Privacy & Security, Screen & System Audio Recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    PermissionManager.shared.openScreenRecordingSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = CallSettings.folderURL
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
