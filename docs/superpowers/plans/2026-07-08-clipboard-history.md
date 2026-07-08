# Clipboard History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the last 20 clipboard copies in memory and let the user recall any of them through a floating picker summoned with `⌘⌥V`, pasting the chosen item into the previously focused app.

**Architecture:** A new `ClipboardManager` (Core) polls `NSPasteboard.general.changeCount` on a timer and feeds a pure `ClipboardBuffer` (ring buffer, cap 20). Recall uses a Carbon-registered `⌘⌥V` global hotkey that opens a non-activating `NSPanel` picker; selection re-writes the item's pasteboard representations and fires Cmd+V (reusing `CursorPaster`) into the still-frontmost target app.

**Tech Stack:** Swift / SwiftUI / AppKit, `Carbon.HIToolbox` (RegisterEventHotKey), `NSPasteboard`, `CGEvent`, Swift `Testing` framework.

## Global Constraints

- Target module name: **`DictAI`** (tests use `@testable import DictAI`). Test target: **`TalkTests`**. Scheme: **`DictAI`**.
- Project uses **file-system-synchronized groups** (`objectVersion 77`). New `.swift` files placed under `Talk/Talk/...` and `Talk/TalkTests/` are auto-added to their targets. Do NOT hand-edit `project.pbxproj`.
- Tests use the Swift **`Testing`** framework: `import Testing`, `@Test`, `#expect(...)`, `struct` suites (see `Talk/TalkTests/MeetingModelTests.swift`).
- Persistence: **in-memory only**. No disk, no `UserDefaults` for history contents (only the enable toggle).
- History cap: **20 items**, newest first.
- Recall shortcut: **`⌘⌥V`** (`cmdKey | optionKey`, virtual key `kVK_ANSI_V` = `0x09`). Fixed, not user-configurable in v1.
- Follow existing patterns: `@MainActor` `ObservableObject` singletons (`HotkeyManager.shared`), `@AppStorage` for settings flags.
- Build: `cd Talk && xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build`
- Run tests: `cd Talk && xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkBuild -only-testing:TalkTests/<SuiteName>`

---

### Task 1: `ClipboardItem` model + `ClipboardBuffer` ring buffer (TDD)

Pure, AppKit-free logic. This is the only fully unit-testable unit; get it solid first.

**Files:**
- Create: `Talk/Talk/Core/ClipboardItem.swift`
- Create: `Talk/Talk/Core/ClipboardBuffer.swift`
- Test: `Talk/TalkTests/ClipboardBufferTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct ClipboardItem: Identifiable, Equatable` with `id: UUID`, `createdAt: Date`, `representations: [ClipboardItem.Rep]`, `preview: ClipboardItem.Preview`.
  - `struct ClipboardItem.Rep: Equatable { let type: NSPasteboard.PasteboardType; let data: Data }`
  - `enum ClipboardItem.Preview: Equatable { case text(String); case image(NSImage); case files([String]); case other(String) }`
  - `static func ClipboardItem.text(_ string: String, id: UUID = UUID(), createdAt: Date = Date()) -> ClipboardItem`
  - `ClipboardItem` equality compares `representations` only (ignores `id`, `createdAt`, `preview`).
  - `struct ClipboardBuffer { private(set) var items: [ClipboardItem]; let maxItems: Int; init(maxItems: Int = 20); mutating func ingest(_ item: ClipboardItem); mutating func clear() }`

- [ ] **Step 1: Write `ClipboardItem.swift`**

```swift
import AppKit

/// A single captured clipboard entry, preserving all pasteboard representations
/// so it can be re-pasted with full fidelity. In-memory only.
struct ClipboardItem: Identifiable {
    let id: UUID
    let createdAt: Date
    let representations: [Rep]
    let preview: Preview

    /// One pasteboard representation: a UTI type and its raw bytes.
    struct Rep: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    /// How a row renders in the picker. Derived, not part of identity.
    enum Preview: Equatable {
        case text(String)
        case image(NSImage)
        case files([String])
        case other(String)
    }

    /// Convenience for text-only items (used by tests and simple captures).
    static func text(_ string: String, id: UUID = UUID(), createdAt: Date = Date()) -> ClipboardItem {
        let data = Data(string.utf8)
        return ClipboardItem(
            id: id,
            createdAt: createdAt,
            representations: [Rep(type: .string, data: data)],
            preview: .text(string)
        )
    }
}

extension ClipboardItem: Equatable {
    /// Identity is the clipboard content (its representations), not id/time/preview.
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.representations == rhs.representations
    }
}
```

