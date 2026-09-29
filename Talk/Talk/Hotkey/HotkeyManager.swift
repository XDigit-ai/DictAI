import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine

@MainActor
class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    // Settings - Two hotkeys: Simple dictation and Agent (voice-to-action)
    @Published var simpleHotkey: HotkeyType {
        didSet {
            UserDefaults.standard.set(simpleHotkey.rawValue, forKey: "simpleHotkey")
        }
    }

    @Published var agentHotkey: HotkeyType {
        didSet {
            UserDefaults.standard.set(agentHotkey.rawValue, forKey: "agentHotkey")
        }
    }

    // State
    @Published var isHotkeyPressed = false
    @Published var activeHotkeyMode: ProcessingMode? = nil  // Which mode's hotkey is currently pressed

    private var eventMonitor: Any?
    private var flagsMonitor: Any?
    private var isRecording = false
    private var keyDownTime: Date?
    private var recordingMode: ProcessingMode? = nil  // Mode for current recording session
    private var cancellables = Set<AnyCancellable>()

    /// Called when the clipboard-recall hotkey (⌘⌥V) is pressed.
    var onClipboardRecall: (() -> Void)?

    private var clipboardHotKeyRef: EventHotKeyRef?
    private var clipboardEventHandler: EventHandlerRef?

    private init() {
        // Initialize from UserDefaults
        if let savedValue = UserDefaults.standard.string(forKey: "simpleHotkey"),
           let hotkey = HotkeyType(rawValue: savedValue) {
            self.simpleHotkey = hotkey
        } else {
            self.simpleHotkey = .rightCommand
        }

        if let savedValue = UserDefaults.standard.string(forKey: "agentHotkey"),
           let hotkey = HotkeyType(rawValue: savedValue) {
            self.agentHotkey = hotkey
        } else {
            // Default: Right Option for agent mode
            self.agentHotkey = .rightOption
            UserDefaults.standard.set(HotkeyType.rightOption.rawValue, forKey: "agentHotkey")
        }
        // Clean up legacy key
        UserDefaults.standard.removeObject(forKey: "advancedHotkey")

        NSLog("[HotkeyManager] init: simpleHotkey=\(self.simpleHotkey.rawValue) agentHotkey=\(self.agentHotkey.rawValue)")

        // Observe UserDefaults changes for sync across instances
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if let savedValue = UserDefaults.standard.string(forKey: "simpleHotkey"),
                   let hotkey = HotkeyType(rawValue: savedValue),
                   hotkey != self.simpleHotkey {
                    self.simpleHotkey = hotkey
                }
                if let savedValue = UserDefaults.standard.string(forKey: "agentHotkey"),
                   let hotkey = HotkeyType(rawValue: savedValue),
                   hotkey != self.agentHotkey {
                    self.agentHotkey = hotkey
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    func setup() {
        setupFlagsMonitor()
        registerClipboardHotkey()
    }

    func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        unregisterClipboardHotkey()
    }

    // MARK: - Clipboard Recall Hotkey (⌘⌥V)

    private func registerClipboardHotkey() {
        // Install a handler for hot-key-pressed events, then register ⌘⌥V.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in manager.onClipboardRecall?() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &clipboardEventHandler
        )
        if installStatus != noErr {
            NSLog("[HotkeyManager] InstallEventHandler for clipboard-recall hotkey failed: OSStatus=\(installStatus)")
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x44494354 /* 'DICT' */), id: 1)
        let kVK_ANSI_V: UInt32 = 0x09
        let modifiers = UInt32(cmdKey | optionKey)
        let registerStatus = RegisterEventHotKey(
            kVK_ANSI_V,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKeyRef
        )
        if registerStatus != noErr {
            NSLog("[HotkeyManager] RegisterEventHotKey for ⌘⌥V (clipboard recall) failed: OSStatus=\(registerStatus). The combo may already be claimed by another app.")
        }
    }

    private func unregisterClipboardHotkey() {
        if let ref = clipboardHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardHotKeyRef = nil
        }
        if let handler = clipboardEventHandler {
            RemoveEventHandler(handler)
            clipboardEventHandler = nil
        }
    }

    // MARK: - Modifier Key Monitoring

    private func setupFlagsMonitor() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let keyCode = event.keyCode

        // Check both hotkeys
        let simplePressed = isHotkeyActive(hotkey: simpleHotkey, flags: flags, keyCode: keyCode)
        let agentPressed = isHotkeyActive(hotkey: agentHotkey, flags: flags, keyCode: keyCode)

        // Debug: log every flag change to file
        debugLogHotkey("keyCode=\(keyCode) simple=\(simplePressed) agent=\(agentPressed) simpleHK=\(simpleHotkey.rawValue) agentHK=\(agentHotkey.rawValue) flags=\(flags.rawValue)")

        // Determine which mode's hotkey is active (simple takes priority, then agent)
        let newMode: ProcessingMode? = simplePressed ? .simple : (agentPressed ? .agent : nil)
        let isPressed = newMode != nil

        if isPressed != isHotkeyPressed || (isPressed && newMode != activeHotkeyMode) {
            let wasPressed = isHotkeyPressed
            isHotkeyPressed = isPressed
            activeHotkeyMode = newMode

            if isPressed && !wasPressed {
                handleHotkeyDown(mode: newMode!)
            } else if !isPressed && wasPressed {
                handleHotkeyUp()
            }
        }
    }

    private func isHotkeyActive(hotkey: HotkeyType, flags: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        switch hotkey {
        case .rightCommand:
            return keyCode == kVK_RightCommand && flags.contains(.command)
        case .leftCommand:
            return keyCode == kVK_Command && flags.contains(.command)
        case .rightOption:
            return keyCode == kVK_RightOption && flags.contains(.option)
        case .leftOption:
            return keyCode == kVK_Option && flags.contains(.option)
        case .rightControl:
            return keyCode == kVK_RightControl && flags.contains(.control)
        case .leftControl:
            return keyCode == kVK_Control && flags.contains(.control)
        case .fn:
            return flags.contains(.function)
        case .capsLock:
            return keyCode == kVK_CapsLock
        }
    }

    // MARK: - Hotkey Actions

    private func handleHotkeyDown(mode: ProcessingMode) {
        keyDownTime = Date()
        recordingMode = mode

        switch AppState.shared.recordingMode {
        case .pushToTalk:
            // Start recording immediately with the specified processing mode
            startRecording(processingMode: mode)
        case .toggle:
            // Do nothing on down - wait for up
            break
        }
    }

    private func handleHotkeyUp() {
        switch AppState.shared.recordingMode {
        case .pushToTalk:
            // Stop recording on release
            if isRecording {
                stopRecording()
            }
        case .toggle:
            // Toggle recording on release (after short press)
            if let downTime = keyDownTime,
               Date().timeIntervalSince(downTime) < 0.5 {
                // Short press - toggle
                if isRecording {
                    stopRecording()
                } else if let mode = recordingMode {
                    startRecording(processingMode: mode)
                }
            }
        }

        keyDownTime = nil
    }

    private func startRecording(processingMode: ProcessingMode) {
        guard !isRecording else { return }

        // Safety: if previous processing is stuck, force-clear state so new recording can start
        if AppState.shared.isProcessing {
            NSLog("[HotkeyManager] Clearing stale processing state before new recording")
            AppState.shared.isProcessing = false
            AppState.shared.currentSessionMode = nil
        }

        isRecording = true
        AppState.shared.startRecording(withMode: processingMode)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingMode = nil
        AppState.shared.stopRecording()
    }

    // MARK: - Debug Logging

    private func debugLogHotkey(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        let path = "/tmp/dictai_hotkey.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Hotkey Types

enum HotkeyType: String, CaseIterable, Codable {
    case rightCommand = "Right ⌘"
    case leftCommand = "Left ⌘"
    case rightOption = "Right ⌥"
    case leftOption = "Left ⌥"
    case rightControl = "Right ⌃"
    case leftControl = "Left ⌃"
    case fn = "fn"
    case capsLock = "Caps Lock"

    var description: String {
        rawValue
    }
}

// MARK: - Virtual Key Codes

private let kVK_Command: UInt16 = 0x37
private let kVK_RightCommand: UInt16 = 0x36
private let kVK_Option: UInt16 = 0x3A
private let kVK_RightOption: UInt16 = 0x3D
private let kVK_Control: UInt16 = 0x3B
private let kVK_RightControl: UInt16 = 0x3E
private let kVK_CapsLock: UInt16 = 0x39
