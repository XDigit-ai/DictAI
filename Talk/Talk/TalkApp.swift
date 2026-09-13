import SwiftUI
import SwiftData

@main
struct TalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var permissionManager = PermissionManager.shared
    @StateObject private var whisperState = WhisperState.shared
    @StateObject private var hotkeyManager = HotkeyManager.shared
    @StateObject private var meetingState = MeetingState.shared

    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([Meeting.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            modelContainer = container
            // Pass the container to MeetingState for persistence
            MeetingState.shared.setModelContainer(container)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        // Menu bar app
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(whisperState)
                .environmentObject(meetingState)
        } label: {
            MenuBarIcon(isRecording: appState.isRecording, isMeetingActive: meetingState.isRecording)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(whisperState)
        }

        // Hidden window for permissions onboarding (shown on first launch)
        Window("Welcome to DictAI", id: "onboarding") {
            PermissionsView()
                .environmentObject(permissionManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}


// MARK: - Menu Bar Icon
struct MenuBarIcon: View {
    let isRecording: Bool
    var isMeetingActive: Bool = false

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        if isMeetingActive { return "record.circle.fill" }
        if isRecording { return "waveform.circle.fill" }
        return "waveform.circle"
    }

    private var iconColor: Color {
        if isMeetingActive { return .orange }
        if isRecording { return .red }
        return .primary
    }
}