- [ ] **Step 2: Write the failing tests in `ClipboardBufferTests.swift`**

```swift
import Testing
import Foundation
@testable import DictAI

struct ClipboardBufferTests {

    @Test func ingestInsertsAtFront() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("first"))
        buffer.ingest(.text("second"))
        #expect(buffer.items.count == 2)
        #expect(buffer.items.first?.preview == .text("second"))
    }

    @Test func ingestCapsAtMax() {
        var buffer = ClipboardBuffer(maxItems: 20)
        for i in 0..<25 { buffer.ingest(.text("item\(i)")) }
        #expect(buffer.items.count == 20)
        #expect(buffer.items.first?.preview == .text("item24"))
        #expect(buffer.items.last?.preview == .text("item5"))
    }

    @Test func ingestDuplicateOfFrontIsNoOp() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("same"))
        buffer.ingest(.text("same"))
        #expect(buffer.items.count == 1)
    }

    @Test func ingestDuplicateDeeperMovesToFront() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("a"))
        buffer.ingest(.text("b"))
        buffer.ingest(.text("c"))
        buffer.ingest(.text("a"))   // re-copy an older item
        #expect(buffer.items.count == 3)
        #expect(buffer.items.first?.preview == .text("a"))
        #expect(buffer.items.map(\.preview) == [.text("a"), .text("c"), .text("b")])
    }

    @Test func clearEmptiesBuffer() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("a"))
        buffer.clear()
        #expect(buffer.items.isEmpty)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Talk && xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkBuild -only-testing:TalkTests/ClipboardBufferTests`
Expected: FAIL — `ClipboardBuffer` is not defined (compile error).

- [ ] **Step 4: Write `ClipboardBuffer.swift`**

```swift
import Foundation

/// Pure, in-memory ring buffer of clipboard items. Newest first, capped at `maxItems`.
/// Re-ingesting existing content moves it to the front instead of duplicating.
struct ClipboardBuffer {
    private(set) var items: [ClipboardItem] = []
    let maxItems: Int

    init(maxItems: Int = 20) {
        self.maxItems = maxItems
    }

    mutating func ingest(_ item: ClipboardItem) {
        // Re-copying the current front item is a no-op.
        if let front = items.first, front == item { return }
        // If it exists deeper in the buffer, remove it so it moves to the front.
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
    }

    mutating func clear() {
        items.removeAll()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Talk && xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkBuild -only-testing:TalkTests/ClipboardBufferTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Talk/Talk/Core/ClipboardItem.swift Talk/Talk/Core/ClipboardBuffer.swift Talk/TalkTests/ClipboardBufferTests.swift
git commit -m "feat(clipboard): add ClipboardItem model and ClipboardBuffer ring buffer with tests"
```

---

### Task 2: `ClipboardManager` — capture, polling, preview derivation

Wraps `ClipboardBuffer`, polls the pasteboard, and holds the enable toggle. Preview-derivation logic is factored into a pure static function so it stays unit-testable.

**Files:**
- Create: `Talk/Talk/Core/ClipboardManager.swift`
- Test: `Talk/TalkTests/ClipboardPreviewTests.swift`

**Interfaces:**
- Consumes: `ClipboardItem`, `ClipboardItem.Rep`, `ClipboardItem.Preview`, `ClipboardBuffer` (Task 1).
- Produces:
  - `@MainActor final class ClipboardManager: ObservableObject { static let shared: ClipboardManager }`
  - `@Published private(set) var items: [ClipboardItem]`
  - `@AppStorage("clipboardHistoryEnabled") var enabled: Bool` (default `true`)
  - `func start()`, `func stop()`, `func clear()`, `func ignoreNextChange()`
  - `func ingest(_ item: ClipboardItem)` (delegates to buffer, republishes `items`)
  - `static func derivePreview(from reps: [ClipboardItem.Rep]) -> ClipboardItem.Preview`
  - `static func capture(from pasteboard: NSPasteboard) -> ClipboardItem?`
  - Placeholder recall hooks (filled in Task 5): `func showPicker()`, `func paste(_ item: ClipboardItem)`.

- [ ] **Step 1: Write the failing preview tests in `ClipboardPreviewTests.swift`**

