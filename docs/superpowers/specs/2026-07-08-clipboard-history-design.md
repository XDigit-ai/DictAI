# Clipboard History — Design

**Date:** 2026-07-08
**App:** DictAI (macOS menu bar dictation app)
**Status:** Approved design, ready for implementation planning

## Summary

Add a clipboard history feature to DictAI. The app keeps the last 20 clipboard entries in
memory and lets the user recall any of them through a floating picker summoned with a global
shortcut (`⌘⌥V`). Selecting an item pastes it into whatever app was focused when the picker
opened.

## Goals

- Capture the last 20 clipboard copies automatically, preserving all pasteboard representations
  (text, images, files, arbitrary data).
- Recall any past item via a keyboard-driven floating picker (`⌘⌥V`).
- Paste the chosen item into the previously focused application with full fidelity.
- Provide a "Clear History" action and an enable/disable toggle.

## Non-Goals (v1 scope guardrails / YAGNI)

- No disk persistence. History is in-memory only and is cleared on quit.
- No type-to-search / filtering in the picker.
- No pinning, favorites, or per-item deletion.
- No configurable shortcut UI. The recall shortcut is fixed at `⌘⌥V` for v1.
- No skipping of concealed/secret pasteboard content. Everything copied is captured (in memory).
- Multi-item copies (e.g. selecting several files at once) capture only the first
  `NSPasteboardItem`.

## Architecture

Follows the app's existing "manager + state + view" layering. Three new units plus small
extensions to existing code.

```
Core/ClipboardManager.swift        (new) — capture, ring buffer, recall orchestration
Views/ClipboardHistoryPanel.swift  (new) — non-activating NSPanel + SwiftUI picker
Core/CursorPaster.swift            (edit) — expose a public paste primitive
Hotkey/HotkeyManager.swift         (edit) — register the ⌘⌥V global hotkey
Views/SettingsView.swift           (edit) — enable toggle, shortcut label, Clear button
MenuBar/MenuBarView.swift          (edit) — "Clipboard History" + "Clear" menu items
AppDelegate.swift / setup path     (edit) — start manager + register hotkey on launch
TalkTests/ClipboardManagerTests.swift (new) — ring-buffer unit tests
```

### Three sub-problems

1. **Capture** — poll `NSPasteboard.general.changeCount` on a timer (~0.5s), snapshot new
   content into an in-memory ring buffer of 20.
2. **Recall UI** — a floating, non-activating picker driven by `⌘⌥V`, keyboard-navigable.
3. **Paste-back** — write the chosen item's representations back to the pasteboard and fire
   Cmd+V into the app that was focused before the picker opened.

## Components

### 1. `ClipboardItem` (data model)

In-memory value type capturing all pasteboard representations for full-fidelity re-paste.

```swift
struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    let preview: Preview

    enum Preview: Equatable {
        case text(String)      // trimmed, first line shown in the row
        case image(NSImage)    // thumbnail
        case files([String])   // file names
        case other(String)     // e.g. "Data (com.foo.bar)"
    }
}
```

- `preview` is derived by priority: image type → `.image`; file-URL type → `.files`; string
  type → `.text`; otherwise `.other(typeDescription)`.
- `Equatable` compares representation types + data (used for dedup). `NSImage` in the preview is
  derived, not compared directly; equality is based on `representations`.

### 2. `ClipboardManager` (Core, new)

`@MainActor` `ObservableObject` singleton (mirrors `HotkeyManager.shared`).

State:
- `@Published private(set) var items: [ClipboardItem]` — ring buffer, newest first, capped at 20.
- `@AppStorage("clipboardHistoryEnabled") var enabled: Bool = true`.
- `private var lastChangeCount: Int`, `private var timer: Timer?`,
  `private var ignoreChangeCount: Int?` (self-paste guard).
- `private var targetApp: NSRunningApplication?` — captured when the picker opens.

Behavior:
- `start()` / `stop()` — begin/end polling; `start()` is a no-op when `enabled == false`.
- Poll tick: if `changeCount` differs from `lastChangeCount`, and it is not the suppressed
  self-paste change, build a `ClipboardItem` from the first `NSPasteboardItem` and call
  `ingest(_:)`.
- `func ingest(_ item: ClipboardItem)` — **pure, testable core**:
  - If `item` equals the current front item, do nothing (no-op).
  - If `item` equals an existing item deeper in the buffer, move it to the front.
  - Otherwise insert at front; if count > 20, drop the oldest.
- `func ignoreNextChange()` — records the current/next `changeCount` so the next poll skips
  capturing our own paste-back (and the transcription auto-paste path calls this too).
- `func clear()` — empties the buffer.
- Recall orchestration: `showPicker()` captures `NSWorkspace.shared.frontmostApplication` into
  `targetApp`, then presents `ClipboardHistoryPanel`. `paste(_ item:)` writes representations to
  the pasteboard, calls `ignoreNextChange()`, and invokes the `CursorPaster` paste primitive.

### 3. Global shortcut — `HotkeyManager` extension

