import AppKit
import Carbon.HIToolbox
import UserNotifications

/// Pastes text at the current cursor position in any application
class CursorPaster {

    /// Check if the app is running in a sandboxed environment
    static var isSandboxed: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Paste text at the current cursor position
    /// - Parameters:
    ///   - text: The text to paste
    ///   - preserveClipboard: If true, restores the original clipboard after pasting
    static func paste(_ text: String, preserveClipboard: Bool = true) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard if needed (only for non-sandboxed auto-paste)
        var savedItems: [(NSPasteboard.PasteboardType, Data)] = []
        if preserveClipboard && !isSandboxed && AXIsProcessTrusted() {
            savedItems = saveClipboard()
        }

        // Set new text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        recordDictationInHistory(text)

        // In sandboxed mode or without accessibility, just copy to clipboard and notify
        if isSandboxed || !AXIsProcessTrusted() {
            showClipboardNotification(text: text)
            return
        }

        // Small delay to ensure clipboard is ready
        usleep(100000)  // 100ms

        // Simulate Cmd+V
        pasteViaCmdV()

        // Restore original clipboard after a longer delay
        if preserveClipboard && !savedItems.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                restoreClipboard(savedItems)
            }
        }
    }

    // MARK: - Notification for Clipboard Mode

    private static func showClipboardNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Text Ready to Paste"
        content.body = "Press ⌘V to paste your transcription"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to show notification: \(error)")
            }
        }

        // Also play a sound to indicate completion
        NSSound.beep()
    }

    // MARK: - Keyboard Simulation

    /// Simulate ⌘V into the frontmost application. Requires Accessibility.
    static func pasteViaCmdV() {
        guard AXIsProcessTrusted() else {
            print("Accessibility permission not granted - cannot simulate paste")
            return
        }

        let source = CGEventSource(stateID: .privateState)
        let kVK_V: CGKeyCode = 0x09

        // Create and post key down with Command modifier
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }

        usleep(50000)  // 50ms delay

        // Create and post key up with Command modifier
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Clipboard Management

    private static func saveClipboard() -> [(NSPasteboard.PasteboardType, Data)] {
        let pasteboard = NSPasteboard.general
        var saved: [(NSPasteboard.PasteboardType, Data)] = []

        guard let items = pasteboard.pasteboardItems else { return saved }

        for item in items {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.append((type, data))
                }
            }
        }

        return saved
    }

    private static func restoreClipboard(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        guard !items.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        for (type, data) in items {
            item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
        syncClipboardManager()
    }

    // MARK: - Clipboard History Integration
    //
    // The dictation paste path writes to `NSPasteboard.general` twice: the transcription, then
    // — when `preserveClipboard` is on — the original clipboard is restored a couple seconds
    // later. We want the transcription itself to LAND in clipboard history (so it can be
    // re-pasted), but the restore write must not churn history.
    //
    // So the two writes are handled differently:
    //  - transcription write -> `recordDictationInHistory(_:)`: explicitly ingest the text as a
    //    history entry, then resync the poll baseline so the automatic 0.5s poll does not also
    //    capture it (which would be a redundant front-dup);
    //  - restore write -> `syncClipboardManager()`: only resync the baseline, so restoring the
    //    original clipboard does not add or reorder history.
    //
    // `CursorPaster` is a plain `static` API that may be entered from a non-main-actor context
    // (though in practice both call sites above run on the main thread), so reaching the
    // `@MainActor`-isolated manager has to be done safely:
    //  - if already on the main thread, hop onto the main actor synchronously via
    //    `MainActor.assumeIsolated` so the work completes before the function returns (and well
    //    before the next poll tick can fire in between);
    //  - otherwise, fall back to an async hop — still prompt, just without the same-turn guarantee.

    /// Record dictated text as a clipboard-history entry (respecting the enable toggle), then
    /// resync the poll baseline so automatic capture does not double-add it.
    private static func recordDictationInHistory(_ text: String) {
        onMainActor {
            guard ClipboardManager.shared.enabled else { return }
            ClipboardManager.shared.ingest(.text(text))
            ClipboardManager.shared.markPasteboardSynced()
        }
    }

    /// Resync `ClipboardManager`'s poll baseline to the current pasteboard, so a programmatic
    /// write we just made is not surfaced as a new history entry.
    private static func syncClipboardManager() {
        onMainActor {
            ClipboardManager.shared.markPasteboardSynced()
        }
    }

    private static func onMainActor(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}

// MARK: - Paste Eligibility Service

class PasteEligibilityService {

    /// Check if the currently focused element can accept pasted text
    static func canPaste() -> Bool {
        // In sandboxed mode, we can't check - assume true
        if CursorPaster.isSandboxed {
            return true
        }

        guard AXIsProcessTrusted() else {
            // If we don't have accessibility permission, assume we can paste
            // The paste will just fail silently if we can't
            return true
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return false
        }

        // Check if the value attribute is settable (i.e., it's an editable field)
        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element as! AXUIElement,
            kAXValueAttribute as CFString,
            &isSettable
        )

        return settableResult == .success && isSettable.boolValue
    }

    /// Get the currently selected text (if any)
    static func getSelectedText() -> String? {
        // In sandboxed mode, we can't access other apps' UI
        if CursorPaster.isSandboxed {
            return nil
        }

        guard AXIsProcessTrusted() else { return nil }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return nil
        }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        guard textResult == .success, let text = selectedText as? String else {
            return nil
        }

        return text.isEmpty ? nil : text
    }
}
