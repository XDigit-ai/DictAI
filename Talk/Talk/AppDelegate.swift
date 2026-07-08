import AppKit
import SwiftData
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private var recordingPanel: NSPanel?
    private var agentPanel: NSPanel?
    private var agentStepObserver: Any?
    private var meetingWindow: NSWindow?
    private var meetingsListWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This app is the host for the unit-test bundle. When running under XCTest,
        // skip the full bootstrap: booting whisper/Metal here triggers a ggml teardown
        // abort at test-process exit (ggml_metal_rsets_free -> ggml_abort), and none of
        // the app services are needed for the logic tests.
        if NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        AppDelegate.shared = self
        // Set dock icon visibility based on user preference
        AppState.shared.updateDockIconVisibility()

        // Setup hotkey manager
        HotkeyManager.shared.setup()

        // Check permissions on launch
        PermissionManager.shared.checkAllPermissions()

        // Show onboarding if first launch or permissions missing
        if !PermissionManager.shared.allPermissionsGranted {
            showOnboarding()
        } else if !UserRegistrationService.shared.isRegistered {
            // Permissions granted but not registered - show registration
            showRegistration()
        }

        // Load Whisper model
        Task {
            await WhisperState.shared.loadModel()
        }

        // Auto-launch Ollama if installed
        Task {
            await OllamaManager.shared.ensureRunning()
        }

        // Bootstrap autocomplete engine (no-op until user enables it in Settings)
        AutocompleteEngine.shared.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup
        HotkeyManager.shared.cleanup()
        // MeetingState handles its own termination via NotificationCenter
    }

    // MARK: - Meeting Recording Window

    func showMeetingRecordingWindow() {
        if meetingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meeting"
            window.center()
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("meetingRecording")

            let hostingView = NSHostingView(rootView:
                MeetingRecordingView()
                    .environmentObject(MeetingState.shared)
            )
            window.contentView = hostingView
            meetingWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.meetingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hideMeetingRecordingWindow() {
        meetingWindow?.orderOut(nil)
        // Restore dock icon preference if no other meeting windows are open
        if meetingsListWindow?.isVisible != true {
            AppState.shared.updateDockIconVisibility()
        }
    }

    @objc func showMeetingsWindow(_ sender: Any?) {
        if meetingsListWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meetings"
            window.center()
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("meetingsList")

            // Create a model container for the meetings list
            do {
                let schema = Schema([Meeting.self])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
                let container = try ModelContainer(for: schema, configurations: [config])

                let hostingView = NSHostingView(rootView:
                    MeetingListView()
                        .environmentObject(MeetingState.shared)
                        .modelContainer(container)
                )
                window.contentView = hostingView
            } catch {
                DebugLogger.log("Failed to create model container for meetings window: \(error)", subsystem: "Meeting")
                return
            }

            meetingsListWindow = window
        }

        // Ensure dock icon is visible so user can Cmd+Tab to the window
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.meetingsListWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Recording Panel

    func showRecordingPanel() {
        if recordingPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden

            let hostingView = NSHostingView(rootView:
                MiniRecorderView()
                    .environmentObject(AppState.shared)
                    .environmentObject(WhisperState.shared)
            )
            panel.contentView = hostingView

            recordingPanel = panel
        }

        // Position near mouse cursor
        if NSScreen.main != nil {
            let mouseLocation = NSEvent.mouseLocation
            let panelSize = recordingPanel!.frame.size
            let x = mouseLocation.x - panelSize.width / 2
            let y = mouseLocation.y + 20
            recordingPanel?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        recordingPanel?.orderFront(nil)
    }

    func hideRecordingPanel() {
        recordingPanel?.orderOut(nil)
    }

    // MARK: - Agent Processing Overlay

    func showAgentOverlay() {
        // Always recreate the hosting view to ensure fresh SwiftUI observation
        if agentPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            agentPanel = panel
        }

        // Refresh the SwiftUI content to ensure proper @Published observation
        let overlayView = AgentOverlayView()
            .environmentObject(AppState.shared)
            .environmentObject(AgentPipeline.shared)
        agentPanel?.contentView = NSHostingView(rootView: overlayView)

        // Position at top-center of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth: CGFloat = 240
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - 170
            agentPanel?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        agentPanel?.orderFront(nil)
    }

    func hideAgentOverlay() {
        // Delay so user can see the completion state
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.agentPanel?.orderOut(nil)
        }
    }

    // MARK: - Onboarding

    private var onboardingWindow: NSWindow?

    private func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "DictAI Setup"
            window.center()
            window.identifier = NSUserInterfaceItemIdentifier("onboarding")

            let hostingView = NSHostingView(rootView:
                PermissionsView()
                    .environmentObject(PermissionManager.shared)
            )
            window.contentView = hostingView

            onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Registration

    private var registrationWindow: NSWindow?

    func showRegistration() {
        if registrationWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "DictAI Pro"
            window.center()
            window.identifier = NSUserInterfaceItemIdentifier("registration")

            let hostingView = NSHostingView(rootView: RegistrationView())
            window.contentView = hostingView

            registrationWindow = window
        }

        registrationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