`⌘⇧V` is system-wide "Paste and Match Style" and an `NSEvent` global monitor cannot consume
keys, so the recall shortcut uses Carbon **`RegisterEventHotKey`** (the `Carbon.HIToolbox`
module is already imported) to actually capture the combo. Default combo: **`⌘⌥V`**
(`cmdKey | optionKey`, virtual key `kVK_ANSI_V` = `0x09`).

- Add a registered-hotkey path to `HotkeyManager` alongside the existing `.flagsChanged`
  monitor: install an event handler for `kEventClassKeyboard` / `kEventHotKeyPressed`, register
  the `⌘⌥V` hotkey in `setup()`, and unregister in `cleanup()`.
- On press, invoke a callback `var onClipboardRecall: (() -> Void)?`, wired by the app to
  `ClipboardManager.shared.showPicker()`.

### 4. `ClipboardHistoryPanel` (Views, new)

- `NSPanel` subclass with **`.nonactivatingPanel`** in its style mask. This is the critical
  detail: the panel receives key events while DictAI does **not** become the active app, so
  `NSWorkspace.frontmostApplication` remains the target app and the eventual Cmd+V lands there.
  Floating window level; centered on the active screen (near-cursor positioning is a later
  refinement).
- Hosts a SwiftUI `ClipboardHistoryView` via `NSHostingView`. Each row shows an index badge
  (1–9 for the first nine), and a preview rendered per `Preview` case (text line, image
  thumbnail, file names, or type description).
- **Keyboard handling via a local `.keyDown` monitor installed while the panel is open** (robust
  inside a non-activating panel, avoids SwiftUI first-responder problems):
  - `↑` / `↓` move the selection.
  - `1`–`9` jump to and select that item.
  - `Return` confirms → paste.
  - `Esc` or resign-key (click elsewhere) dismisses without pasting.

### 5. Paste-back — `CursorPaster` extension

- Extract the existing private `simulatePaste()` (Cmd+V via `CGEvent`) into a reusable
  `static func pasteViaCmdV()` public primitive.
- `ClipboardManager.paste(_ item:)` writes all `representations` into a single
  `NSPasteboardItem` on `NSPasteboard.general`, calls `ignoreNextChange()`, then calls
  `CursorPaster.pasteViaCmdV()`. Because the panel is non-activating, the target app is still
  frontmost and receives the paste.

### 6. Settings + menu bar

- `SettingsView`: new "Clipboard History" section with an "Enable Clipboard History" toggle
  (bound to the `@AppStorage` flag), a static label showing the `⌘⌥V` shortcut, and a
  "Clear History" button calling `ClipboardManager.shared.clear()`.
- `MenuBarView`: a "Clipboard History" item that calls `showPicker()`, and a
  "Clear Clipboard History" item that calls `clear()`.

## Data Flow

```
Copy in any app
  → poll tick detects changeCount change
  → ClipboardManager.ingest(item)  → items ring buffer (max 20)

⌘⌥V pressed
  → HotkeyManager registered-hotkey handler → onClipboardRecall()
  → ClipboardManager.showPicker(): capture frontmostApplication, show panel

Panel open (non-activating; target app stays frontmost)
  → local keyDown monitor: ↑/↓/1–9 select, Return confirm, Esc dismiss
  → on Return: hide panel
      → ClipboardManager.paste(item): write representations, ignoreNextChange()
      → CursorPaster.pasteViaCmdV() → Cmd+V into target app
```

## Error Handling & Edge Cases

- **Self-paste loop:** `ignoreNextChange()` prevents the paste-back (and the existing
  transcription auto-paste) from re-entering history.
- **Accessibility not granted:** Cmd+V simulation requires Accessibility (same as existing
  paste). If not trusted, fall back to leaving the item on the clipboard (reuse existing
  `CursorPaster` sandbox/permission handling) and notify, consistent with current behavior.
- **Empty history:** the picker shows an empty-state row; `⌘⌥V` still opens it.
- **Disabled feature:** when the toggle is off, `start()` does not poll and the hotkey handler
  is a no-op (or the hotkey is not registered). Toggling on starts polling.
- **Large/binary data:** captured as raw `Data` in memory; preview falls back to
  `.other(type)`. Bounded by the 20-item cap.

## Testing

- New `TalkTests/ClipboardManagerTests.swift` targeting the pure `ingest(_:)` core:
  - inserting new items pushes to front,
  - buffer caps at 20 (oldest dropped),
  - ingesting a duplicate of the front item is a no-op,
  - ingesting a duplicate deeper in the buffer moves it to the front,
  - `clear()` empties the buffer.
- `NSPasteboard` polling and the AppKit panel are not unit-tested (AppKit/AX side effects);
  they are validated manually. The design isolates all testable logic into `ingest`.

## Implementation Order (high level)

1. `ClipboardItem` + `ClipboardManager` (with `ingest`) and unit tests.
2. `CursorPaster.pasteViaCmdV()` extraction.
3. `HotkeyManager` `⌘⌥V` registration + callback.
4. `ClipboardHistoryPanel` + `ClipboardHistoryView` + keyboard monitor.
5. Wire `showPicker` / `paste` end to end.
6. Settings + menu bar UI.
7. Lifecycle wiring in the app setup path.
