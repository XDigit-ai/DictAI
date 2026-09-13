import AppKit
import Carbon.HIToolbox

/// Intercepts Tab (accept) and Escape (dismiss) keystrokes while a suggestion overlay is visible.
/// Uses a CGEventTap so it can *consume* the key — Cocoa global monitors can only observe.
///
/// Not @MainActor: the CGEventTap C callback is nonisolated, so this class holds plain
/// (non-actor-isolated) state. Writes to `suggestionActive` happen from the main thread;
/// reads from the callback see them via a memory barrier on event delivery.
final class KeyInterceptor {
    var onAccept: () -> Void = {}
    var onDismiss: () -> Void = {}

    nonisolated(unsafe) var suggestionActive: Bool = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func install() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyInterceptorCallback,
            userInfo: selfPtr
        ) else {
            NSLog("[Autocomplete] Failed to create CGEventTap (Accessibility permission?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        runLoopSource = source
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private func keyInterceptorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { interceptor.reenable() }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    guard interceptor.suggestionActive else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    let hasModifier = !flags.intersection(modifierMask).isEmpty

    if keyCode == kVK_Tab && !hasModifier {
        DispatchQueue.main.async { interceptor.onAccept() }
        return nil
    }

    if keyCode == kVK_Escape {
        DispatchQueue.main.async { interceptor.onDismiss() }
        return nil
    }

    return Unmanaged.passUnretained(event)
}
