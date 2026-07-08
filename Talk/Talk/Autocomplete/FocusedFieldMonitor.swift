import AppKit
import ApplicationServices

struct FocusedFieldSnapshot: Equatable {
    let bundleId: String
    let textBeforeCaret: String
    let caretIndex: Int
    let totalLength: Int
    let caretRect: CGRect?
}

@MainActor
protocol FocusedFieldMonitorDelegate: AnyObject {
    func focusedFieldDidChange(_ snapshot: FocusedFieldSnapshot)
    func focusedFieldDidClear()
}

@MainActor
final class FocusedFieldMonitor {
    weak var delegate: FocusedFieldMonitorDelegate?

    private var timer: Timer?
    private var lastSnapshot: FocusedFieldSnapshot?
    private(set) var running = false

    func start() {
        guard !running else { return }
        guard AXIsProcessTrusted() else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        lastSnapshot = nil
    }

    private func tick() {
        guard let snap = readFocusedField() else {
            if lastSnapshot != nil {
                lastSnapshot = nil
                delegate?.focusedFieldDidClear()
            }
            return
        }
        if snap != lastSnapshot {
            lastSnapshot = snap
            delegate?.focusedFieldDidChange(snap)
        }
    }

    private func readFocusedField() -> FocusedFieldSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return nil }

        // Don't peek at our own UI
        if bundleId == Bundle.main.bundleIdentifier { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let axElement = element as! AXUIElement

        // Must be a settable text-bearing field
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }

        // Caret index from selected range (selection start)
        var caret = value.count
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let axRange = rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange) {
                caret = min(max(0, cfRange.location), value.count)
            }
        }

        let prefixEnd = value.index(value.startIndex, offsetBy: caret, limitedBy: value.endIndex) ?? value.endIndex
        let textBefore = String(value[..<prefixEnd])

        // Caret bounds: bounds of a 1-char range at caret-1 (or caret if at start)
        let rect = caretRect(for: axElement, at: caret)

        return FocusedFieldSnapshot(
            bundleId: bundleId,
            textBeforeCaret: textBefore,
            caretIndex: caret,
            totalLength: value.count,
            caretRect: rect
        )
    }

    private func caretRect(for element: AXUIElement, at caret: Int) -> CGRect? {
        let probeLocation = max(0, caret - 1)
        var range = CFRange(location: probeLocation, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }

        var boundsRef: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        )
        guard result == .success, let bounds = boundsRef else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