```swift
import Testing
import Foundation
import AppKit
@testable import DictAI

struct ClipboardPreviewTests {

    @Test func derivePreviewPrefersImage() {
        let png = NSImage(size: NSSize(width: 1, height: 1))
            .tiffRepresentation ?? Data()
        let reps = [
            ClipboardItem.Rep(type: .string, data: Data("caption".utf8)),
            ClipboardItem.Rep(type: .tiff, data: png)
        ]
        if case .image = ClipboardManager.derivePreview(from: reps) {
            // ok
        } else {
            Issue.record("expected .image preview")
        }
    }

    @Test func derivePreviewFilesWhenFileURL() {
        let url = URL(fileURLWithPath: "/tmp/hello.txt")
        let reps = [ClipboardItem.Rep(type: .fileURL, data: url.dataRepresentation)]
        #expect(ClipboardManager.derivePreview(from: reps) == .files(["hello.txt"]))
    }

    @Test func derivePreviewTextWhenString() {
        let reps = [ClipboardItem.Rep(type: .string, data: Data("hello world".utf8))]
        #expect(ClipboardManager.derivePreview(from: reps) == .text("hello world"))
    }

    @Test func derivePreviewOtherWhenUnknown() {
        let reps = [ClipboardItem.Rep(type: NSPasteboard.PasteboardType("com.foo.bar"), data: Data([0x1]))]
        #expect(ClipboardManager.derivePreview(from: reps) == .other("com.foo.bar"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Talk && xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkBuild -only-testing:TalkTests/ClipboardPreviewTests`
Expected: FAIL — `ClipboardManager` not defined.

- [ ] **Step 3: Write `ClipboardManager.swift`**

