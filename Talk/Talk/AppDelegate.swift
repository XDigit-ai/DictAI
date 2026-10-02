import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private var recordingPanel: NSPanel?

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

        // Clipboard history: start capture and connect the recall hotkey.
        ClipboardManager.shared.start()
        HotkeyManager.shared.onClipboardRecall = {
            ClipboardManager.shared.showPicker()
        }

        // Call transcripts: detect calls and finish any transcript left by a crash.
        CallSession.shared.bootstrap()

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
        ClipboardManager.shared.stop()
        CallSession.shared.handleTermination()
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
