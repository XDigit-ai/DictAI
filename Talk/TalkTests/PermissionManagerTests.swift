import Testing
@testable import DictAI

@MainActor
struct PermissionManagerTests {

    /// Checking the Screen Recording status must never show the macOS prompt, so it
    /// has to come from the preflight check, synchronously, not from ScreenCaptureKit.
    @Test func screenRecordingCheckUsesPreflightOnly() {
        let manager = PermissionManager.shared
        let original = PermissionManager.screenRecordingPreflight
        defer { PermissionManager.screenRecordingPreflight = original }

        PermissionManager.screenRecordingPreflight = { true }
        manager.checkScreenRecordingPermission()
        #expect(manager.screenRecordingEnabled == true)

        PermissionManager.screenRecordingPreflight = { false }
        manager.checkScreenRecordingPermission()
        #expect(manager.screenRecordingEnabled == false)
    }
}
