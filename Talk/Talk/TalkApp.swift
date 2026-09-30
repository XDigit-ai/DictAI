import SwiftUI

@main
struct TalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var permissionManager = PermissionManager.shared
    @StateObject private var whisperState = WhisperState.shared
    @StateObject private var hotkeyManager = HotkeyManager.shared
    @StateObject private var callSession = CallSession.shared

    var body: some Scene {
        // Menu bar app
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(whisperState)
                .environmentObject(callSession)
        } label: {
            MenuBarIcon(isRecording: appState.isRecording, isCallRecording: callSession.isRecording)
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
    var isCallRecording: Bool = false

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        if isCallRecording { return "record.circle.fill" }
        if isRecording { return "waveform.circle.fill" }
        return "waveform.circle"
    }

    private var iconColor: Color {
        if isCallRecording { return .red }
        if isRecording { return .red }
        return .primary
    }
}
