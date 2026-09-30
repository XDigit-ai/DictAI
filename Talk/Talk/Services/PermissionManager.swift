import AVFoundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Combine

@MainActor
class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published var accessibilityEnabled: Bool = false
    @Published var screenRecordingEnabled: Bool = false

    /// Check if running in sandbox (App Store version)
    var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// In sandboxed mode, accessibility is not needed (clipboard-only mode)
    var allPermissionsGranted: Bool {
        if isSandboxed {
            return microphoneStatus == .authorized
        }
        return microphoneStatus == .authorized && accessibilityEnabled
    }

    private init() {
        checkAllPermissions()
    }

    // MARK: - Check Permissions

    func checkAllPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
        checkScreenRecordingPermission()
    }

    func checkMicrophonePermission() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func checkAccessibilityPermission() {
        // Check without prompting
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Request Permissions

    func requestMicrophonePermission() async -> Bool {
        print("[PermissionManager] Requesting microphone permission...")
        print("[PermissionManager] Current status: \(microphoneStatus.rawValue)")

        // If already denied or restricted, open Settings instead
        if microphoneStatus == .denied || microphoneStatus == .restricted {
            print("[PermissionManager] Permission denied/restricted, opening Settings...")
            await MainActor.run {
                openMicrophoneSettings()
            }
            return false
        }

        // Try multiple methods to trigger permission dialog
        print("[PermissionManager] Trying AVCaptureDevice.requestAccess...")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        print("[PermissionManager] AVCaptureDevice result: \(granted)")

        // If that didn't work, try triggering by creating an audio session
        if !granted && microphoneStatus == .notDetermined {
            print("[PermissionManager] Trying AVAudioRecorder approach...")
            await triggerMicPermissionViaRecorder()
        }

        await MainActor.run {
            checkMicrophonePermission() // Re-check actual status
            print("[PermissionManager] Updated status: \(microphoneStatus.rawValue)")

            // If still not determined or denied, open settings
            if microphoneStatus != .authorized {
                print("[PermissionManager] Opening Settings as fallback...")
                openMicrophoneSettings()
            }
        }
        return microphoneStatus == .authorized
    }

    private func triggerMicPermissionViaRecorder() async {
        // Create a temporary audio recorder to trigger permission
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("permission_test.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1
        ]

        do {
            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.prepareToRecord()
            // This should trigger the permission dialog
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            recorder.stop()
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            print("[PermissionManager] Recorder trigger failed: \(error)")
        }
    }

    func requestAccessibilityPermission() {
        print("[PermissionManager] Requesting accessibility permission...")

        // First try the system prompt
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("[PermissionManager] AXIsProcessTrusted result: \(trusted)")

        // Also open System Settings directly for reliability
        openAccessibilitySettings()

        // Start polling to detect when user grants permission
        startAccessibilityPolling()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// Reads the Screen Recording status without prompting. Touching ScreenCaptureKit here
    /// showed the macOS permission dialog on every launch and every check.
    static var screenRecordingPreflight: () -> Bool = { CGPreflightScreenCaptureAccess() }

    func checkScreenRecordingPermission() {
        screenRecordingEnabled = Self.screenRecordingPreflight()
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Triggers the Screen Recording permission prompt by attempting a no-op capture,
    /// then opens System Settings as a reliable fallback.
    func requestScreenRecordingPermission() {
        Task {
            // Touching SCShareableContent triggers the TCC prompt on first use
            _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            await MainActor.run {
                self.checkScreenRecordingPermission()
                self.openScreenRecordingSettings()
            }
        }
    }

    var screenRecordingStatusText: String {
        screenRecordingEnabled ? "Granted" : "Required for OCR context — Click to enable"
    }

    // MARK: - Polling for Accessibility

    private var accessibilityTimer: Timer?

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.checkAccessibilityPermission()
                if self.accessibilityEnabled {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    // MARK: - Permission Status Text

    var microphoneStatusText: String {
        switch microphoneStatus {
        case .authorized:
            return "Granted"
        case .denied:
            return "Denied - Click to open Settings"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    var accessibilityStatusText: String {
        accessibilityEnabled ? "Granted" : "Required - Click to enable"
    }
}