```swift
import AppKit
import SwiftUI

/// Owns clipboard capture (polling) and the in-memory history buffer.
/// Recall (showPicker/paste) is wired in a later task.
@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []
    @AppStorage("clipboardHistoryEnabled") var enabled: Bool = true

    private var buffer = ClipboardBuffer(maxItems: 20)
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    /// When set, the poll skips capturing this changeCount (our own paste-back).
    private var suppressedChangeCount: Int?

    /// App that was frontmost when the picker opened; paste target. Set in Task 5.
    var targetApp: NSRunningApplication?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard enabled, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Capture

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        if suppressedChangeCount == current {
            suppressedChangeCount = nil
            return
        }
        if let item = ClipboardManager.capture(from: pb) {
            ingest(item)
        }
    }

    /// Call before writing to the pasteboard ourselves so the next poll ignores it.
    func ignoreNextChange() {
        suppressedChangeCount = NSPasteboard.general.changeCount + 1
    }

    func ingest(_ item: ClipboardItem) {
        buffer.ingest(item)
        items = buffer.items
    }

    func clear() {
        buffer.clear()
        items = buffer.items
    }

    // MARK: - Pure helpers (unit-tested)

    /// Snapshot the first pasteboard item's representations into a ClipboardItem.
    static func capture(from pasteboard: NSPasteboard) -> ClipboardItem? {
        guard let pbItem = pasteboard.pasteboardItems?.first else { return nil }
        var reps: [ClipboardItem.Rep] = []
        for type in pbItem.types {
            if let data = pbItem.data(forType: type) {
                reps.append(ClipboardItem.Rep(type: type, data: data))
            }
        }
        guard !reps.isEmpty else { return nil }
        return ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            representations: reps,
            preview: derivePreview(from: reps)
        )
    }

    /// Choose how a captured item renders, by type priority: image > files > text > other.
    static func derivePreview(from reps: [ClipboardItem.Rep]) -> ClipboardItem.Preview {
        // Image
        if let imageRep = reps.first(where: { $0.type == .tiff || $0.type == .png }),
           let image = NSImage(data: imageRep.data) {
            return .image(image)
        }
        // Files
        let fileReps = reps.filter { $0.type == .fileURL }
        if !fileReps.isEmpty {
            let names = fileReps.compactMap { rep -> String? in
                guard let url = URL(dataRepresentation: rep.data, relativeTo: nil) else { return nil }
                return url.lastPathComponent
            }
            if !names.isEmpty { return .files(names) }
        }
        // Text
        if let stringRep = reps.first(where: { $0.type == .string }),
           let string = String(data: stringRep.data, encoding: .utf8) {
            return .text(string)
        }
        // Fallback
        return .other(reps.first?.type.rawValue ?? "unknown")
    }

    // MARK: - Recall (implemented in Task 5)

    func showPicker() { /* wired in Task 5 */ }
    func paste(_ item: ClipboardItem) { /* wired in Task 5 */ }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Talk && xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkBuild -only-testing:TalkTests/ClipboardPreviewTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Build the whole app to confirm no integration breakage**

Run: `cd Talk && xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Talk/Talk/Core/ClipboardManager.swift Talk/TalkTests/ClipboardPreviewTests.swift
git commit -m "feat(clipboard): add ClipboardManager with polling capture and preview derivation"
```

---

### Task 3: Extract reusable Cmd+V primitive in `CursorPaster`

Expose the existing private `simulatePaste()` as a public static method so the clipboard picker can paste without touching the clipboard-save/restore logic.

**Files:**
- Modify: `Talk/Talk/Core/CursorPaster.swift` (rename `private static func simulatePaste()` at line 77 to a public primitive and call it from the existing path)

**Interfaces:**
- Consumes: nothing new.
- Produces: `static func CursorPaster.pasteViaCmdV()` — simulates ⌘V into the frontmost app; no-op (with log) when Accessibility is not trusted.

- [ ] **Step 1: Rename and expose the method**

In `Talk/Talk/Core/CursorPaster.swift`, change the declaration at line 77 from:

```swift
    private static func simulatePaste() {
```

to:

```swift
    /// Simulate ⌘V into the frontmost application. Requires Accessibility.
    static func pasteViaCmdV() {
```

- [ ] **Step 2: Update the internal call site**

In the same file, inside `paste(_:preserveClipboard:)`, change the call (currently `simulatePaste()` around line 42) to:

```swift
        // Simulate Cmd+V
        pasteViaCmdV()
```

- [ ] **Step 3: Build to confirm parity**

Run: `cd Talk && xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manually verify dictation paste still works**

Run the app (`open /tmp/TalkBuild/Build/Products/Debug/DictAI.app`), dictate into a text field, confirm the transcription still auto-pastes. (Behavior must be unchanged — this is a pure rename.)

- [ ] **Step 5: Commit**

```bash
git add Talk/Talk/Core/CursorPaster.swift
git commit -m "refactor(paste): expose CursorPaster.pasteViaCmdV() primitive"
```

---

### Task 4: Register `⌘⌥V` global hotkey in `HotkeyManager`

Add a Carbon `RegisterEventHotKey` path so the recall combo is actually consumed system-wide (an `NSEvent` global monitor cannot consume keys, and `⌘⇧V` is taken by Paste-and-Match-Style).

**Files:**
- Modify: `Talk/Talk/Hotkey/HotkeyManager.swift` (add hotkey registration; call from `setup()` line 77 and `cleanup()` line 81)

**Interfaces:**
- Consumes: nothing new (uses `Carbon.HIToolbox`, already imported at line 3).
- Produces: `var HotkeyManager.onClipboardRecall: (() -> Void)?` — invoked on `⌘⌥V` press.

- [ ] **Step 1: Add stored properties for the hotkey**

In `HotkeyManager` (near the other `private var ...Monitor` properties, around line 27), add:

```swift
    /// Called when the clipboard-recall hotkey (⌘⌥V) is pressed.
    var onClipboardRecall: (() -> Void)?

    private var clipboardHotKeyRef: EventHotKeyRef?
    private var clipboardEventHandler: EventHandlerRef?
```

- [ ] **Step 2: Add registration/unregistration methods**

Add these methods to `HotkeyManager` (e.g. after `cleanup()`):

```swift
    // MARK: - Clipboard Recall Hotkey (⌘⌥V)

    private func registerClipboardHotkey() {
        // Install a handler for hot-key-pressed events, then register ⌘⌥V.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
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

        let hotKeyID = EventHotKeyID(signature: OSType(0x44494354 /* 'DICT' */), id: 1)
        let kVK_ANSI_V: UInt32 = 0x09
        let modifiers = UInt32(cmdKey | optionKey)
        RegisterEventHotKey(
            kVK_ANSI_V,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKeyRef
        )
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
```

- [ ] **Step 3: Call from `setup()` and `cleanup()`**

In `setup()` (line 77-79), add after `setupFlagsMonitor()`:

```swift
    func setup() {
        setupFlagsMonitor()
        registerClipboardHotkey()
    }
```

In `cleanup()` (line 81), add before the closing brace:

```swift
        unregisterClipboardHotkey()
```

- [ ] **Step 4: Temporarily wire a log to verify the hotkey fires**

Build the app. In `AppDelegate.applicationDidFinishLaunching` (after line 20 `HotkeyManager.shared.setup()`), temporarily add:

```swift
        HotkeyManager.shared.onClipboardRecall = { NSLog("[Clipboard] ⌘⌥V pressed") }
```

- [ ] **Step 5: Build and manually verify**

Run: `cd Talk && xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build && open /tmp/TalkBuild/Build/Products/Debug/DictAI.app`
Then press `⌘⌥V` and confirm `[Clipboard] ⌘⌥V pressed` appears in Console.app (or `log stream --predicate 'process == "DictAI"'`). Remove the temporary line from Step 4 afterward.

- [ ] **Step 6: Commit**

```bash
git add Talk/Talk/Hotkey/HotkeyManager.swift
git commit -m "feat(hotkey): register ⌘⌥V global hotkey for clipboard recall"
```

---

### Task 5: Picker panel + recall/paste orchestration

Build the non-activating `NSPanel` picker and implement `showPicker()` / `paste(_:)` on `ClipboardManager`.

**Files:**
- Create: `Talk/Talk/Views/ClipboardHistoryPanel.swift` (panel + SwiftUI view + keyboard monitor)
- Modify: `Talk/Talk/Core/ClipboardManager.swift` (replace the Task 2 placeholder `showPicker()` / `paste(_:)`)

**Interfaces:**
- Consumes: `ClipboardManager.shared`, `ClipboardItem`, `CursorPaster.pasteViaCmdV()` (Task 3), `ClipboardManager.ignoreNextChange()` (Task 2).
- Produces:
  - `@MainActor final class ClipboardHistoryPanel` with `static let shared`, `func toggle(items:onPick:)`, `func hide()`.
  - Filled `ClipboardManager.showPicker()` and `ClipboardManager.paste(_ item:)`.

- [ ] **Step 1: Write `ClipboardHistoryPanel.swift`**

```swift
import AppKit
import SwiftUI

/// Floating, non-activating picker for clipboard history.
/// Non-activating so the previously focused app stays frontmost and receives the paste.
@MainActor
final class ClipboardHistoryPanel {
    static let shared = ClipboardHistoryPanel()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var onPick: ((ClipboardItem) -> Void)?
    private var items: [ClipboardItem] = []
    private var selection: Int = 0

    private init() {}

    func toggle(items: [ClipboardItem], onPick: @escaping (ClipboardItem) -> Void) {
        if panel != nil { hide(); return }
        self.items = items
        self.onPick = onPick
        self.selection = 0
        show()
    }

    private func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = ClipboardHistoryView(
            items: items,
            selection: Binding(get: { [weak self] in self?.selection ?? 0 },
                               set: { [weak self] in self?.selection = $0 }),
            onPick: { [weak self] item in self?.pick(item) }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        panel.orderFrontRegardless()

        installKeyMonitor()
        self.panel = panel
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: // down arrow
                self.move(1); return nil
            case 126: // up arrow
                self.move(-1); return nil
            case 36, 76: // return / enter
                self.confirm(); return nil
            case 53: // escape
                self.hide(); return nil
            default:
                // number keys 1–9 jump to that item
                if let chars = event.charactersIgnoringModifiers,
                   let digit = Int(chars), (1...9).contains(digit),
                   digit <= self.items.count {
                    self.selection = digit - 1
                    self.confirm()
                    return nil
                }
                return event
            }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
        // Rebuild content so SwiftUI reflects the new selection.
        if let panel, let hosting = panel.contentView as? NSHostingView<ClipboardHistoryView> {
            hosting.rootView = ClipboardHistoryView(
                items: items,
                selection: Binding(get: { [weak self] in self?.selection ?? 0 },
                                   set: { [weak self] in self?.selection = $0 }),
                onPick: { [weak self] item in self?.pick(item) }
            )
        }
    }

    private func confirm() {
        guard items.indices.contains(selection) else { hide(); return }
        pick(items[selection])
    }

    private func pick(_ item: ClipboardItem) {
        hide()
        onPick?(item)
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The list UI hosted inside the panel.
struct ClipboardHistoryView: View {
    let items: [ClipboardItem]
    @Binding var selection: Int
    let onPick: (ClipboardItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clipboard History")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if items.isEmpty {
                Text("No clipboard history yet")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(index: index, item: item)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Divider()
            Text("↑↓ select   ⏎ paste   1–9 quick   esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 420, height: 360, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(index: Int, item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            } else {
                Spacer().frame(width: 16)
            }
            previewLabel(item.preview)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onPick(item) }
    }

    @ViewBuilder
    private func previewLabel(_ preview: ClipboardItem.Preview) -> some View {
        switch preview {
        case .text(let string):
            Text(string.trimmingCharacters(in: .whitespacesAndNewlines))
                .lineLimit(1)
        case .image(let image):
            HStack(spacing: 6) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
                Text("Image").foregroundStyle(.secondary)
            }
        case .files(let names):
            Label(names.joined(separator: ", "), systemImage: "doc").lineLimit(1)
        case .other(let type):
            Label(type, systemImage: "questionmark.square.dashed")
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
```

- [ ] **Step 2: Implement `showPicker()` and `paste(_:)` in `ClipboardManager`**

Replace the two placeholder methods at the bottom of `ClipboardManager.swift` (from Task 2) with:

```swift
    // MARK: - Recall

    func showPicker() {
        targetApp = NSWorkspace.shared.frontmostApplication
        ClipboardHistoryPanel.shared.toggle(items: items) { [weak self] item in
            self?.paste(item)
        }
    }

    func paste(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        ignoreNextChange()
        pb.clearContents()
        let pbItem = NSPasteboardItem()
        for rep in item.representations {
            pbItem.setData(rep.data, forType: rep.type)
        }
        pb.writeObjects([pbItem])
        // Small delay so the pasteboard is ready before the synthetic ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CursorPaster.pasteViaCmdV()
        }
    }
```

- [ ] **Step 3: Build**

Run: `cd Talk && xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit (wiring to launch happens in Task 6)**

```bash
git add Talk/Talk/Views/ClipboardHistoryPanel.swift Talk/Talk/Core/ClipboardManager.swift
git commit -m "feat(clipboard): add non-activating picker panel and paste-back"
```

---

### Task 6: Lifecycle wiring — start manager, connect hotkey, end-to-end

Start capture on launch, connect the `⌘⌥V` callback to `showPicker()`, and stop on terminate.

**Files:**
- Modify: `Talk/Talk/AppDelegate.swift` (`applicationDidFinishLaunching` after line 20; `applicationWillTerminate` after line 49)

**Interfaces:**
- Consumes: `ClipboardManager.shared` (Tasks 2/5), `HotkeyManager.shared.onClipboardRecall` (Task 4).
- Produces: nothing (wiring only).

- [ ] **Step 1: Wire in `applicationDidFinishLaunching`**

In `Talk/Talk/AppDelegate.swift`, after `HotkeyManager.shared.setup()` (line 20), add:

```swift
        // Clipboard history: start capture and connect the recall hotkey.
        ClipboardManager.shared.start()
        HotkeyManager.shared.onClipboardRecall = {
            ClipboardManager.shared.showPicker()
        }
```

- [ ] **Step 2: Wire in `applicationWillTerminate`**

After `HotkeyManager.shared.cleanup()` (line 49), add:

```swift
        ClipboardManager.shared.stop()
```

- [ ] **Step 3: Build and run**

Run: `cd Talk && pkill -9 DictAI 2>/dev/null; xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build && open /tmp/TalkBuild/Build/Products/Debug/DictAI.app`
Expected: `BUILD SUCCEEDED`, app launches.

- [ ] **Step 4: Manual end-to-end verification**

1. Copy three different text snippets from any app.
2. Click into a text field in another app (e.g. TextEdit).
3. Press `⌘⌥V` — the picker appears; TextEdit stays frontmost.
4. Press `↓` to select the 2nd item, press `⏎`.
5. Confirm the 2nd snippet is pasted into TextEdit, and the picker closed.
6. Press `⌘⌥V` again, press `2` — confirm it pastes item 2 immediately.
7. Press `⌘⌥V`, then `Esc` — confirm it closes with no paste.

(Accessibility permission must be granted for the paste; grant it if prompted.)

- [ ] **Step 5: Commit**

```bash
git add Talk/Talk/AppDelegate.swift
git commit -m "feat(clipboard): start capture on launch and wire ⌘⌥V to picker"
```

---

### Task 7: Settings toggle + menu bar actions

Expose the enable toggle, the shortcut hint, and Clear actions in the UI.

**Files:**
- Modify: `Talk/Talk/Views/SettingsView.swift` (add a new tab in the `TabView` at lines 6-46; add the tab view struct near the other `*SettingsTab` structs)
- Modify: `Talk/Talk/MenuBar/MenuBarView.swift` (add items in `body` / `actionsSection`)

**Interfaces:**
- Consumes: `ClipboardManager.shared` (Tasks 2/5).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Add the Settings tab entry**

In `SettingsView.swift`, inside the `TabView` (after the `MeetingSettingsTab()` block ending at line 40, before `PermissionsSettingsTab()`), add:

```swift
            ClipboardSettingsTab()
                .tabItem {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                }
```

- [ ] **Step 2: Add the tab view struct**

At the end of `SettingsView.swift` (after the last `*SettingsTab` struct), add:

```swift
// MARK: - Clipboard Settings

struct ClipboardSettingsTab: View {
    @ObservedObject private var clipboard = ClipboardManager.shared

    var body: some View {
        Form {
            Section("Clipboard History") {
                Toggle("Enable clipboard history", isOn: Binding(
                    get: { clipboard.enabled },
                    set: { newValue in
                        clipboard.enabled = newValue
                        if newValue { clipboard.start() } else { clipboard.stop() }
                    }
                ))
                LabeledContent("Recall shortcut", value: "⌘⌥V")
                Text("Keeps the last 20 clipboard items in memory. Press ⌘⌥V to open the picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear History") {
                    clipboard.clear()
                }
                Text("\(clipboard.items.count) item(s) stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

- [ ] **Step 3: Add menu bar actions**

In `MenuBarView.swift`, inside `body`, add a clipboard block after the `actionsSection` call (line 37, before the closing `}` of the `VStack` at line 38):

```swift
            Divider()
                .padding(.vertical, 8)

            Button {
                ClipboardManager.shared.showPicker()
            } label: {
                Label("Clipboard History", systemImage: "doc.on.clipboard")
            }

            Button {
                ClipboardManager.shared.clear()
            } label: {
                Label("Clear Clipboard History", systemImage: "trash")
            }
```

- [ ] **Step 4: Build and verify UI**

Run: `cd Talk && pkill -9 DictAI 2>/dev/null; xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build && open /tmp/TalkBuild/Build/Products/Debug/DictAI.app`
Then:
1. Open Settings → Clipboard tab. Toggle off then on; confirm no crash.
2. Confirm "Recall shortcut ⌘⌥V" is shown and the item count updates after copying.
3. Open the menu bar menu; click "Clipboard History" → picker opens.
4. Click "Clear Clipboard History"; reopen picker → empty state shown.

- [ ] **Step 5: Commit**

```bash
git add Talk/Talk/Views/SettingsView.swift Talk/Talk/MenuBar/MenuBarView.swift
git commit -m "feat(clipboard): add settings toggle and menu bar actions"
```

---

## Self-Review Notes

- **Spec coverage:** capture/polling (Task 2), 20-item in-memory ring buffer (Task 1), all-representation fidelity (Tasks 1–2, `Rep`), `⌘⌥V` recall via Carbon (Task 4), non-activating panel + keyboard nav (Task 5), paste-back reusing `CursorPaster` (Tasks 3, 5), self-paste guard `ignoreNextChange()` (Tasks 2, 5), Settings toggle + Clear + menu items (Task 7), lifecycle wiring (Task 6), `ingest` unit tests (Task 1), preview-derivation tests (Task 2). All spec sections mapped.
- **YAGNI honored:** no disk persistence, no search, no pinning, no secret-skipping, fixed shortcut — none appear in tasks.
- **Type consistency:** `ClipboardItem`, `ClipboardItem.Rep`, `ClipboardItem.Preview`, `ClipboardBuffer.ingest`, `ClipboardManager.derivePreview/capture/ingest/ignoreNextChange/showPicker/paste`, `CursorPaster.pasteViaCmdV`, `HotkeyManager.onClipboardRecall`, `ClipboardHistoryPanel.toggle/hide` are used identically across tasks.
- **Known follow-ups (not in v1):** near-cursor panel positioning; configurable shortcut; concealed-content skipping.
