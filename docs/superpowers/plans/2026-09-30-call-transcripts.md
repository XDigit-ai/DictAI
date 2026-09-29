# Call Transcripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Meeting feature with a lean call transcript tool that streams a cleaned, append-only Markdown transcript during calls (Apple SpeechTranscriber) and replaces it with a final Whisper transcript after the call.

**Architecture:** Two audio channels (mic = You, call app process tap = Them) are captured at 16 kHz, written to WAV files, and fed to one Apple `SpeechAnalyzer` per channel. Finalized live results are cleaned by pure rules and appended to the transcript file on one serial queue. When the call ends, `FinalPass` segments the WAVs at pauses, transcribes them with Whisper, merges both channels by time, and atomically replaces the file.

**Tech Stack:** Swift 5 mode with default MainActor isolation, SwiftUI, AVFoundation, Core Audio process taps (`CATapDescription`), Speech (`SpeechAnalyzer`, `SpeechTranscriber`), whisper.cpp via `whisper.xcframework`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-29-call-transcripts-design.md`

## Global Constraints

- Deployment target stays **macOS 26.1**. Do not change it.
- Build settings: `SWIFT_VERSION = 5.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Every type that runs off the main thread or is pure logic is declared `nonisolated` (types) so it is not MainActor isolated.
- English only: Apple locale `en-US`, Whisper `language = "en"`.
- Default transcripts folder: `~/Documents/DictAI Transcripts/`. File name: `YYYY-MM-DD HHMM <title>.md`. Live pointer: `_live.md` symlink in the same folder.
- Status values: `live`, `processing`, `final`, `ended-live-only`, written right padded with spaces to **15** characters.
- No LLM touches transcripts. Cleaning is exactly the four rules in the spec's TranscriptCleaner section.
- User facing text (UI strings, README) must not use em dashes or spaced hyphens as separators.
- New files under `Talk/Talk/` and `Talk/TalkTests/` are picked up automatically (the project uses synchronized folders). Do not edit the project file to add sources.
- Test command (this Mac has no development certificate, so tests are signed ad hoc). Replace `<Suite>` with the test struct name:

```bash
cd /Users/ak/code/DictAI/Talk && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkTest \
  -only-testing:TalkTests/<Suite> CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  2>&1 | grep -E "error:|✘|✔|Test run|TEST (SUCCEEDED|FAILED)" | tail -40
```

- Full suite: same command with `-only-testing:TalkTests`.
- Every commit message ends with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp
```

### Spec deltas decided while planning

These refine the spec; Task 12 writes them back into the spec document.

1. Header `title` and `app` values are YAML double quoted, so titles containing `:` stay valid.
2. The layout rule does not insert spaces after punctuation (it would break `3.5`, `e.g.`, `U.S.`). It only removes spaces before punctuation, collapses whitespace and capitalizes sentence starts.
3. `CallDetector` polls Core Audio once per second instead of registering property listeners.
4. The Them tap covers every Core Audio process whose bundle ID equals or starts with the call app's bundle ID plus `.` (Chrome and Teams run audio in helper processes). Safari calls are matched through `com.apple.WebKit.GPU`.
5. Audio hand off uses one serial dispatch queue per recording (the "sink") instead of a ring buffer. The sink owns the WAV writers, the live transcriber input and all transcript file writes.
6. `CallSession` has no `finalizing` phase. The final pass runs in the background, so a new call can start while the previous transcript is finishing.
7. `NSSpeechRecognitionUsageDescription` is added next to `NSAudioCaptureUsageDescription`, in case SpeechAnalyzer asks for speech recognition authorization.
8. The final pass counts as failed (status `ended-live-only`) when every utterance fails to transcribe, so a missing Whisper model never replaces live text with an empty transcript.
9. The Apple speech model is installed in the background at app launch. A call never waits for the download: a call that starts before the model is ready is recorded with `live: unavailable`. There is no install progress UI.
10. A live transcriber that fails mid call is not restarted. The error is logged and the final pass fills the gap.

## Review Focus

1. **Spoken text that looks like the header.** Someone says "Status: done" at the start of a line. `setStatus` must change only the header's status line, never the body. Pinned in Task 3.
2. **Hostile titles.** A calendar event titled `Q3: plan/review "final"` or 200 characters long. The file name must be valid and the YAML header must parse. Pinned in Task 3.
3. **System Audio Recording permission denied.** The tap starts but delivers pure silence. The final header must say `channels: you` and the menu bar must warn. Pinned in Task 10.
4. **Crash mid call.** WAV files are left with a zero data size in their headers. Recovery must still read every sample and produce a final transcript. Pinned in Tasks 5 and 10.
5. **Whisper unavailable after the call.** The model is missing or fails to load. The live text must be kept, status `ended-live-only`, and a retry offered. Pinned in Task 10.

---

## File Structure

New, in `Talk/Talk/CallTranscript/`:

| File | Responsibility |
|---|---|
| `TranscriptTypes.swift` | `Speaker`, `TranscriptStatus`, `TranscriptHeader`, `Turn`, `TimedText` |
| `TranscriptCleaner.swift` | Four cleaning rules, pure |
| `TranscriptRenderer.swift` | Markdown for header, turn headings, whole document, timestamps |
| `TranscriptFile.swift` | Create, append, set status, rewrite header, atomic replace, `_live.md` |
| `SpeechSegmenter.swift` | Offline pause based segmentation for the final pass |
| `WAVFile.swift` | `WAVWriter` (streaming, crash tolerant) and `WAVFile.readSamples` |
| `AudioBufferConverter.swift` | `AVAudioConverter` wrapper, 16 kHz mono format, buffer helpers |
| `FinalPass.swift` | `UtteranceTranscribing`, `WhisperFinalTranscriber`, channel transcription, merge, render |
| `LiveTranscriber.swift` | `LiveTranscribing`, `LiveResult`, `AppleLiveTranscriber`, `LiveSpeechAssets` |
| `CoreAudioHelpers.swift` | Process list, PID to process object, default output UID, tap format |
| `ProcessTap.swift` | Core Audio process tap + private aggregate device |
| `CallAudioCapture.swift` | `CallCapturing`, mic (voice processing) + tap, 16 kHz output |
| `CallDetector.swift` | `AudioProcessSource`, `CallApp`, `KnownCallApps`, detector state machine |
| `CallSettings.swift` | UserDefaults keys and folder resolution |
| `CallSession.swift` | Coordinator, `SessionManifest`, recovery, termination |
| `Views/CallPromptPanel.swift` | "Transcribe this call?" non activating panel |
| `Views/CallTranscriptSettingsTab.swift` | Settings tab |

New tests in `Talk/TalkTests/`: `CallTestSupport.swift`, `TranscriptCleanerTests.swift`, `TranscriptFileTests.swift`, `SpeechSegmenterTests.swift`, `AudioFileTests.swift`, `FinalPassTests.swift`, `CallDetectorTests.swift`, `CallSessionTests.swift`, `CallEndToEndTests.swift`.

Modified: `TalkApp.swift`, `AppDelegate.swift`, `MenuBar/MenuBarView.swift`, `Views/SettingsView.swift`, `Whisper/WhisperContext.swift`, `Whisper/WhisperState.swift`, `Talk.xcodeproj/project.pbxproj` (two Info.plist keys only), `README.md`, `CLAUDE.md`, the spec.

Moved: `Talk/Talk/Meeting/DebugLogger.swift` to `Talk/Talk/Core/DebugLogger.swift`.

Deleted: the rest of `Talk/Talk/Meeting/`, `TalkTests/MeetingModelTests.swift`, `TalkTests/ChunkedTranscriberTests.swift`, `TalkTests/MeetingNotesGeneratorTests.swift`.

---

### Task 1: Remove the Meeting feature

**Files:**
- Move: `Talk/Talk/Meeting/DebugLogger.swift` → `Talk/Talk/Core/DebugLogger.swift`
- Delete: `Talk/Talk/Meeting/` (all remaining files), `Talk/TalkTests/MeetingModelTests.swift`, `Talk/TalkTests/ChunkedTranscriberTests.swift`, `Talk/TalkTests/MeetingNotesGeneratorTests.swift`
- Modify: `Talk/Talk/TalkApp.swift`, `Talk/Talk/AppDelegate.swift`, `Talk/Talk/MenuBar/MenuBarView.swift`, `Talk/Talk/Views/SettingsView.swift`, `Talk/Talk/Whisper/WhisperState.swift`, `Talk/Talk/Whisper/WhisperContext.swift`

**Interfaces:**
- Produces: `nonisolated enum DebugLogger { static func log(_ message: String, subsystem: String) }` usable from any thread.

- [ ] **Step 1: Move DebugLogger and make it nonisolated**

```bash
cd /Users/ak/code/DictAI/Talk
git mv Talk/Meeting/DebugLogger.swift Talk/Core/DebugLogger.swift
sed -i '' 's/^enum DebugLogger {/nonisolated enum DebugLogger {/' Talk/Core/DebugLogger.swift
grep -n 'enum DebugLogger' Talk/Core/DebugLogger.swift
```

Expected: `3:nonisolated enum DebugLogger {`

- [ ] **Step 2: Delete the Meeting feature and its tests**

```bash
cd /Users/ak/code/DictAI/Talk
git rm -r -q Talk/Meeting
git rm -q TalkTests/MeetingModelTests.swift TalkTests/ChunkedTranscriberTests.swift TalkTests/MeetingNotesGeneratorTests.swift
```

- [ ] **Step 3: Remove SwiftData and MeetingState from `TalkApp.swift`**

Replace the top of the file, from `import SwiftUI` through the closing brace of `init()`, with:

```swift
import SwiftUI

@main
struct TalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var permissionManager = PermissionManager.shared
    @StateObject private var whisperState = WhisperState.shared
    @StateObject private var hotkeyManager = HotkeyManager.shared
```

In `body`, replace:

```swift
                .environmentObject(meetingState)
        } label: {
            MenuBarIcon(isRecording: appState.isRecording, isMeetingActive: meetingState.isRecording)
        }
```

with:

```swift
        } label: {
            MenuBarIcon(isRecording: appState.isRecording)
        }
```

Replace the whole `MenuBarIcon` struct with:

```swift
// MARK: - Menu Bar Icon
struct MenuBarIcon: View {
    let isRecording: Bool
    var isCallRecording: Bool = false

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        if isCallRecording { return "record.circle.fill" }
        if isRecording { return "waveform.circle.fill" }
        return "waveform.circle"
    }

    private var iconColor: Color {
        if isCallRecording { return .red }
        if isRecording { return .red }
        return .primary
    }
}
```

- [ ] **Step 4: Remove meeting windows from `AppDelegate.swift`**

1. Delete the line `import SwiftData`.
2. Delete the two properties `private var meetingWindow: NSWindow?` and `private var meetingsListWindow: NSWindow?`.
3. In `applicationWillTerminate`, delete the comment line `// MeetingState handles its own termination via NotificationCenter`.
4. Delete everything from `// MARK: - Meeting Recording Window` down to (not including) `// MARK: - Recording Panel`. That removes `showMeetingRecordingWindow()`, `hideMeetingRecordingWindow()` and `showMeetingsWindow(_:)`.

- [ ] **Step 5: Remove the meeting section from `MenuBarView.swift`**

1. Delete `@EnvironmentObject var meetingState: MeetingState`.
2. In `body`, delete these lines (the call section replaces them in Task 11):

```swift
            // Meeting Section
            meetingSection

            Divider()
                .padding(.vertical, 8)

```

3. Delete everything from `// MARK: - Meeting Section` down to (not including) `// MARK: - Mode Section`.
4. In `#Preview`, delete `.environmentObject(MeetingState.shared)`.

- [ ] **Step 6: Remove the Meeting tab from `SettingsView.swift`**

Delete:

```swift
            MeetingSettingsTab()
                .tabItem {
                    Label("Meeting", systemImage: "person.2.wave.2")
                }

```

- [ ] **Step 7: Remove the old meeting Whisper API**

In `Whisper/WhisperState.swift`, delete the `// MARK: - Meeting Transcription` comment and the whole `transcribeMeetingChunk(samples:)` function.

In `Whisper/WhisperContext.swift`, delete the `// MARK: - Meeting Transcription (multi-segment, timestamps)` comment and the functions `transcribeMeeting(samples:)` and `getSegmentedTranscription()`.

- [ ] **Step 8: Confirm nothing still references the removed code**

```bash
cd /Users/ak/code/DictAI/Talk/Talk
grep -rn -E 'MeetingState|MeetingAudioEngine|ChunkedTranscriber|MeetingSettingsTab|MeetingRecordingView|MeetingListView|Meeting\.self|import SwiftData|transcribeMeeting|getSegmentedTranscription|showMeeting' --include='*.swift' . | grep -v whisper.xcframework
```

Expected: no output.

- [ ] **Step 9: Run the full test suite**

Run the full suite command from Global Constraints.
Expected: `** TEST SUCCEEDED **`, with the clipboard tests and `example()` passing.

- [ ] **Step 10: Commit**

```bash
cd /Users/ak/code/DictAI
git add -A Talk
git commit -q -m "Remove Meeting feature ahead of call transcripts

Deletes the meeting window, notes, bookmarks, SwiftData model and the
chunked transcriber. DebugLogger moves to Core and becomes nonisolated.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 2: Transcript types and TranscriptCleaner

**Files:**
- Create: `Talk/Talk/CallTranscript/TranscriptTypes.swift`
- Create: `Talk/Talk/CallTranscript/TranscriptCleaner.swift`
- Test: `Talk/TalkTests/TranscriptCleanerTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum Speaker: String, Codable, Sendable, CaseIterable { case you, them; var label: String }`
  - `nonisolated enum TranscriptStatus: String, Codable, Sendable { case live, processing, final, endedLiveOnly }`
  - `nonisolated struct TranscriptHeader: Equatable, Codable, Sendable { title, app, started, ended, channels, liveUnavailable, status }`
  - `nonisolated struct Turn: Equatable, Sendable { speaker, start, text }`
  - `nonisolated struct TimedText: Equatable, Sendable { speaker, start, text }`
  - `TranscriptCleaner.clean(_ text: String, confidence: Double?) -> String`

- [ ] **Step 1: Write the failing tests**

`Talk/TalkTests/TranscriptCleanerTests.swift`:

```swift
import Testing
@testable import DictAI

struct TranscriptCleanerTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let input: String
        let confidence: Double?
        let expected: String
        var testDescription: String { "\"\(input)\" -> \"\(expected)\"" }
    }

    static let junk: [Case] = [
        Case(input: "[BLANK_AUDIO]", confidence: nil, expected: ""),
        Case(input: "So (upbeat music) we start", confidence: nil, expected: "So we start"),
        Case(input: "Thanks for watching!", confidence: nil, expected: ""),
        Case(input: "Subtitles by the Amara.org community", confidence: nil, expected: ""),
        Case(input: "Thank you.", confidence: 0.2, expected: ""),
        Case(input: "Okay. Okay. Okay. Okay.", confidence: nil, expected: "Okay."),
    ]

    static let fillers: [Case] = [
        Case(input: "Um, so we start", confidence: nil, expected: "So we start"),
        Case(input: "I think, uh, we should go", confidence: nil, expected: "I think, we should go"),
        Case(input: "I think umm we're done", confidence: nil, expected: "I think we're done"),
        Case(input: "Hmm.", confidence: nil, expected: ""),
    ]

    static let stutters: [Case] = [
        Case(input: "I I I think the the plan works", confidence: nil, expected: "I think the plan works"),
        Case(input: "We should we should go", confidence: nil, expected: "We should go"),
        Case(input: "I, I think so", confidence: nil, expected: "I think so"),
    ]

    static let layout: [Case] = [
        Case(input: "hello , world . next", confidence: nil, expected: "Hello, world. Next"),
        Case(input: "  lots   of    space  ", confidence: nil, expected: "Lots of space"),
    ]

    /// Real speech that must come out exactly as it went in.
    static let mustNotChange: [Case] = [
        Case(input: "Thank you.", confidence: 0.9, expected: "Thank you."),
        Case(input: "Thank you.", confidence: nil, expected: "Thank you."),
        Case(input: "Okay. Okay.", confidence: nil, expected: "Okay. Okay."),
        Case(input: "Mm-hmm, yes.", confidence: nil, expected: "Mm-hmm, yes."),
        Case(input: "Uh-huh.", confidence: nil, expected: "Uh-huh."),
        Case(input: "I like it, you know.", confidence: nil, expected: "I like it, you know."),
        Case(input: "I had had enough.", confidence: nil, expected: "I had had enough."),
        Case(input: "I know that that is true.", confidence: nil, expected: "I know that that is true."),
        Case(input: "No. No. That's wrong.", confidence: nil, expected: "No. No. That's wrong."),
        Case(input: "It grew 3.5 percent in the U.S. market.", confidence: nil, expected: "It grew 3.5 percent in the U.S. market."),
        Case(input: "Well, so the numbers are fine.", confidence: nil, expected: "Well, so the numbers are fine."),
    ]

    @Test(arguments: junk) func removesJunk(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: fillers) func removesFillers(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: stutters) func collapsesStutters(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: layout) func tidiesLayout(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }

    @Test(arguments: mustNotChange) func keepsRealSpeech(_ c: Case) {
        #expect(TranscriptCleaner.clean(c.input, confidence: c.confidence) == c.expected)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `<Suite>` = `TranscriptCleanerTests`.
Expected: build error `cannot find 'TranscriptCleaner' in scope`.

- [ ] **Step 3: Write the types**

`Talk/Talk/CallTranscript/TranscriptTypes.swift`:

```swift
import Foundation

/// Which side of the call a piece of speech came from.
nonisolated enum Speaker: String, Codable, Sendable, CaseIterable {
    case you
    case them

    var label: String { self == .you ? "You" : "Them" }
}

/// Lifecycle of a transcript file. See the spec's "Agent contract".
nonisolated enum TranscriptStatus: String, Codable, Sendable {
    case live
    case processing
    case `final`
    case endedLiveOnly = "ended-live-only"
}

nonisolated struct TranscriptHeader: Equatable, Codable, Sendable {
    var title: String
    var app: String
    var started: Date
    var ended: Date?
    var channels: [Speaker]
    var liveUnavailable: Bool
    var status: TranscriptStatus
}

/// One speaker paragraph in the transcript.
nonisolated struct Turn: Equatable, Sendable {
    let speaker: Speaker
    let start: TimeInterval
    var text: String
}

/// A cleaned piece of text with its absolute start time in the recording.
nonisolated struct TimedText: Equatable, Sendable {
    let speaker: Speaker
    let start: TimeInterval
    let text: String
}
```

- [ ] **Step 4: Write the cleaner**

`Talk/Talk/CallTranscript/TranscriptCleaner.swift`:

```swift
import Foundation

/// Cleans transcript text without rewording it. The four rules and their
/// exceptions are defined in the call transcripts spec, section "TranscriptCleaner".
nonisolated enum TranscriptCleaner {

    static func clean(_ text: String, confidence: Double? = nil) -> String {
        var s = removeJunk(text, confidence: confidence)
        s = removeFillers(s)
        s = collapseStutters(s)
        s = tidy(s)
        return s.contains(where: { $0.isLetter || $0.isNumber }) ? s : ""
    }

    // MARK: - Rule 1: junk

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"[\[\(]\s*(?:blank_audio|music|noise|silence|applause|laughter|inaudible|[a-z ]*music)\s*[\]\)]"#,
        options: [.caseInsensitive]
    )
    private static let hallucinations: Set<String> = [
        "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe",
    ]
    private static let lowConfidenceOnly: Set<String> = ["thank you", "bye"]

    static func removeJunk(_ text: String, confidence: Double?) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var s = tagPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        s = collapseRepeatedSentences(s)
        let key = normalized(s)
        if hallucinations.contains(key) || key.hasPrefix("subtitles by") { return "" }
        if lowConfidenceOnly.contains(key), let confidence, confidence < 0.5 { return "" }
        return s
    }

    /// Reduces a run of 3 or more identical sentences to one. Returns the input
    /// untouched when there is no such run, so sentence splitting never alters text.
    static func collapseRepeatedSentences(_ text: String) -> String {
        let sentences = splitSentences(text)
        var out: [String] = []
        var changed = false
        var i = 0
        while i < sentences.count {
            var j = i + 1
            while j < sentences.count, normalized(sentences[j]) == normalized(sentences[i]) { j += 1 }
            if j - i >= 3 {
                out.append(sentences[i])
                changed = true
            } else {
                out.append(contentsOf: sentences[i..<j])
            }
            i = j
        }
        return changed ? out.joined(separator: " ") : text
    }

    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?]+[.!?]*"#)

    static func splitSentences(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return sentencePattern.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { text[$0].trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    /// Lowercased words only, for comparisons.
    static func normalized(_ s: String) -> String {
        let keep = CharacterSet.letters.union(.decimalDigits)
        let mapped = s.lowercased().unicodeScalars.map { keep.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Rule 2: fillers

    private static let fillerPattern = try! NSRegularExpression(pattern: #"^(?:u+m+|u+h+|e+r+m*|a+h+|h+m+)$"#)

    static func isFiller(_ word: String) -> Bool {
        let lower = word.lowercased()
        return fillerPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    static func removeFillers(_ text: String) -> String {
        var kept: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            let parts = splitPunctuation(token)
            guard isFiller(parts.core) else {
                kept.append(token)
                continue
            }
            // Keep a filler's sentence-ending punctuation by moving it onto the previous word.
            if let end = parts.trailing.last(where: { ".!?".contains($0) }),
               let last = kept.last,
               let lastChar = last.last,
               !".!?,;:".contains(lastChar) {
                kept[kept.count - 1] = last + String(end)
            }
        }
        return kept.joined(separator: " ")
    }

    static func splitPunctuation(_ token: String) -> (leading: String, core: String, trailing: String) {
        let chars = Array(token)
        var start = 0
        var end = chars.count
        while start < end, !(chars[start].isLetter || chars[start].isNumber) { start += 1 }
        while end > start, !(chars[end - 1].isLetter || chars[end - 1].isNumber) { end -= 1 }
        return (String(chars[..<start]), String(chars[start..<end]), String(chars[end...]))
    }

    // MARK: - Rule 3: stutters

    private static let keepDoubles: Set<String> = ["that", "had"]

    static func collapseStutters(_ text: String) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        var i = 0
        while i < tokens.count {
            var removed = false
            for n in stride(from: 3, through: 1, by: -1) where i + 2 * n <= tokens.count {
                let first = tokens[i..<(i + n)]
                // A block that ends a sentence is emphasis, not a stutter ("No. No.").
                if first.contains(where: { $0.last.map { ".!?".contains($0) } ?? false }) { continue }
                let a = first.map { splitPunctuation($0).core.lowercased() }
                let b = tokens[(i + n)..<(i + 2 * n)].map { splitPunctuation($0).core.lowercased() }
                guard a == b, !a.contains("") else { continue }
                if n == 1, keepDoubles.contains(a[0]) { continue }
                tokens.removeSubrange(i..<(i + n))
                removed = true
                break
            }
            if !removed { i += 1 }
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Rule 4: layout

    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.?!;:])"#)
    private static let sentenceStart = try! NSRegularExpression(pattern: #"(?:^|[.?!]\s+)([a-z])"#)

    static func tidy(_ text: String) -> String {
        var s = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = spaceBeforePunctuation.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        // Punctuation orphaned at the start by an earlier removal: ", so we" -> "so we".
        while let first = s.first, ",;:".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return capitalizeSentenceStarts(s)
    }

    static func capitalizeSentenceStarts(_ text: String) -> String {
        var result = text
        let matches = sentenceStart.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let r = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(r, with: result[r].uppercased())
        }
        return result
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the test command with `<Suite>` = `TranscriptCleanerTests`.
Expected: all 26 cases pass, `** TEST SUCCEEDED **`.

If `"So (upbeat music) we start"` fails, check that `tagPattern` has `.caseInsensitive`. If `"It grew 3.5 percent..."` fails, check that `collapseRepeatedSentences` returns `text` when `changed` is false.

- [ ] **Step 6: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript Talk/TalkTests/TranscriptCleanerTests.swift
git commit -q -m "Add transcript types and TranscriptCleaner

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 3: TranscriptRenderer and TranscriptFile

**Files:**
- Create: `Talk/Talk/CallTranscript/TranscriptRenderer.swift`
- Create: `Talk/Talk/CallTranscript/TranscriptFile.swift`
- Create: `Talk/TalkTests/CallTestSupport.swift`
- Test: `Talk/TalkTests/TranscriptFileTests.swift`

**Interfaces:**
- Consumes: `Speaker`, `TranscriptStatus`, `TranscriptHeader`, `Turn` from Task 2.
- Produces:
  - `TranscriptRenderer.statusWidth` (15), `statusValue(_:) -> String`, `timestamp(_ t: TimeInterval) -> String` (`HH:MM:SS`), `renderHeader(_:timeZone:) -> String`, `turnHeading(_:at:) -> String`, `document(header:turns:timeZone:) -> String`
  - `nonisolated final class TranscriptFile: @unchecked Sendable` with `static let livePointerName`, `let url: URL`, `var lastSpeaker: Speaker?`, `init(url:)`, `static func create(in:header:timeZone:) throws -> TranscriptFile`, `static func create(at:header:timeZone:) throws -> TranscriptFile`, `static func baseName(started:title:timeZone:) -> String`, `static func sanitizedTitle(_:) -> String`, `func append(speaker:at:text:) throws`, `func finishLiveText() throws`, `func setStatus(_:) throws`, `func body() throws -> String`, `func rewriteHeader(_:timeZone:) throws`, `func replaceAtomically(with:) throws`, `func pointLiveLink()`, `func removeLivePointer()`, `func close()`
  - Test support: `makeTempDirectory() -> URL`, `sampleHeader(title:status:) -> TranscriptHeader`, `utc: TimeZone`

- [ ] **Step 1: Write the test support file**

`Talk/TalkTests/CallTestSupport.swift`:

```swift
import Foundation
@testable import DictAI

let utc = TimeZone(identifier: "UTC")!

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictai-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 2026-09-29 14:30:05 UTC.
let sampleStart = Date(timeIntervalSince1970: 1_790_692_205)

func sampleHeader(title: String = "Weekly sync", status: TranscriptStatus = .live) -> TranscriptHeader {
    TranscriptHeader(
        title: title, app: "Zoom", started: sampleStart, ended: nil,
        channels: [.you, .them], liveUnavailable: false, status: status
    )
}
```

- [ ] **Step 2: Write the failing tests**

`Talk/TalkTests/TranscriptFileTests.swift`:

```swift
import Testing
import Foundation
@testable import DictAI

struct TranscriptFileTests {

    @Test func headerHasPaddedStatusAndQuotedTitle() {
        let text = TranscriptRenderer.renderHeader(sampleHeader(title: #"Q3: plan "final""#), timeZone: utc)
        let expected = [
            "---",
            #"title: "Q3: plan \"final\"""#,
            #"app: "Zoom""#,
            "started: 2026-09-29T14:30:05Z",
            "channels: you, them",
            "language: en",
            "status: live" + String(repeating: " ", count: 11),
            "---",
            "",
            #"# Q3: plan "final""#,
        ].joined(separator: "\n") + "\n"
        #expect(text == expected)
    }

    @Test func endedHeaderHasDurationAndLiveUnavailable() {
        var h = sampleHeader(status: .final)
        h.ended = sampleStart.addingTimeInterval(1956)
        h.channels = [.you]
        h.liveUnavailable = true
        let text = TranscriptRenderer.renderHeader(h, timeZone: utc)
        #expect(text.contains("ended: 2026-09-29T15:02:41Z\nduration: 00:32:36\n"))
        #expect(text.contains("channels: you\n"))
        #expect(text.contains("live: unavailable\n"))
        #expect(text.contains("status: final          \n"))
    }

    @Test func fileNameIsSanitized() {
        #expect(TranscriptFile.sanitizedTitle("Q3: plan/review \"final\"") == "Q3 plan review final")
        #expect(TranscriptFile.sanitizedTitle("  \n ") == "Call")
        #expect(TranscriptFile.sanitizedTitle(String(repeating: "a", count: 200)).count == 80)
        #expect(TranscriptFile.baseName(started: sampleStart, title: "Weekly sync", timeZone: utc)
                == "2026-09-29 1430 Weekly sync")
    }

    @Test func createWritesHeaderAndLivePointer() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        #expect(file.url.lastPathComponent == "2026-09-29 1430 Weekly sync.md")
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("_live.md").path)
        #expect(link == file.url.lastPathComponent)
    }

    @Test func nameCollisionGetsSuffix() throws {
        let dir = makeTempDirectory()
        _ = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        let second = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        #expect(second.url.lastPathComponent == "2026-09-29 1430 Weekly sync (2).md")
    }

    @Test func liveAppendsMatchFinalDocumentLayout() throws {
        let dir = makeTempDirectory()
        let header = sampleHeader()
        let file = try TranscriptFile.create(in: dir, header: header, timeZone: utc)
        try file.append(speaker: .you, at: 4, text: "So I looked at the numbers.")
        try file.append(speaker: .you, at: 7, text: "The drop is on mobile.")
        try file.append(speaker: .them, at: 11, text: "That matches.")
        try file.finishLiveText()
        let expected = TranscriptRenderer.document(header: header, turns: [
            Turn(speaker: .you, start: 4, text: "So I looked at the numbers. The drop is on mobile."),
            Turn(speaker: .them, start: 11, text: "That matches."),
        ], timeZone: utc)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == expected)
    }

    @Test func setStatusChangesOnlyTheHeaderInPlace() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        // Review Focus 1: body text that looks like a status line.
        try file.append(speaker: .you, at: 1, text: "Status: done")
        try file.append(speaker: .them, at: 2, text: "ok")
        let before = try Data(contentsOf: file.url)
        try file.setStatus(.processing)
        let after = try String(contentsOf: file.url, encoding: .utf8)
        #expect(try Data(contentsOf: file.url).count == before.count)
        #expect(after.contains("status: processing     \n---"))
        #expect(after.contains("**You** · 00:00:01\nStatus: done"))
    }

    @Test func rewriteHeaderKeepsBody() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        try file.append(speaker: .you, at: 1, text: "Hello there.")
        var h = sampleHeader(status: .endedLiveOnly)
        h.ended = sampleStart.addingTimeInterval(60)
        try file.rewriteHeader(h, timeZone: utc)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("status: ended-live-only\n"))
        #expect(text.hasSuffix("# Weekly sync\n\n**You** · 00:00:01\nHello there.\n"))
    }

    @Test func replaceAtomicallySwapsContents() throws {
        let dir = makeTempDirectory()
        let file = try TranscriptFile.create(in: dir, header: sampleHeader(), timeZone: utc)
        try file.replaceAtomically(with: "final text\n")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "final text\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func removeLivePointerOnlyRemovesItsOwnLink() throws {
        let dir = makeTempDirectory()
        let first = try TranscriptFile.create(in: dir, header: sampleHeader(title: "First"), timeZone: utc)
        let second = try TranscriptFile.create(in: dir, header: sampleHeader(title: "Second"), timeZone: utc)
        first.removeLivePointer()
        let link = dir.appendingPathComponent("_live.md").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == second.url.lastPathComponent)
        second.removeLivePointer()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run the test command with `<Suite>` = `TranscriptFileTests`.
Expected: build error `cannot find 'TranscriptRenderer' in scope`.

- [ ] **Step 4: Write the renderer**

`Talk/Talk/CallTranscript/TranscriptRenderer.swift`:

```swift
import Foundation

/// Markdown for transcript files. The only place the file format is defined.
nonisolated enum TranscriptRenderer {
    /// Length of the longest status value, `ended-live-only`.
    static let statusWidth = 15

    static func statusValue(_ status: TranscriptStatus) -> String {
        status.rawValue.padding(toLength: statusWidth, withPad: " ", startingAt: 0)
    }

    static func timestamp(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func isoDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Front matter plus the `# Title` line, ending with a newline.
    static func renderHeader(_ h: TranscriptHeader, timeZone: TimeZone = .current) -> String {
        let title = h.title.replacingOccurrences(of: "\n", with: " ")
        var lines = [
            "---",
            "title: \(quoted(title))",
            "app: \(quoted(h.app))",
            "started: \(isoDate(h.started, timeZone: timeZone))",
        ]
        if let ended = h.ended {
            lines.append("ended: \(isoDate(ended, timeZone: timeZone))")
            lines.append("duration: \(timestamp(ended.timeIntervalSince(h.started)))")
        }
        lines.append("channels: \(h.channels.map(\.rawValue).joined(separator: ", "))")
        lines.append("language: en")
        if h.liveUnavailable { lines.append("live: unavailable") }
        lines.append("status: \(statusValue(h.status))")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func turnHeading(_ speaker: Speaker, at t: TimeInterval) -> String {
        "**\(speaker.label)** · \(timestamp(t))"
    }

    static func document(header: TranscriptHeader, turns: [Turn], timeZone: TimeZone = .current) -> String {
        renderHeader(header, timeZone: timeZone)
            + turns.map { "\n\(turnHeading($0.speaker, at: $0.start))\n\($0.text)\n" }.joined()
    }
}
```

- [ ] **Step 5: Write TranscriptFile**

`Talk/Talk/CallTranscript/TranscriptFile.swift`:

```swift
import Foundation

nonisolated enum TranscriptFileError: Error {
    case statusLineMissing
    case malformed
}

/// The only writer of transcript files. Used from one serial queue at a time.
nonisolated final class TranscriptFile: @unchecked Sendable {
    static let livePointerName = "_live.md"

    let url: URL
    private(set) var lastSpeaker: Speaker?
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
    }

    // MARK: - Creating

    /// Creates a new transcript with a unique name in `folder` and points `_live.md` at it.
    static func create(in folder: URL, header: TranscriptHeader, timeZone: TimeZone = .current) throws -> TranscriptFile {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = baseName(started: header.started, title: header.title, timeZone: timeZone)
        let file = try create(at: uniqueURL(in: folder, base: base), header: header, timeZone: timeZone)
        file.pointLiveLink()
        return file
    }

    /// Writes a header to an exact path (used by crash recovery). Does not touch `_live.md`.
    static func create(at url: URL, header: TranscriptHeader, timeZone: TimeZone = .current) throws -> TranscriptFile {
        try Data(TranscriptRenderer.renderHeader(header, timeZone: timeZone).utf8).write(to: url)
        return TranscriptFile(url: url)
    }

    static func baseName(started: Date, title: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(formatter.string(from: started)) \(sanitizedTitle(title))"
    }

    static func sanitizedTitle(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
        let collapsed = replaced.split(separator: " ").joined(separator: " ")
        let limited = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? "Call" : limited
    }

    static func uniqueURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).md")
            n += 1
        }
        return candidate
    }

    // MARK: - Live pointer

    var livePointerURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(Self.livePointerName)
    }

    func pointLiveLink() {
        let fm = FileManager.default
        try? fm.removeItem(at: livePointerURL)
        // Relative destination, so the link survives the folder being moved.
        try? fm.createSymbolicLink(atPath: livePointerURL.path, withDestinationPath: url.lastPathComponent)
    }

    func removeLivePointer() {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: livePointerURL.path)) == url.lastPathComponent {
            try? fm.removeItem(at: livePointerURL)
        }
    }

    // MARK: - Live writing

    /// Appends text. Continues the current paragraph when the speaker is unchanged.
    func append(speaker: Speaker, at time: TimeInterval, text: String) throws {
        guard !text.isEmpty else { return }
        let chunk: String
        if speaker == lastSpeaker {
            chunk = " " + text
        } else {
            let separator = lastSpeaker == nil ? "" : "\n"
            chunk = separator + "\n" + TranscriptRenderer.turnHeading(speaker, at: time) + "\n" + text
        }
        try writeAtEnd(chunk)
        lastSpeaker = speaker
    }

    /// Ends the last paragraph with a newline, matching `TranscriptRenderer.document`.
    func finishLiveText() throws {
        guard lastSpeaker != nil else { return }
        try writeAtEnd("\n")
        lastSpeaker = nil
    }

    private func writeAtEnd(_ string: String) throws {
        let h = try openHandle()
        try h.seekToEnd()
        try h.write(contentsOf: Data(string.utf8))
        try h.synchronize()
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let h = try FileHandle(forWritingTo: url)
        handle = h
        return h
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    // MARK: - Status and replacement

    /// Overwrites the padded status value in place. The file length never changes.
    func setStatus(_ status: TranscriptStatus) throws {
        let data = try Data(contentsOf: url)
        // The header is first in the file, so the first match is the header's line.
        guard let range = data.range(of: Data("\nstatus: ".utf8)) else {
            throw TranscriptFileError.statusLineMissing
        }
        let h = try openHandle()
        try h.seek(toOffset: UInt64(range.upperBound))
        try h.write(contentsOf: Data(TranscriptRenderer.statusValue(status).utf8))
        try h.synchronize()
    }

    /// Everything after the `# Title` line.
    func body() throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let titleMarker = text.range(of: "\n---\n\n# "),
              let lineEnd = text.range(of: "\n", range: titleMarker.upperBound..<text.endIndex)
        else { throw TranscriptFileError.malformed }
        return String(text[lineEnd.upperBound...])
    }

    /// Replaces the header and keeps the body. Only used once the file is no longer live.
    func rewriteHeader(_ header: TranscriptHeader, timeZone: TimeZone = .current) throws {
        var body = try self.body()
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        try replaceAtomically(with: TranscriptRenderer.renderHeader(header, timeZone: timeZone) + body)
    }

    /// Writes to a temporary file in the same folder, then swaps it in.
    func replaceAtomically(with contents: String) throws {
        close()
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try Data(contents.utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the test command with `<Suite>` = `TranscriptFileTests`.
Expected: 9 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript Talk/TalkTests/CallTestSupport.swift Talk/TalkTests/TranscriptFileTests.swift
git commit -q -m "Add TranscriptRenderer and append-only TranscriptFile

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 4: SpeechSegmenter

**Files:**
- Create: `Talk/Talk/CallTranscript/SpeechSegmenter.swift`
- Modify: `Talk/TalkTests/CallTestSupport.swift` (signal helpers)
- Test: `Talk/TalkTests/SpeechSegmenterTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct Utterance: Equatable, Sendable { let startSample: Int; let samples: [Float]; var endSample: Int }`
  - `nonisolated struct SegmenterConfig: Sendable` (fields below)
  - `SpeechSegmenter.segment(_ samples: [Float], config: SegmenterConfig = .init()) -> [Utterance]`
  - Test support: `tone(_ seconds: Double, amplitude: Float = 0.1, frequency: Double = 220) -> [Float]`, `silence(_ seconds: Double) -> [Float]`, `noise(_ seconds: Double, rmsFrom: Float, rmsTo: Float, seed: UInt64) -> [Float]`, `seconds(_ sample: Int) -> Double`

- [ ] **Step 1: Add signal helpers to the test support file**

Append to `Talk/TalkTests/CallTestSupport.swift`:

```swift
// MARK: - Synthetic audio (16 kHz)

let testSampleRate = 16_000

func seconds(_ sample: Int) -> Double { Double(sample) / Double(testSampleRate) }

func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(testSampleRate)))
}

func tone(_ seconds: Double, amplitude: Float = 0.1, frequency: Double = 220) -> [Float] {
    let count = Int(seconds * Double(testSampleRate))
    return (0..<count).map { i in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / Double(testSampleRate)))
    }
}

/// Deterministic uniform noise whose RMS ramps linearly from `rmsFrom` to `rmsTo`.
func noise(_ seconds: Double, rmsFrom: Float, rmsTo: Float, seed: UInt64 = 42) -> [Float] {
    let count = Int(seconds * Double(testSampleRate))
    var state = seed
    return (0..<count).map { i in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24) * 2 - 1          // -1...1
        let rms = rmsFrom + (rmsTo - rmsFrom) * Float(i) / Float(max(1, count - 1))
        return unit * rms * Float(3).squareRoot()                         // uniform RMS = a / sqrt(3)
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Talk/TalkTests/SpeechSegmenterTests.swift`:

```swift
import Testing
@testable import DictAI

struct SpeechSegmenterTests {
    let frame = 0.03

    @Test func splitsAtLongPausesWithPreRoll() {
        let audio = silence(1) + tone(2) + silence(2) + tone(1) + silence(1)
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 2)
        #expect(abs(seconds(u[0].startSample) - 0.7) <= frame)     // 1.0 s minus 300 ms pre roll
        #expect(abs(seconds(u[1].startSample) - 4.7) <= frame)
        #expect(abs(seconds(u[0].endSample) - 3.2) <= frame)       // 3.0 s plus 200 ms post roll
    }

    @Test func mergesUtterancesLessThanOneSecondApart() {
        let audio = silence(1) + tone(1) + silence(0.8) + tone(1) + silence(1)
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 1)
        #expect(abs(seconds(u[0].endSample) - 4.0) <= frame)
    }

    @Test func dropsShortBlips() {
        let audio = silence(1) + tone(0.3) + silence(1)
        #expect(SpeechSegmenter.segment(audio).isEmpty)
    }

    @Test func capsLongUtterancesAtTheQuietestPoint() {
        // Speech from 2.0 s to 47.0 s with a near silent dip at 27.5 to 27.6 s.
        let audio = silence(2) + tone(25.5) + tone(0.1, amplitude: 0.001) + tone(19.4) + silence(2)
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 2)
        #expect(u.allSatisfy { seconds($0.samples.count) <= 28.0 })
        #expect(seconds(u[0].endSample) >= 27.5 - frame && seconds(u[0].endSample) <= 27.6 + frame)
        #expect(u[1].startSample == u[0].endSample)
    }

    @Test func risingNoiseFloorDoesNotStartSpeech() {
        var audio = noise(20, rmsFrom: 0.001, rmsTo: 0.004)
        let burst = tone(1, amplitude: 0.1)
        let at = 10 * testSampleRate
        for i in 0..<burst.count { audio[at + i] += burst[i] }
        let u = SpeechSegmenter.segment(audio)
        #expect(u.count == 1)
        #expect(abs(seconds(u[0].startSample) - 9.7) <= 2 * frame)
    }

    @Test func silenceGivesNothing() {
        #expect(SpeechSegmenter.segment(silence(5)).isEmpty)
        #expect(SpeechSegmenter.segment([]).isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run with `<Suite>` = `SpeechSegmenterTests`.
Expected: build error `cannot find 'SpeechSegmenter' in scope`.

- [ ] **Step 4: Write the segmenter**

`Talk/Talk/CallTranscript/SpeechSegmenter.swift`:

```swift
import Foundation

nonisolated struct Utterance: Equatable, Sendable {
    let startSample: Int
    let samples: [Float]
    var endSample: Int { startSample + samples.count }
}

nonisolated struct SegmenterConfig: Sendable {
    var sampleRate = 16_000
    var frameMs = 30
    var startSpeechMs = 150
    var endSilenceMs = 700
    var preRollMs = 300
    var postRollMs = 200
    var minSpeechMs = 400
    var maxUtteranceSec = 28.0
    var mergeGapSec = 1.0
    var capSearchSec = 3.0
    var noiseFactor: Float = 3
    var minThreshold: Float = 0.002
}

/// Splits a recorded channel into utterances at natural pauses, for the final pass.
/// Energy based: an adaptive noise floor, hysteresis on speech start and end,
/// merging of close utterances and a hard cap just under Whisper's 30 s window.
nonisolated enum SpeechSegmenter {

    static func segment(_ samples: [Float], config c: SegmenterConfig = .init()) -> [Utterance] {
        let frameLen = c.sampleRate * c.frameMs / 1000
        guard samples.count >= frameLen else { return [] }
        let energies = frameEnergies(samples, frameLen: frameLen)
        let voiced = voicedFlags(energies, config: c)
        let preRoll = c.preRollMs / c.frameMs
        let postRoll = c.postRollMs / c.frameMs
        let minFrames = c.minSpeechMs / c.frameMs

        var ranges: [Range<Int>] = speechSpans(voiced, config: c).compactMap { span in
            guard span.last - span.first + 1 >= minFrames else { return nil }
            let start = max(0, (span.first - preRoll) * frameLen)
            let end = min(samples.count, (span.last + 1 + postRoll) * frameLen)
            return start..<end
        }
        ranges = merge(ranges, config: c)
        ranges = ranges.flatMap { split($0, energies: energies, frameLen: frameLen, config: c) }
        return ranges.map { Utterance(startSample: $0.lowerBound, samples: Array(samples[$0])) }
    }

    static func frameEnergies(_ samples: [Float], frameLen: Int) -> [Float] {
        stride(from: 0, to: samples.count, by: frameLen).map { start in
            let end = min(samples.count, start + frameLen)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    /// Speech when energy exceeds `max(floor * noiseFactor, minThreshold)`. The floor starts
    /// at the 5th percentile and follows non speech frames, so slowly rising noise is tracked.
    static func voicedFlags(_ energies: [Float], config c: SegmenterConfig) -> [Bool] {
        let sorted = energies.sorted()
        var floor = sorted[sorted.count / 20]
        return energies.map { e in
            let isSpeech = e > max(floor * c.noiseFactor, c.minThreshold)
            if !isSpeech { floor = floor * 0.95 + e * 0.05 }
            return isSpeech
        }
    }

    /// Inclusive first and last voiced frame of each utterance.
    static func speechSpans(_ voiced: [Bool], config c: SegmenterConfig) -> [(first: Int, last: Int)] {
        let startFrames = max(1, c.startSpeechMs / c.frameMs)
        let endFrames = max(1, c.endSilenceMs / c.frameMs)
        var spans: [(first: Int, last: Int)] = []
        var run = 0
        var silent = 0
        var current: (first: Int, last: Int)?
        for (i, v) in voiced.enumerated() {
            if var span = current {
                if v {
                    span.last = i
                    current = span
                    silent = 0
                } else {
                    silent += 1
                    if silent >= endFrames {
                        spans.append(span)
                        current = nil
                        silent = 0
                        run = 0
                    }
                }
            } else {
                run = v ? run + 1 : 0
                if run >= startFrames {
                    current = (i - run + 1, i)
                    run = 0
                }
            }
        }
        if let span = current { spans.append(span) }
        return spans
    }

    static func merge(_ ranges: [Range<Int>], config c: SegmenterConfig) -> [Range<Int>] {
        let gap = Int(c.mergeGapSec * Double(c.sampleRate))
        let maxLen = Int(c.maxUtteranceSec * Double(c.sampleRate))
        var out: [Range<Int>] = []
        for r in ranges {
            guard let last = out.last else {
                out.append(r)
                continue
            }
            if r.lowerBound - last.upperBound < gap, r.upperBound - last.lowerBound <= maxLen {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else if r.lowerBound < last.upperBound {
                out.append(last.upperBound..<r.upperBound)   // rolls overlapped: no shared samples
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Cuts anything longer than the cap at the quietest frame in the last `capSearchSec`.
    static func split(_ r: Range<Int>, energies: [Float], frameLen: Int, config c: SegmenterConfig) -> [Range<Int>] {
        let maxLen = Int(c.maxUtteranceSec * Double(c.sampleRate))
        let search = Int(c.capSearchSec * Double(c.sampleRate))
        var out: [Range<Int>] = []
        var start = r.lowerBound
        while r.upperBound - start > maxLen {
            let windowEnd = start + maxLen
            let firstFrame = (windowEnd - search) / frameLen
            let lastFrame = min(energies.count - 1, windowEnd / frameLen - 1)
            var cutFrame = lastFrame
            if firstFrame <= lastFrame {
                cutFrame = (firstFrame...lastFrame).min { energies[$0] < energies[$1] } ?? lastFrame
            }
            let cut = max(start + 1, min(windowEnd, cutFrame * frameLen))
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<r.upperBound)
        return out
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run with `<Suite>` = `SpeechSegmenterTests`.
Expected: 6 tests pass.

If `capsLongUtterancesAtTheQuietestPoint` fails because the dip frames count as silence and end the span early, confirm the dip is only 0.1 s (3 frames), below `endSilenceMs` (23 frames).

- [ ] **Step 6: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript/SpeechSegmenter.swift Talk/TalkTests/CallTestSupport.swift Talk/TalkTests/SpeechSegmenterTests.swift
git commit -q -m "Add pause based SpeechSegmenter for the final pass

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 5: WAV files and audio buffer conversion

**Files:**
- Create: `Talk/Talk/CallTranscript/WAVFile.swift`
- Create: `Talk/Talk/CallTranscript/AudioBufferConverter.swift`
- Test: `Talk/TalkTests/AudioFileTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated final class WAVWriter: @unchecked Sendable { init(url:) throws; func write(_ samples: [Float]) throws; func finalize() throws; var sampleCount: Int; var peak: Float; let url: URL }`
  - `nonisolated enum WAVFile { static func header(dataBytes:sampleRate:) -> Data; static func readSamples(_ url: URL) throws -> [Float] }`
  - `nonisolated final class AudioBufferConverter { static let whisperFormat: AVAudioFormat; let inputFormat: AVAudioFormat; let outputFormat: AVAudioFormat; init?(from:to:); func convert(_:) -> AVAudioPCMBuffer? }`
  - `AVAudioPCMBuffer.monoSamples: [Float]` and `AVAudioPCMBuffer.mono16k(_ samples: [Float]) -> AVAudioPCMBuffer` (both `nonisolated`)

- [ ] **Step 1: Write the failing tests**

`Talk/TalkTests/AudioFileTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import DictAI

struct AudioFileTests {

    @Test func wavRoundTrip() throws {
        let url = makeTempDirectory().appendingPathComponent("a.wav")
        let writer = try WAVWriter(url: url)
        let input = tone(0.5) + silence(0.25)
        try writer.write(Array(input.prefix(3000)))
        try writer.write(Array(input.dropFirst(3000)))
        try writer.finalize()
        #expect(writer.sampleCount == input.count)
        #expect(abs(writer.peak - 0.1) < 0.001)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + input.count * 2)
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(UInt32(littleEndian: riffSize)) == 36 + input.count * 2)

        let back = try WAVFile.readSamples(url)
        #expect(back.count == input.count)
        #expect(zip(back, input).allSatisfy { abs($0 - $1) < 0.0001 })
    }

    /// Review Focus 4: a crash leaves the header claiming zero data bytes.
    @Test func readsUnfinalizedWav() throws {
        let url = makeTempDirectory().appendingPathComponent("crash.wav")
        var data = WAVFile.header(dataBytes: 0)
        for s in tone(0.1) {
            var v = Int16(s * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(0x7F)                                   // half a sample, as if cut mid write
        try data.write(to: url)
        #expect(try WAVFile.readSamples(url).count == tone(0.1).count)
    }

    @Test func converts48kStereoTo16kMono() throws {
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let converter = try #require(AudioBufferConverter(from: inFormat, to: AudioBufferConverter.whisperFormat))
        var out: [Float] = []
        for chunk in 0..<10 {                                // 1 s of 1 kHz in 100 ms chunks
            let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for i in 0..<4800 {
                let v = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(chunk * 4800 + i) / 48_000))
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
            }
            out += try #require(converter.convert(buffer)).monoSamples
        }
        #expect(abs(out.count - 16_000) <= 64)
        let crossings = zip(out, out.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(crossings - 2000) <= 40)
    }

    @Test func mono16kBufferRoundTrip() {
        let samples = tone(0.2)
        #expect(AVAudioPCMBuffer.mono16k(samples).monoSamples == samples)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run with `<Suite>` = `AudioFileTests`.
Expected: build error `cannot find 'WAVWriter' in scope`.

- [ ] **Step 3: Write the WAV code**

`Talk/Talk/CallTranscript/WAVFile.swift`:

```swift
import Foundation

nonisolated enum WAVFileError: Error {
    case tooShort
}

/// 16 bit PCM, mono, 16 kHz WAV helpers.
nonisolated enum WAVFile {
    static let headerSize = 44

    static func header(dataBytes: Int, sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// Reads every complete sample after the header, ignoring the header's sizes,
    /// so files left behind by a crash are read in full.
    static func readSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= headerSize else { throw WAVFileError.tooShort }
        let count = (data.count - headerSize) / 2
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: headerSize + i * 2, as: Int16.self))
                return Float(v) / Float(Int16.max)
            }
        }
    }
}

/// Streams samples to a WAV file. The header's sizes are patched in `finalize()`.
/// Used from one serial queue.
nonisolated final class WAVWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private(set) var sampleCount = 0
    private(set) var peak: Float = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: WAVFile.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.url = url
    }

    func write(_ samples: [Float]) throws {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            peak = max(peak, abs(clamped))
            var v = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func finalize() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVFile.header(dataBytes: sampleCount * 2))
        try handle.synchronize()
        try handle.close()
    }
}
```

- [ ] **Step 4: Write the converter**

`Talk/Talk/CallTranscript/AudioBufferConverter.swift`:

```swift
import AVFoundation

/// Streaming format conversion. Keeps resampler state between buffers, so it must
/// be used for one continuous stream from one thread at a time.
nonisolated final class AudioBufferConverter {
    /// Whisper's input format, and the format of every captured channel.
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.inputFormat = input
        self.outputFormat = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return out
    }
}

extension AVAudioPCMBuffer {
    /// First channel as Float samples. Expects a Float32 buffer.
    nonisolated var monoSamples: [Float] {
        guard let data = floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(frameLength)))
    }

    nonisolated static func mono16k(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioBufferConverter.whisperFormat,
            frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { dst.update(from: base, count: samples.count) }
            }
        }
        return buffer
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run with `<Suite>` = `AudioFileTests`.
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript/WAVFile.swift Talk/Talk/CallTranscript/AudioBufferConverter.swift Talk/TalkTests/AudioFileTests.swift
git commit -q -m "Add crash tolerant WAV writer/reader and audio converter

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 6: Whisper segments API and FinalPass

**Files:**
- Modify: `Talk/Talk/Whisper/WhisperContext.swift` (add `WhisperSegment` and `transcribeSegments`)
- Modify: `Talk/Talk/Whisper/WhisperState.swift` (add `transcribeSegments`)
- Create: `Talk/Talk/CallTranscript/FinalPass.swift`
- Modify: `Talk/TalkTests/CallTestSupport.swift` (fake transcriber)
- Test: `Talk/TalkTests/FinalPassTests.swift`

**Interfaces:**
- Consumes: `SpeechSegmenter`, `TranscriptCleaner`, `TranscriptRenderer`, `TimedText`, `Turn`, `TranscriptHeader`.
- Produces:
  - `nonisolated struct WhisperSegment: Equatable, Sendable { let text: String; let start: TimeInterval; let end: TimeInterval; let confidence: Double? }` (times in seconds, relative to the samples passed in)
  - `WhisperContext.transcribeSegments(samples:initialPrompt:beamSize:) -> [WhisperSegment]?`
  - `WhisperState.transcribeSegments(samples:initialPrompt:beamSize:) async throws -> [WhisperSegment]`
  - `nonisolated protocol UtteranceTranscribing: Sendable { func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] }`
  - `nonisolated struct WhisperFinalTranscriber: UtteranceTranscribing`
  - `FinalPass.transcribeChannel(_:speaker:using:) async -> ChannelResult`, `FinalPass.mergeIntoTurns(_:) -> [Turn]`, `FinalPass.render(channels:header:using:timeZone:) async throws -> String`, `FinalPassError.transcriptionUnavailable`
  - Test support: `final class FakeTranscriber: UtteranceTranscribing, @unchecked Sendable { init(responses: [[WhisperSegment]], failAll: Bool = false); var prompts: [String?] }`

- [ ] **Step 1: Add the fake transcriber to the test support file**

Append to `Talk/TalkTests/CallTestSupport.swift`:

```swift
// MARK: - Fakes

enum FakeError: Error { case failed }

/// Returns scripted segments, one response per call, and records the prompts it was given.
final class FakeTranscriber: UtteranceTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[WhisperSegment]]
    private let failAll: Bool
    private(set) var prompts: [String?] = []

    init(responses: [[WhisperSegment]], failAll: Bool = false) {
        self.responses = responses
        self.failAll = failAll
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] {
        try lock.withLock {
            prompts.append(prompt)
            if failAll { throw FakeError.failed }
            return responses.isEmpty ? [] : responses.removeFirst()
        }
    }
}

func seg(_ text: String, _ start: TimeInterval, confidence: Double? = 0.9) -> WhisperSegment {
    WhisperSegment(text: text, start: start, end: start + 1, confidence: confidence)
}
```

- [ ] **Step 2: Write the failing tests**

`Talk/TalkTests/FinalPassTests.swift`:

```swift
import Testing
import Foundation
@testable import DictAI

struct FinalPassTests {

    /// Two utterances: speech at 1.0 to 3.0 s and 5.0 to 6.0 s.
    let twoUtterances = silence(1) + tone(2) + silence(2) + tone(1) + silence(1)

    @Test func channelTimesAreUtteranceOffsetPlusSegmentStart() async {
        let fake = FakeTranscriber(responses: [[seg("um, hello there", 0.5)], [seg("second part", 0.2)]])
        let result = await FinalPass.transcribeChannel(twoUtterances, speaker: .them, using: fake)
        #expect(result.items.map(\.text) == ["Hello there", "Second part"])
        #expect(abs(result.items[0].start - 1.2) < 0.05)        // 0.7 s utterance start + 0.5 s
        #expect(abs(result.items[1].start - 4.9) < 0.05)        // 4.7 s + 0.2 s
        #expect(result.attempted == 2 && result.failed == 0)
        #expect(fake.prompts == [nil, "Hello there"])
    }

    @Test func lowConfidenceThankYouIsDropped() async {
        let fake = FakeTranscriber(responses: [[seg("Thank you.", 0, confidence: 0.2)], [seg("Real words", 0)]])
        let result = await FinalPass.transcribeChannel(twoUtterances, speaker: .you, using: fake)
        #expect(result.items.map(\.text) == ["Real words"])
    }

    @Test func mergeOrdersByTimeAndGroupsSpeakers() {
        let turns = FinalPass.mergeIntoTurns([
            TimedText(speaker: .them, start: 5, text: "Them later."),
            TimedText(speaker: .you, start: 1, text: "First."),
            TimedText(speaker: .you, start: 2, text: "Still me."),
            TimedText(speaker: .them, start: 2, text: "Interrupting."),   // tie: you first
            TimedText(speaker: .you, start: 9, text: "Last."),
        ])
        #expect(turns == [
            Turn(speaker: .you, start: 1, text: "First. Still me."),
            Turn(speaker: .them, start: 2, text: "Interrupting. Them later."),
            Turn(speaker: .you, start: 9, text: "Last."),
        ])
    }

    @Test func renderProducesFinalDocument() async throws {
        let fake = FakeTranscriber(responses: [[seg("hello", 0)], [seg("bye now", 0)], [seg("hi", 0)]])
        var header = sampleHeader()
        header.ended = sampleStart.addingTimeInterval(8)
        let doc = try await FinalPass.render(
            channels: [.you: twoUtterances, .them: silence(2) + tone(1) + silence(1)],
            header: header, using: fake, timeZone: utc)
        #expect(doc.contains("status: final          \n"))
        #expect(doc.contains("duration: 00:00:08\n"))
        #expect(doc.hasSuffix("**You** · 00:00:00\nHello\n\n**Them** · 00:00:01\nHi\n\n**You** · 00:00:04\nBye now\n"))
    }

    /// Review Focus 5: no Whisper model means every utterance fails.
    @Test func renderThrowsWhenEveryUtteranceFails() async {
        let fake = FakeTranscriber(responses: [], failAll: true)
        await #expect(throws: FinalPassError.transcriptionUnavailable) {
            _ = try await FinalPass.render(channels: [.you: twoUtterances], header: sampleHeader(), using: fake, timeZone: utc)
        }
    }

    @Test func renderOfSilenceIsAnEmptyFinalTranscript() async throws {
        let fake = FakeTranscriber(responses: [])
        let doc = try await FinalPass.render(channels: [.you: silence(3)], header: sampleHeader(), using: fake, timeZone: utc)
        #expect(doc.hasSuffix("# Weekly sync\n"))
    }
}
```

Check of the expected times in `renderProducesFinalDocument`: You utterances start at 0.7 s and 4.7 s, and Them at 1.7 s (2.0 s minus 300 ms pre roll). All segment starts are 0, so turns start at 00:00:00, 00:00:01 and 00:00:04.

- [ ] **Step 3: Run the tests to verify they fail**

Run with `<Suite>` = `FinalPassTests`.
Expected: build error `cannot find type 'UtteranceTranscribing' in scope`.

- [ ] **Step 4: Add `WhisperSegment` and `transcribeSegments` to WhisperContext**

At the top of `Talk/Talk/Whisper/WhisperContext.swift`, after the imports, add:

```swift
/// One Whisper segment. Times are seconds relative to the samples passed in.
nonisolated struct WhisperSegment: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// Mean probability of the segment's text tokens, or nil if it has none.
    let confidence: Double?
}
```

Inside the actor, before `// MARK: - Model Info`, add:

```swift
    // MARK: - Segments (call transcripts)

    /// Transcribes and reads results in one actor call, so a dictation request
    /// cannot run in between and overwrite the results.
    func transcribeSegments(samples: [Float], initialPrompt: String?, beamSize: Int) -> [WhisperSegment]? {
        #if canImport(whisper)
        guard let ctx = context, !samples.isEmpty,
              !samples.contains(where: { $0.isNaN || $0.isInfinite }) else { return nil }

        var params = whisper_full_default_params(beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 2))
        params.beam_search.beam_size = Int32(beamSize)
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.no_speech_thold = 0.6
        params.suppress_blank = true
        params.suppress_nst = true

        let prompt = initialPrompt ?? ""
        let ok: Bool = "en".withCString { lang in
            prompt.withCString { promptPtr in
                params.language = lang
                params.initial_prompt = prompt.isEmpty ? nil : promptPtr
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count)) == 0
                }
            }
        }
        guard ok else { return nil }

        let eot = whisper_token_eot(ctx)
        return (0..<whisper_full_n_segments(ctx)).compactMap { i in
            guard let cText = whisper_full_get_segment_text(ctx, i) else { return nil }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var probabilities: [Float] = []
            for j in 0..<whisper_full_n_tokens(ctx, i) where whisper_full_get_token_id(ctx, i, j) < eot {
                probabilities.append(whisper_full_get_token_p(ctx, i, j))
            }
            let confidence = probabilities.isEmpty
                ? nil : Double(probabilities.reduce(0, +) / Float(probabilities.count))
            // Segment t0 and t1 are in 10 ms units.
            return WhisperSegment(
                text: text,
                start: Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                end: Double(whisper_full_get_segment_t1(ctx, i)) / 100,
                confidence: confidence)
        }
        #else
        return [WhisperSegment(text: "[whisper unavailable]", start: 0, end: 1, confidence: nil)]
        #endif
    }
```

- [ ] **Step 5: Add `transcribeSegments` to WhisperState**

In `Talk/Talk/Whisper/WhisperState.swift`, before `func unloadModel()`, add:

```swift
    // MARK: - Call transcripts

    /// Loads the model if needed, then transcribes with timestamps and confidences.
    func transcribeSegments(samples: [Float], initialPrompt: String?, beamSize: Int = 5) async throws -> [WhisperSegment] {
        if whisperContext == nil { await loadModel() }
        guard let context = whisperContext else { throw WhisperError.modelNotLoaded }
        guard let segments = await context.transcribeSegments(
            samples: samples, initialPrompt: initialPrompt, beamSize: beamSize) else {
            throw WhisperError.transcriptionFailed
        }
        return segments
    }
```

- [ ] **Step 6: Write FinalPass**

`Talk/Talk/CallTranscript/FinalPass.swift`:

```swift
import Foundation

nonisolated protocol UtteranceTranscribing: Sendable {
    func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment]
}

/// Final pass transcription through the app's shared Whisper model.
nonisolated struct WhisperFinalTranscriber: UtteranceTranscribing {
    func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] {
        try await WhisperState.shared.transcribeSegments(samples: samples, initialPrompt: prompt, beamSize: 5)
    }
}

nonisolated enum FinalPassError: Error, Equatable {
    /// Every utterance failed, for example because no Whisper model could be loaded.
    case transcriptionUnavailable
}

/// Transcribes complete recordings after the call and renders the final document.
nonisolated enum FinalPass {
    static let promptCharacters = 200

    struct ChannelResult: Sendable {
        var items: [TimedText] = []
        var attempted = 0
        var failed = 0
    }

    static func transcribeChannel(
        _ samples: [Float], speaker: Speaker, using transcriber: UtteranceTranscribing, sampleRate: Int = 16_000
    ) async -> ChannelResult {
        var result = ChannelResult()
        var context = ""
        for utterance in SpeechSegmenter.segment(samples) {
            result.attempted += 1
            let prompt = context.isEmpty ? nil : String(context.suffix(promptCharacters))
            let segments: [WhisperSegment]
            do {
                segments = try await transcriber.transcribe(samples: utterance.samples, prompt: prompt)
            } catch {
                result.failed += 1
                DebugLogger.log("Final pass failed at sample \(utterance.startSample): \(error)", subsystem: "Calls")
                continue
            }
            let offset = Double(utterance.startSample) / Double(sampleRate)
            for segment in segments {
                let text = TranscriptCleaner.clean(segment.text, confidence: segment.confidence)
                guard !text.isEmpty else { continue }
                result.items.append(TimedText(speaker: speaker, start: offset + segment.start, text: text))
                context += (context.isEmpty ? "" : " ") + text
            }
        }
        return result
    }

    /// Sorted by start time (ties: You first), consecutive same speaker text joined.
    static func mergeIntoTurns(_ items: [TimedText]) -> [Turn] {
        let sorted = items.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.speaker != b.element.speaker { return a.element.speaker == .you }
            return a.offset < b.offset
        }.map(\.element)
        var turns: [Turn] = []
        for item in sorted {
            if let last = turns.last, last.speaker == item.speaker {
                turns[turns.count - 1].text += " " + item.text
            } else {
                turns.append(Turn(speaker: item.speaker, start: item.start, text: item.text))
            }
        }
        return turns
    }

    static func render(
        channels: [Speaker: [Float]], header: TranscriptHeader,
        using transcriber: UtteranceTranscribing, timeZone: TimeZone = .current
    ) async throws -> String {
        var items: [TimedText] = []
        var attempted = 0
        var failed = 0
        for speaker in Speaker.allCases {
            guard let samples = channels[speaker] else { continue }
            let result = await transcribeChannel(samples, speaker: speaker, using: transcriber)
            items += result.items
            attempted += result.attempted
            failed += result.failed
        }
        if attempted > 0, failed == attempted { throw FinalPassError.transcriptionUnavailable }
        var finalHeader = header
        finalHeader.status = .final
        return TranscriptRenderer.document(header: finalHeader, turns: mergeIntoTurns(items), timeZone: timeZone)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run with `<Suite>` = `FinalPassTests`.
Expected: 6 tests pass. Then run the full suite to confirm the Whisper changes build and nothing else broke.

- [ ] **Step 8: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/Whisper Talk/Talk/CallTranscript/FinalPass.swift Talk/TalkTests/CallTestSupport.swift Talk/TalkTests/FinalPassTests.swift
git commit -q -m "Add Whisper segment API with confidences and the FinalPass

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 7: Apple live transcriber

**Files:**
- Create: `Talk/Talk/CallTranscript/LiveTranscriber.swift`
- Modify: `Talk/TalkTests/CallTestSupport.swift` (scripted call, word accuracy)
- Test: `Talk/TalkTests/CallEndToEndTests.swift` (live part; Task 12 adds the Whisper part)

**Interfaces:**
- Consumes: `Speaker`, `AudioBufferConverter`, `DebugLogger`.
- Produces:
  - `nonisolated struct LiveResult: Equatable, Sendable { let speaker: Speaker; let start: TimeInterval; let text: String; let confidence: Double? }`
  - `nonisolated protocol LiveTranscribing: AnyObject, Sendable { var speaker: Speaker { get }; func start(onResult: @escaping @Sendable (LiveResult) -> Void) async throws; func append(_ buffer: AVAudioPCMBuffer); func finish() async }`
  - `nonisolated final class AppleLiveTranscriber: LiveTranscribing, @unchecked Sendable { init(speaker:) }`
  - `nonisolated enum LiveSpeechAssets { static let locale: Locale; static func ensureInstalled() async -> Bool; static func isInstalled() async -> Bool }`
  - Test support: `ScriptedCall.make() throws -> ScriptedCall` with `you: [Float]`, `them: [Float]`, `youText: String`, `themText: String`; `wordAccuracy(expected:actual:) -> Double`; `e2eEnabled: Bool`

- [ ] **Step 1: Add the scripted call and accuracy helpers**

Append to `Talk/TalkTests/CallTestSupport.swift`:

```swift
// MARK: - Scripted call for end to end tests

import AVFoundation

let e2eEnabled = ProcessInfo.processInfo.environment["DICTAI_E2E"] == "1"

struct ScriptedCall {
    static let youLines = [
        "Good morning, thanks for joining the call today.",
        "I looked at the numbers from last week and the drop is mostly on mobile.",
        "Yes, I will send you the full breakdown after this call.",
    ]
    static let themLines = [
        "Happy to be here. What did you find?",
        "That matches what the support team told us on Monday.",
        "Perfect. Talk to you next week then.",
    ]

    let you: [Float]
    let them: [Float]
    var youText: String { Self.youLines.joined(separator: " ") }
    var themText: String { Self.themLines.joined(separator: " ") }

    /// Voices each line with `say` and lays the turns out alternately with 1 s gaps,
    /// starting with You at 0.5 s. Both channels have the same length.
    static func make() throws -> ScriptedCall {
        let dir = makeTempDirectory()
        func voice(_ text: String, _ name: String) throws -> [Float] {
            let url = dir.appendingPathComponent("\(name).wav")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
            try p.run()
            p.waitUntilExit()
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            return buffer.monoSamples
        }
        var you: [Float] = silence(0.5)
        var them: [Float] = silence(0.5)
        for i in 0..<youLines.count {
            let y = try voice(youLines[i], "you\(i)")
            you += y + silence(1)
            them += silence(seconds(y.count) + 1)
            let t = try voice(themLines[i], "them\(i)")
            them += t + silence(1)
            you += silence(seconds(t.count) + 1)
        }
        let length = max(you.count, them.count)
        you += [Float](repeating: 0, count: length - you.count)
        them += [Float](repeating: 0, count: length - them.count)
        return ScriptedCall(you: you, them: them)
    }
}

func words(_ s: String) -> [String] {
    s.lowercased()
        .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        .split(separator: " ").map(String.init)
}

/// 1 minus word error rate, floored at 0.
func wordAccuracy(expected: String, actual: String) -> Double {
    let e = words(expected), a = words(actual)
    guard !e.isEmpty else { return a.isEmpty ? 1 : 0 }
    var previous = Array(0...a.count)
    for i in 1...e.count {
        var current = [i] + [Int](repeating: 0, count: a.count)
        for j in 1...max(1, a.count) where j <= a.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (e[i - 1] == a[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return max(0, 1 - Double(previous[a.count]) / Double(e.count))
}
```

Move `import AVFoundation` to the top of the file with the other imports.

- [ ] **Step 2: Write the failing live test**

`Talk/TalkTests/CallEndToEndTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import DictAI

/// Real speech engines on a scripted call. Run with DICTAI_E2E=1 in the environment:
/// `DICTAI_E2E=1 xcodebuild test ... -only-testing:TalkTests/CallEndToEndTests`
@Suite(.enabled(if: e2eEnabled, "Set DICTAI_E2E=1 to run end to end tests"))
struct CallEndToEndTests {

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LiveResult] = []
        func add(_ r: LiveResult) { lock.withLock { items.append(r) } }
        var all: [LiveResult] { lock.withLock { items } }
    }

    @Test func liveTranscriberHearsBothChannels() async throws {
        try #require(await LiveSpeechAssets.ensureInstalled(), "Apple speech assets are not installed")
        let call = try ScriptedCall.make()
        let collector = Collector()
        // Two analyzers at once: the spec's "two concurrent analyzers" risk.
        let you = AppleLiveTranscriber(speaker: .you)
        let them = AppleLiveTranscriber(speaker: .them)
        try await you.start { collector.add($0) }
        try await them.start { collector.add($0) }
        let chunk = testSampleRate / 10
        for offset in stride(from: 0, to: call.you.count, by: chunk) {
            let end = min(call.you.count, offset + chunk)
            you.append(.mono16k(Array(call.you[offset..<end])))
            them.append(.mono16k(Array(call.them[offset..<end])))
        }
        await you.finish()
        await them.finish()

        let results = collector.all
        let youText = results.filter { $0.speaker == .you }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        let themText = results.filter { $0.speaker == .them }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        #expect(wordAccuracy(expected: call.youText, actual: youText) >= 0.85, "You: \(youText)")
        #expect(wordAccuracy(expected: call.themText, actual: themText) >= 0.85, "Them: \(themText)")
        #expect(themText.lowercased().contains("next week"))    // last sentence present after finish()
        #expect(results.allSatisfy { $0.start >= 0 && $0.start < seconds(call.you.count) })
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd /Users/ak/code/DictAI/Talk && DICTAI_E2E=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkTest \
  -only-testing:TalkTests/CallEndToEndTests CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  2>&1 | grep -E "error:|✘|✔|TEST (SUCCEEDED|FAILED)" | tail -20
```

Expected: build error `cannot find 'AppleLiveTranscriber' in scope`.

`xcodebuild` passes environment variables that start with `TEST_RUNNER_` to the test process with the prefix removed. If `DICTAI_E2E=1` does not reach the test (the suite is reported as skipped), use `TEST_RUNNER_DICTAI_E2E=1` instead, and use that form everywhere this plan runs end to end tests.

- [ ] **Step 4: Write the live transcriber**

`Talk/Talk/CallTranscript/LiveTranscriber.swift`:

```swift
import AVFoundation
import Speech

nonisolated struct LiveResult: Equatable, Sendable {
    let speaker: Speaker
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let text: String
    let confidence: Double?
}

nonisolated protocol LiveTranscribing: AnyObject, Sendable {
    var speaker: Speaker { get }
    /// Prepares the engine. Buffers appended before this returns are dropped.
    func start(onResult: @escaping @Sendable (LiveResult) -> Void) async throws
    /// Any PCM format. Must be called from one thread at a time.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finalizes everything appended so far and waits for the last results.
    func finish() async
}

nonisolated enum LiveTranscriberError: Error {
    case noAudioFormat
}

nonisolated enum LiveSpeechAssets {
    static let locale = Locale(identifier: "en-US")

    /// Installs the on device English model if needed. False if it cannot be used.
    static func ensureInstalled() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            DebugLogger.log("Speech asset install failed: \(error)", subsystem: "Calls")
            return false
        }
        return await isInstalled()
    }

    static func isInstalled() async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }
}

/// One SpeechAnalyzer and SpeechTranscriber for one channel. Only finalized results
/// are reported, so nothing written to the live file is ever retracted.
nonisolated final class AppleLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let speaker: Speaker

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AudioBufferConverter?
    private var resultsTask: Task<Void, Never>?

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    func start(onResult: @escaping @Sendable (LiveResult) -> Void) async throws {
        let transcriber = SpeechTranscriber(
            locale: LiveSpeechAssets.locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTranscriberError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let speaker = self.speaker

        let task = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let confidences = result.text.runs.compactMap { $0.transcriptionConfidence }
                    let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    onResult(LiveResult(speaker: speaker, start: result.range.start.seconds, text: text, confidence: confidence))
                }
            } catch {
                DebugLogger.log("Live results for \(speaker.rawValue) ended: \(error)", subsystem: "Calls")
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        lock.withLock {
            self.analyzer = analyzer
            self.continuation = continuation
            self.analyzerFormat = format
            self.resultsTask = task
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let analyzerFormat else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AudioBufferConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converted = converter?.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        let (analyzer, continuation, task) = lock.withLock { (self.analyzer, self.continuation, self.resultsTask) }
        continuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            DebugLogger.log("Live finish for \(speaker.rawValue) failed: \(error)", subsystem: "Calls")
        }
        await task?.value
    }
}
```

If `result.text.runs.compactMap { $0.transcriptionConfidence }` does not compile, use the explicit key path form: `result.text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }`.

- [ ] **Step 5: Run the live test to verify it passes**

Run the Step 3 command again.
Expected: `liveTranscriberHearsBothChannels` passes. The first run may take a few minutes while macOS downloads the English speech model.

If accuracy is below 0.85 on one channel only while running two analyzers, that is the spec's "two concurrent analyzers" risk. Record the failing text in the task report and stop; do not lower the threshold.

- [ ] **Step 6: Confirm the normal suite still skips end to end tests**

Run the full suite command from Global Constraints (without `DICTAI_E2E`).
Expected: `** TEST SUCCEEDED **` and `CallEndToEndTests` reported as skipped.

- [ ] **Step 7: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript/LiveTranscriber.swift Talk/TalkTests/CallTestSupport.swift Talk/TalkTests/CallEndToEndTests.swift
git commit -q -m "Add Apple SpeechTranscriber live transcriber with scripted call test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 8: Core Audio process tap and call audio capture

**Files:**
- Create: `Talk/Talk/CallTranscript/CoreAudioHelpers.swift`
- Create: `Talk/Talk/CallTranscript/ProcessTap.swift`
- Create: `Talk/Talk/CallTranscript/CallAudioCapture.swift`
- Test: `Talk/TalkTests/CallCaptureHardwareTests.swift` (opt in, needs real audio hardware and permission)

**Interfaces:**
- Consumes: `Speaker`, `AudioBufferConverter`, `DebugLogger`.
- Produces:
  - `CoreAudioHelpers.processObjectIDs() -> [AudioObjectID]`, `pid(of:) -> pid_t?`, `bundleID(of:) -> String?`, `isRunningInput(_:) -> Bool`, `processObjectID(for pid: pid_t) -> AudioObjectID?`, `defaultOutputDeviceUID() throws -> String`, `tapFormat(_:) throws -> AudioStreamBasicDescription`
  - `nonisolated final class ProcessTap: @unchecked Sendable { func start(processes: [AudioObjectID]?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws; func stop() }` (`nil` processes = all system audio except DictAI)
  - `nonisolated protocol CallCapturing: AnyObject { var onAudio: (@Sendable (Speaker, AVAudioPCMBuffer) -> Void)? { get set }; func start(appBundleKey: String?) throws -> [Speaker]; func stop() }`
  - `nonisolated final class CallAudioCapture: CallCapturing, @unchecked Sendable`
  - `nonisolated enum CallCaptureError: Error { case noMicrophone }`

This task wraps hardware, so its automated test is opt in. The logic that matters for correctness (conversion, WAV, segmentation) is already unit tested.

- [ ] **Step 1: Write the opt in hardware test**

`Talk/TalkTests/CallCaptureHardwareTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import DictAI

/// Needs speakers or headphones, a microphone, and System Audio Recording permission
/// for the test host. Run with DICTAI_HW=1 in the environment.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DICTAI_HW"] == "1"))
struct CallCaptureHardwareTests {

    final class Peaks: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Speaker: Float] = [:]
        private var formats: [Speaker: Double] = [:]
        func add(_ s: Speaker, _ b: AVAudioPCMBuffer) {
            let peak = b.monoSamples.map(abs).max() ?? 0
            lock.withLock {
                values[s] = max(values[s] ?? 0, peak)
                formats[s] = b.format.sampleRate
            }
        }
        subscript(s: Speaker) -> Float { lock.withLock { values[s] ?? 0 } }
        func rate(_ s: Speaker) -> Double? { lock.withLock { formats[s] } }
    }

    @Test func capturesSystemAudioAndMic() async throws {
        let capture = CallAudioCapture()
        let peaks = Peaks()
        capture.onAudio = { peaks.add($0, $1) }
        let channels = try capture.start(appBundleKey: nil)
        #expect(channels == [.you, .them])

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        try await Task.sleep(for: .seconds(3))
        capture.stop()

        #expect(peaks[.them] > 0.01, "No system audio: check System Audio Recording permission")
        #expect(peaks.rate(.you) == 16_000)
        #expect(peaks.rate(.them) == 16_000)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/ak/code/DictAI/Talk && DICTAI_HW=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme DictAI -destination 'platform=macOS' -derivedDataPath /tmp/TalkTest \
  -only-testing:TalkTests/CallCaptureHardwareTests CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  2>&1 | grep -E "error:|✘|✔|TEST (SUCCEEDED|FAILED)" | tail -20
```

Expected: build error `cannot find 'CallAudioCapture' in scope`. (Use `TEST_RUNNER_DICTAI_HW=1` if the plain variable does not reach the test, as in Task 7.)

- [ ] **Step 3: Write the Core Audio helpers**

`Talk/Talk/CallTranscript/CoreAudioHelpers.swift`:

```swift
import CoreAudio
import Foundation

nonisolated enum CoreAudioError: Error {
    case status(OSStatus, String)
}

nonisolated func checkStatus(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.status(status, what) }
}

/// Thin wrappers over the Core Audio property API used by call detection and capture.
nonisolated enum CoreAudioHelpers {

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func processObjectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        stringProperty(object, kAudioProcessPropertyBundleID)
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDeviceUID() throws -> String {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkStatus(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
            "default output device")
        guard let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError.status(-1, "output device UID")
        }
        return uid
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkStatus(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format), "tap format")
        return format
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }
}
```

- [ ] **Step 4: Write the process tap**

`Talk/Talk/CallTranscript/ProcessTap.swift`:

```swift
import AVFoundation
import CoreAudio

nonisolated enum ProcessTapError: Error {
    case badFormat
}

/// Captures the audio output of chosen processes through a Core Audio process tap
/// read via a private aggregate device. Needs NSAudioCaptureUsageDescription; the
/// first use shows the System Audio Recording permission prompt.
nonisolated final class ProcessTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ai.xdigit.dictai.processtap", qos: .userInitiated)

    /// `processes` nil taps all system audio except DictAI. The buffer passed to
    /// `onBuffer` is only valid during the call; copy or convert it synchronously.
    func start(processes: [AudioObjectID]?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description: CATapDescription
        if let processes, !processes.isEmpty {
            description = CATapDescription(monoMixdownOfProcesses: processes)
        } else {
            let own = CoreAudioHelpers.processObjectID(for: getpid()).map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try checkStatus(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        var asbd = try CoreAudioHelpers.tapFormat(tap)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw ProcessTapError.badFormat
        }

        let outputUID = try CoreAudioHelpers.defaultOutputDeviceUID()
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DictAI Call Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try checkStatus(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate), "create aggregate device")
            aggregateID = aggregate

            var proc: AudioDeviceIOProcID?
            try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                onBuffer(buffer)
            }, "create IO proc")
            procID = proc
            try checkStatus(AudioDeviceStart(aggregate, proc), "start aggregate device")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
```

If `CATapDescription(monoMixdownOfProcesses:)` or `description.isPrivate` do not compile with these names, check the Swift names in Xcode's generated interface for `CATapDescription` (Open Quickly, then "Generated Interface"). The Objective C property is `privateTap` with getter `isPrivate`.

- [ ] **Step 5: Write the call capture**

`Talk/Talk/CallTranscript/CallAudioCapture.swift`:

```swift
import AVFoundation
import CoreAudio

nonisolated enum CallCaptureError: Error {
    case noMicrophone
}

nonisolated protocol CallCapturing: AnyObject {
    /// 16 kHz mono Float32 buffers, delivered on audio threads.
    var onAudio: (@Sendable (Speaker, AVAudioPCMBuffer) -> Void)? { get set }
    /// Starts capture and returns the channels that actually started.
    /// `appBundleKey` nil taps all system audio except DictAI.
    func start(appBundleKey: String?) throws -> [Speaker]
    func stop()
}

/// You: microphone with echo cancellation. Them: process tap on the call app.
nonisolated final class CallAudioCapture: CallCapturing, @unchecked Sendable {
    var onAudio: (@Sendable (Speaker, AVAudioPCMBuffer) -> Void)?

    private var engine: AVAudioEngine?
    private let tap = ProcessTap()
    private var micConverter: AudioBufferConverter?
    private var tapConverter: AudioBufferConverter?

    func start(appBundleKey: String?) throws -> [Speaker] {
        try startMicrophone()
        var channels: [Speaker] = [.you]
        do {
            let processes = appBundleKey.map(Self.processObjects(matching:))
            try tap.start(processes: processes) { [weak self] buffer in
                guard let self else { return }
                if self.tapConverter == nil {
                    self.tapConverter = AudioBufferConverter(from: buffer.format, to: AudioBufferConverter.whisperFormat)
                }
                guard let out = self.tapConverter?.convert(buffer) else { return }
                self.onAudio?(.them, out)
            }
            channels.append(.them)
        } catch {
            DebugLogger.log("System audio tap failed: \(error). Recording the microphone only.", subsystem: "Calls")
        }
        return channels
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tap.stop()
        micConverter = nil
        tapConverter = nil
    }

    /// Every process whose bundle ID is the key or starts with "key." (helper processes).
    static func processObjects(matching key: String) -> [AudioObjectID] {
        CoreAudioHelpers.processObjectIDs().filter { object in
            guard let id = CoreAudioHelpers.bundleID(of: object) else { return false }
            return id == key || id.hasPrefix(key + ".")
        }
    }

    private func startMicrophone() throws {
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            DebugLogger.log("Mic with voice processing failed: \(error). Retrying without.", subsystem: "Calls")
            stop()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing needs the output side of the engine to exist.
            engine.mainMixerNode.outputVolume = 0
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CallCaptureError.noMicrophone }
        micConverter = AudioBufferConverter(from: format, to: AudioBufferConverter.whisperFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let out = self.micConverter?.convert(buffer) else { return }
            self.onAudio?(.you, out)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }
}
```

- [ ] **Step 6: Build and run the hardware test**

Run the Step 2 command.
Expected: macOS asks the test host for System Audio Recording permission the first time. Allow it and run again. Then `capturesSystemAudioAndMic` passes.

If the tap reports a peak of 0 after permission is granted, check that the output device is not in exclusive use by another app and that the system volume is not muted, then run again. Record findings in the task report.

- [ ] **Step 7: Run the full suite**

Run the full suite command. Expected: `** TEST SUCCEEDED **`, hardware and end to end suites skipped.

- [ ] **Step 8: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript/CoreAudioHelpers.swift Talk/Talk/CallTranscript/ProcessTap.swift Talk/Talk/CallTranscript/CallAudioCapture.swift Talk/TalkTests/CallCaptureHardwareTests.swift
git commit -q -m "Add Core Audio process tap and two channel call capture

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 9: CallDetector

**Files:**
- Create: `Talk/Talk/CallTranscript/CallDetector.swift`
- Modify: `Talk/TalkTests/CallTestSupport.swift` (fake process source, clock)
- Test: `Talk/TalkTests/CallDetectorTests.swift`

**Interfaces:**
- Consumes: `CoreAudioHelpers`.
- Produces:
  - `nonisolated struct AudioProcessInfo: Equatable, Sendable { let pid: pid_t; let bundleID: String; let isRunningInput: Bool }`
  - `nonisolated protocol AudioProcessSource: AnyObject { func currentProcesses() -> [AudioProcessInfo] }`
  - `nonisolated final class CoreAudioProcessSource: AudioProcessSource`
  - `nonisolated struct CallApp: Equatable, Codable, Sendable { let bundleKey: String; let name: String }`
  - `nonisolated enum KnownCallApps { static let names: [String: String]; static func match(_ bundleID: String) -> CallApp? }`
  - `@MainActor final class CallDetector { init(source:ownPID:now:startDelay:releaseDelay:); var onCallStarted: ((CallApp) -> Void)?; var onCallEnded: ((CallApp) -> Void)?; private(set) var state: State; func activeCallApp() -> CallApp?; func evaluate(); func startMonitoring(); func stopMonitoring() }`
  - Test support: `final class FakeProcessSource: AudioProcessSource { var processes: [AudioProcessInfo] }`, `final class TestClock { var now: Date; func advance(_ s: TimeInterval) }`

- [ ] **Step 1: Add fakes to the test support file**

Append to `Talk/TalkTests/CallTestSupport.swift`:

```swift
final class FakeProcessSource: AudioProcessSource {
    var processes: [AudioProcessInfo] = []
    func currentProcesses() -> [AudioProcessInfo] { processes }
}

final class TestClock: @unchecked Sendable {
    var now = sampleStart
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
```

- [ ] **Step 2: Write the failing tests**

`Talk/TalkTests/CallDetectorTests.swift`:

```swift
import Testing
import Foundation
@testable import DictAI

@MainActor
struct CallDetectorTests {
    let source = FakeProcessSource()
    let clock = TestClock()
    let zoom = AudioProcessInfo(pid: 500, bundleID: "us.zoom.xos", isRunningInput: true)

    func makeDetector() -> (CallDetector, started: () -> [CallApp], ended: () -> [CallApp]) {
        let detector = CallDetector(source: source, ownPID: 999, now: { [clock] in clock.now })
        var started: [CallApp] = []
        var ended: [CallApp] = []
        detector.onCallStarted = { started.append($0) }
        detector.onCallEnded = { ended.append($0) }
        return (detector, { started }, { ended })
    }

    /// Advances the clock second by second, evaluating each tick like the 1 s timer.
    func tick(_ detector: CallDetector, seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(1)
            detector.evaluate()
        }
    }

    @Test func startsAfterThreeSecondsOfMicUse() {
        let (detector, started, _) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 2)
        #expect(started().isEmpty)
        tick(detector, seconds: 1)
        #expect(started() == [CallApp(bundleKey: "us.zoom.xos", name: "Zoom")])
        tick(detector, seconds: 5)
        #expect(started().count == 1)
    }

    @Test func briefMicUseDoesNotStart() {
        let (detector, started, _) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 2)
        source.processes = []
        tick(detector, seconds: 5)
        #expect(started().isEmpty)
        #expect(detector.state == .idle)
    }

    @Test func endsTenSecondsAfterRelease() {
        let (detector, _, ended) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 3)
        source.processes = []
        tick(detector, seconds: 9)
        #expect(ended().isEmpty)
        tick(detector, seconds: 1)
        #expect(ended().map(\.name) == ["Zoom"])
    }

    @Test func reacquiringTheMicCancelsTheEnd() {
        let (detector, started, ended) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 3)
        source.processes = []
        tick(detector, seconds: 5)
        source.processes = [zoom]
        tick(detector, seconds: 1)
        source.processes = []
        tick(detector, seconds: 9)
        #expect(ended().isEmpty)
        #expect(started().count == 1)
    }

    @Test func ignoresDictAIAndUnknownApps() {
        let (detector, started, _) = makeDetector()
        source.processes = [
            AudioProcessInfo(pid: 999, bundleID: "us.zoom.xos", isRunningInput: true),
            AudioProcessInfo(pid: 600, bundleID: "com.example.recorder", isRunningInput: true),
            AudioProcessInfo(pid: 700, bundleID: "com.google.Chrome", isRunningInput: false),
        ]
        detector.evaluate()
        tick(detector, seconds: 5)
        #expect(started().isEmpty)
    }

    @Test func matchesHelperProcessesAndSafari() {
        #expect(KnownCallApps.match("com.google.Chrome.helper") == CallApp(bundleKey: "com.google.Chrome", name: "Google Chrome"))
        #expect(KnownCallApps.match("com.microsoft.teams2.helper")?.name == "Microsoft Teams")
        #expect(KnownCallApps.match("com.apple.WebKit.GPU")?.name == "Safari")
        #expect(KnownCallApps.match("com.google.Chromebook") == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run with `<Suite>` = `CallDetectorTests`.
Expected: build error `cannot find 'CallDetector' in scope`.

- [ ] **Step 4: Write the detector**

`Talk/Talk/CallTranscript/CallDetector.swift`:

```swift
import Foundation
import CoreAudio

nonisolated struct AudioProcessInfo: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
}

nonisolated protocol AudioProcessSource: AnyObject {
    func currentProcesses() -> [AudioProcessInfo]
}

nonisolated final class CoreAudioProcessSource: AudioProcessSource {
    func currentProcesses() -> [AudioProcessInfo] {
        CoreAudioHelpers.processObjectIDs().compactMap { object in
            guard let pid = CoreAudioHelpers.pid(of: object),
                  let bundleID = CoreAudioHelpers.bundleID(of: object) else { return nil }
            return AudioProcessInfo(pid: pid, bundleID: bundleID, isRunningInput: CoreAudioHelpers.isRunningInput(object))
        }
    }
}

nonisolated struct CallApp: Equatable, Codable, Sendable {
    /// The known bundle ID the process matched; used to find the processes to tap.
    let bundleKey: String
    let name: String
}

nonisolated enum KnownCallApps {
    static let names: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.apple.WebKit.GPU": "Safari",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
    ]

    /// Exact bundle ID, or a helper whose ID starts with a known ID plus ".".
    static func match(_ bundleID: String) -> CallApp? {
        for (key, name) in names where bundleID == key || bundleID.hasPrefix(key + ".") {
            return CallApp(bundleKey: key, name: name)
        }
        return nil
    }
}

/// Notices when a known call app starts and stops using the microphone.
@MainActor
final class CallDetector {
    enum State: Equatable {
        case idle
        case candidate(CallApp, since: Date)
        case inCall(CallApp)
        case releasing(CallApp, since: Date)
    }

    var onCallStarted: ((CallApp) -> Void)?
    var onCallEnded: ((CallApp) -> Void)?
    private(set) var state: State = .idle

    private let source: AudioProcessSource
    private let ownPID: pid_t
    private let now: () -> Date
    private let startDelay: TimeInterval
    private let releaseDelay: TimeInterval
    private var timer: Timer?

    init(
        source: AudioProcessSource, ownPID: pid_t = getpid(), now: @escaping () -> Date = Date.init,
        startDelay: TimeInterval = 3, releaseDelay: TimeInterval = 10
    ) {
        self.source = source
        self.ownPID = ownPID
        self.now = now
        self.startDelay = startDelay
        self.releaseDelay = releaseDelay
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func activeCallApp() -> CallApp? {
        for process in source.currentProcesses() where process.isRunningInput && process.pid != ownPID {
            if let app = KnownCallApps.match(process.bundleID) { return app }
        }
        return nil
    }

    func evaluate() {
        let active = activeCallApp()
        let t = now()
        switch state {
        case .idle:
            if let active { state = .candidate(active, since: t) }
        case let .candidate(app, since):
            if active != app {
                state = active.map { .candidate($0, since: t) } ?? .idle
            } else if t.timeIntervalSince(since) >= startDelay {
                state = .inCall(app)
                onCallStarted?(app)
            }
        case let .inCall(app):
            if active != app { state = .releasing(app, since: t) }
        case let .releasing(app, since):
            if active == app {
                state = .inCall(app)
            } else if t.timeIntervalSince(since) >= releaseDelay {
                state = .idle
                onCallEnded?(app)
            }
        }
    }
}
```

`KnownCallApps.names` is a dictionary, so iteration order is not fixed. No two keys are prefixes of each other plus `.` except `com.microsoft.teams` and `com.microsoft.teams2`, which map to the same name, so the order does not change the result.

- [ ] **Step 5: Run the tests to verify they pass**

Run with `<Suite>` = `CallDetectorTests`.
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript/CallDetector.swift Talk/TalkTests/CallTestSupport.swift Talk/TalkTests/CallDetectorTests.swift
git commit -q -m "Add CallDetector for known call apps using the microphone

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 10: CallSession coordinator

**Files:**
- Create: `Talk/Talk/CallTranscript/CallSettings.swift`
- Create: `Talk/Talk/CallTranscript/CallSession.swift`
- Modify: `Talk/TalkTests/CallTestSupport.swift` (fake capture, fake live)
- Test: `Talk/TalkTests/CallSessionTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2 to 9.
- Produces:
  - `enum CallSettings { static let folderKey, autoDetectKey, keepAudioKey: String; static var defaultFolder: URL; static var folderURL: URL; static var sessionsRoot: URL }`
  - `nonisolated struct SessionManifest: Codable, Equatable { var header: TranscriptHeader; var transcriptPath: String; var appBundleKey: String? }`
  - `struct CallSessionEnvironment` (fields below) with `static var live: CallSessionEnvironment`
  - `@MainActor final class CallSession: ObservableObject` with `static let shared`, `init(environment:)`, `@Published phase: Phase` (`.idle`, `.recording(started: Date, app: CallApp?)`), `@Published warning: String?`, `@Published pendingRetries: [URL]`, `@Published finalizingCount: Int`, `var isRecording: Bool`, `func start(app: CallApp?) async`, `func startManually() async`, `func stop() async`, `func waitForFinalization() async`, `func recoverOrphanedSessions() async`, `func retryPending() async`, `func handleTermination()`, `func bootstrap()`, `func drainForTesting() async`
  - Test support: `FakeCapture`, `FakeLive`

- [ ] **Step 1: Add capture and live fakes to the test support file**

Append to `Talk/TalkTests/CallTestSupport.swift`:

```swift
final class FakeCapture: CallCapturing, @unchecked Sendable {
    var onAudio: (@Sendable (Speaker, AVAudioPCMBuffer) -> Void)?
    var channels: [Speaker] = [.you, .them]
    private(set) var started = false
    private(set) var stopped = false

    func start(appBundleKey: String?) throws -> [Speaker] {
        started = true
        return channels
    }
    func stop() { stopped = true }

    /// Sends samples as if the hardware produced them.
    func emit(_ speaker: Speaker, _ samples: [Float]) {
        onAudio?(speaker, .mono16k(samples))
    }
}

final class FakeLive: LiveTranscribing, @unchecked Sendable {
    let speaker: Speaker
    private var onResult: (@Sendable (LiveResult) -> Void)?
    private(set) var appendedFrames = 0
    private(set) var finished = false

    init(speaker: Speaker) { self.speaker = speaker }

    func start(onResult: @escaping @Sendable (LiveResult) -> Void) async throws { self.onResult = onResult }
    func append(_ buffer: AVAudioPCMBuffer) { appendedFrames += Int(buffer.frameLength) }
    func finish() async { finished = true }

    func emit(_ text: String, at start: TimeInterval, confidence: Double? = 0.9) {
        onResult?(LiveResult(speaker: speaker, start: start, text: text, confidence: confidence))
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Talk/TalkTests/CallSessionTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import DictAI

@MainActor
struct CallSessionTests {
    let transcripts = makeTempDirectory()
    let sessions = makeTempDirectory()
    let capture = FakeCapture()
    var lives: [Speaker: FakeLive] = [.you: FakeLive(speaker: .you), .them: FakeLive(speaker: .them)]

    func makeSession(
        transcriber: UtteranceTranscribing = FakeTranscriber(responses: [[seg("final words", 0)]]),
        liveAssets: Bool = true, keepAudio: Bool = false
    ) -> CallSession {
        let lives = self.lives
        let capture = self.capture
        let env = CallSessionEnvironment(
            transcriptsFolder: { [transcripts] in transcripts },
            sessionsRoot: sessions,
            makeCapture: { capture },
            makeLive: { lives[$0]! },
            liveAssetsReady: { liveAssets },
            transcriber: transcriber,
            calendarTitle: { nil },
            keepAudio: { keepAudio },
            now: { sampleStart },
            timeZone: utc)
        return CallSession(environment: env)
    }

    func transcriptText() throws -> String {
        let name = try FileManager.default.contentsOfDirectory(atPath: transcripts.path)
            .first { $0.hasSuffix(".md") && $0 != "_live.md" }!
        return try String(contentsOf: transcripts.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func liveResultsStreamIntoTheFileThenFinalReplacesIt() async throws {
        let session = makeSession()
        await session.start(app: CallApp(bundleKey: "us.zoom.xos", name: "Zoom"))
        #expect(session.isRecording)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        capture.emit(.them, silence(1) + tone(2) + silence(1))
        lives[.you]!.emit("um, hello there", at: 1.2)
        lives[.them]!.emit("hi", at: 2.5)
        await session.drainForTesting()

        let live = try transcriptText()
        #expect(live.contains("title: \"Zoom call\""))
        #expect(live.contains("status: live           \n"))
        #expect(live.hasSuffix("**You** · 00:00:01\nHello there\n\n**Them** · 00:00:02\nHi"))
        #expect(FileManager.default.fileExists(atPath: transcripts.appendingPathComponent("_live.md").path))

        await session.stop()
        await session.waitForFinalization()
        #expect(capture.stopped)
        #expect(lives[.you]!.finished && lives[.them]!.finished)
        let final = try transcriptText()
        #expect(final.contains("status: final          \n"))
        #expect(final.contains("Final words"))
        #expect(!FileManager.default.fileExists(atPath: transcripts.appendingPathComponent("_live.md").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
    }

    @Test func missingSpeechAssetsMarksLiveUnavailable() async throws {
        let session = makeSession(liveAssets: false)
        await session.start(app: nil)
        #expect(try transcriptText().contains("live: unavailable\n"))
        #expect(lives[.you]!.appendedFrames == 0)
        await session.stop()
        await session.waitForFinalization()
    }

    /// Review Focus 3: permission denied, the tap delivers only zeros.
    @Test func silentThemChannelBecomesYouOnly() async throws {
        let session = makeSession()
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        capture.emit(.them, silence(4))
        await session.stop()
        await session.waitForFinalization()
        #expect(try transcriptText().contains("channels: you\n"))
        #expect(session.warning?.contains("System Audio Recording") == true)
    }

    /// Review Focus 5: Whisper unavailable keeps the live text.
    @Test func failedFinalPassKeepsLiveText() async throws {
        let session = makeSession(transcriber: FakeTranscriber(responses: [], failAll: true))
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        lives[.you]!.emit("keep me", at: 1)
        await session.stop()
        await session.waitForFinalization()
        let text = try transcriptText()
        #expect(text.contains("status: ended-live-only\n"))
        #expect(text.contains("Keep me\n"))
        #expect(session.pendingRetries.count == 1)
    }

    /// Review Focus 4: crash recovery from an orphaned session with unfinalized WAVs.
    @Test func recoversOrphanedSession() async throws {
        let folder = sessions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var wav = WAVFile.header(dataBytes: 0)
        for s in silence(1) + tone(2) + silence(1) {
            var v = Int16(s * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        try wav.write(to: folder.appendingPathComponent("you.wav"))
        let path = transcripts.appendingPathComponent("2026-09-29 1430 Crashed call.md").path
        let manifest = SessionManifest(
            header: TranscriptHeader(title: "Crashed call", app: "Zoom", started: sampleStart, ended: nil,
                                     channels: [.you], liveUnavailable: false, status: .live),
            transcriptPath: path, appBundleKey: nil)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("session.json"))

        let session = makeSession()
        await session.recoverOrphanedSessions()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("status: final          \n"))
        #expect(text.contains("duration: 00:00:04\n"))
        #expect(text.contains("Final words"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func keepAudioMovesWavsNextToTranscript() async throws {
        let session = makeSession(keepAudio: true)
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        capture.emit(.them, silence(1) + tone(1) + silence(2))
        await session.stop()
        await session.waitForFinalization()
        let names = try FileManager.default.contentsOfDirectory(atPath: transcripts.path)
        #expect(names.contains { $0.hasSuffix(".you.wav") })
        #expect(names.contains { $0.hasSuffix(".them.wav") })
    }

    @Test func secondCallCanStartWhileFirstIsFinalizing() async throws {
        let session = makeSession()
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        await session.stop()
        await session.start(app: nil)
        #expect(session.isRecording)
        await session.stop()
        await session.waitForFinalization()
        let files = try FileManager.default.contentsOfDirectory(atPath: transcripts.path).filter { $0.hasSuffix(".md") }
        #expect(files.count == 2)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run with `<Suite>` = `CallSessionTests`.
Expected: build error `cannot find 'CallSession' in scope`.

- [ ] **Step 4: Write CallSettings**

`Talk/Talk/CallTranscript/CallSettings.swift`:

```swift
import Foundation

enum CallSettings {
    static let folderKey = "callTranscriptsFolder"
    static let autoDetectKey = "callAutoDetect"
    static let keepAudioKey = "callKeepAudio"

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictAI Transcripts", isDirectory: true)
    }

    /// The chosen folder if it exists or can be created, else the default.
    static var folderURL: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: url.path) {
                return url
            }
            DebugLogger.log("Transcripts folder \(path) not writable, using default", subsystem: "Calls")
        }
        return defaultFolder
    }

    static var autoDetect: Bool {
        UserDefaults.standard.object(forKey: autoDetectKey) as? Bool ?? true
    }

    static var keepAudio: Bool {
        UserDefaults.standard.bool(forKey: keepAudioKey)
    }

    static var sessionsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictAI/Sessions", isDirectory: true)
    }
}
```

- [ ] **Step 5: Write CallSession**

`Talk/Talk/CallTranscript/CallSession.swift`:

```swift
import AVFoundation
import AppKit
import Combine
import EventKit

nonisolated struct SessionManifest: Codable, Equatable {
    var header: TranscriptHeader
    var transcriptPath: String
    var appBundleKey: String?
}

struct CallSessionEnvironment {
    var transcriptsFolder: () -> URL
    var sessionsRoot: URL
    var makeCapture: () -> CallCapturing
    var makeLive: (Speaker) -> LiveTranscribing
    /// True if live transcription can run now. Must return quickly; never waits for a download.
    var liveAssetsReady: () async -> Bool
    var transcriber: UtteranceTranscribing
    var calendarTitle: () -> String?
    var keepAudio: () -> Bool
    var now: () -> Date
    var timeZone: TimeZone = .current

    static var live: CallSessionEnvironment {
        CallSessionEnvironment(
            transcriptsFolder: { CallSettings.folderURL },
            sessionsRoot: CallSettings.sessionsRoot,
            makeCapture: { CallAudioCapture() },
            makeLive: { AppleLiveTranscriber(speaker: $0) },
            liveAssetsReady: {
                if await LiveSpeechAssets.isInstalled() { return true }
                Task.detached { _ = await LiveSpeechAssets.ensureInstalled() }   // ready for the next call
                return false
            },
            transcriber: WhisperFinalTranscriber(),
            calendarTitle: { CallSession.currentCalendarEventTitle() },
            keepAudio: { CallSettings.keepAudio },
            now: Date.init)
    }
}

/// Everything belonging to the call being recorded. After `start` returns, the WAV
/// writers, live transcriber input and transcript file are only touched on `sink`.
nonisolated private final class ActiveRecording: @unchecked Sendable {
    let folder: URL
    var manifest: SessionManifest
    let file: TranscriptFile
    let capture: CallCapturing
    let live: [Speaker: LiveTranscribing]
    let writers: [Speaker: WAVWriter]
    let sink: DispatchQueue

    init(folder: URL, manifest: SessionManifest, file: TranscriptFile, capture: CallCapturing,
         live: [Speaker: LiveTranscribing], writers: [Speaker: WAVWriter], sink: DispatchQueue) {
        self.folder = folder
        self.manifest = manifest
        self.file = file
        self.capture = capture
        self.live = live
        self.writers = writers
        self.sink = sink
    }
}

nonisolated private func drain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
}

@MainActor
final class CallSession: ObservableObject {
    static let shared = CallSession(environment: .live)

    enum Phase: Equatable {
        case idle
        case recording(started: Date, app: CallApp?)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var warning: String?
    @Published private(set) var pendingRetries: [URL] = []
    @Published private(set) var finalizingCount = 0

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private let env: CallSessionEnvironment
    private var active: ActiveRecording?
    private var finalizations: [Task<Void, Never>] = []
    private var detector: CallDetector?

    init(environment: CallSessionEnvironment) {
        self.env = environment
    }

    // MARK: - App lifecycle

    func bootstrap() {
        let detector = CallDetector(source: CoreAudioProcessSource())
        detector.onCallStarted = { [weak self] app in self?.callDetected(app) }
        detector.onCallEnded = { [weak self] app in self?.callEnded(app) }
        detector.startMonitoring()
        self.detector = detector
        Task { await recoverOrphanedSessions() }
        Task.detached { _ = await LiveSpeechAssets.ensureInstalled() }   // so the first call has live text
    }

    private func callDetected(_ app: CallApp) {
        guard CallSettings.autoDetect, !isRecording else { return }
        CallPromptPanel.shared.show(app: app) { [weak self] accepted in
            guard accepted else { return }
            Task { await self?.start(app: app) }
        }
    }

    private func callEnded(_ app: CallApp) {
        CallPromptPanel.shared.dismiss()
        if case let .recording(_, recordingApp) = phase, recordingApp == app {
            Task { await stop() }
        }
    }

    /// Menu bar "Transcribe Call": uses the call app if one is on the mic.
    func startManually() async {
        await start(app: detector?.activeCallApp())
    }

    // MARK: - Recording

    func start(app: CallApp?) async {
        guard !isRecording else { return }
        warning = nil
        let started = env.now()
        let title = env.calendarTitle() ?? app.map { "\($0.name) call" } ?? "Call"
        var header = TranscriptHeader(
            title: title, app: app?.name ?? "Unknown", started: started, ended: nil,
            channels: [.you, .them], liveUnavailable: false, status: .live)
        do {
            let folder = env.sessionsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writers: [Speaker: WAVWriter] = [
                .you: try WAVWriter(url: folder.appendingPathComponent("you.wav")),
                .them: try WAVWriter(url: folder.appendingPathComponent("them.wav")),
            ]
            let sink = DispatchQueue(label: "ai.xdigit.dictai.callsink", qos: .userInitiated)

            // The file does not exist yet; live results wait on the sink until it does.
            let fileBox = FileBox()
            let liveOK = await env.liveAssetsReady()
            header.liveUnavailable = !liveOK
            var live: [Speaker: LiveTranscribing] = [:]
            if liveOK {
                for speaker in Speaker.allCases {
                    let transcriber = env.makeLive(speaker)
                    do {
                        try await transcriber.start { result in
                            sink.async {
                                let text = TranscriptCleaner.clean(result.text, confidence: result.confidence)
                                try? fileBox.file?.append(speaker: result.speaker, at: result.start, text: text)
                            }
                        }
                        live[speaker] = transcriber
                    } catch {
                        DebugLogger.log("Live transcriber \(speaker.rawValue) failed to start: \(error)", subsystem: "Calls")
                    }
                }
            }

            let capture = env.makeCapture()
            capture.onAudio = { [live] speaker, buffer in
                let samples = buffer.monoSamples
                sink.async {
                    try? writers[speaker]?.write(samples)
                    live[speaker]?.append(buffer)
                }
            }
            header.channels = try capture.start(appBundleKey: app?.bundleKey)

            let file = try TranscriptFile.create(in: env.transcriptsFolder(), header: header, timeZone: env.timeZone)
            sink.sync { fileBox.file = file }
            let manifest = SessionManifest(header: header, transcriptPath: file.url.path, appBundleKey: app?.bundleKey)
            try saveManifest(manifest, in: folder)
            active = ActiveRecording(folder: folder, manifest: manifest, file: file, capture: capture,
                                     live: live, writers: writers, sink: sink)
            phase = .recording(started: started, app: app)
            DebugLogger.log("Call recording started: \(title)", subsystem: "Calls")
        } catch {
            warning = "Could not start transcribing: \(error.localizedDescription)"
            DebugLogger.log("Call start failed: \(error)", subsystem: "Calls")
        }
    }

    func stop() async {
        guard let rec = active else { return }
        active = nil
        phase = .idle
        rec.capture.stop()
        await drain(rec.sink)
        for transcriber in rec.live.values { await transcriber.finish() }
        await drain(rec.sink)                     // appends queued by the last live results

        var header = rec.manifest.header
        header.ended = env.now()
        let silentThem = header.channels.contains(.them) && (rec.sink.sync { rec.writers[.them]?.peak ?? 0 }) == 0
        if silentThem {
            header.channels = [.you]
            warning = "No audio came from the call app. Check that DictAI is allowed under System Settings, Privacy & Security, Screen & System Audio Recording."
        }
        rec.sink.sync {
            for writer in rec.writers.values { try? writer.finalize() }
            try? rec.file.finishLiveText()
            try? rec.file.setStatus(.processing)
            rec.file.removeLivePointer()
            rec.file.close()
        }
        var manifest = rec.manifest
        manifest.header = header
        try? saveManifest(manifest, in: rec.folder)
        runFinalization(folder: rec.folder, manifest: manifest)
    }

    // MARK: - Final pass

    private func runFinalization(folder: URL, manifest: SessionManifest) {
        finalizingCount += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finalize(folder: folder, manifest: manifest)
            self.finalizingCount -= 1
        }
        finalizations.append(task)
    }

    func waitForFinalization() async {
        while !finalizations.isEmpty {
            let pending = finalizations
            finalizations.removeAll()
            for task in pending { await task.value }
        }
    }

    private func finalize(folder: URL, manifest: SessionManifest) async {
        let fileURL = URL(fileURLWithPath: manifest.transcriptPath)
        let file = TranscriptFile(url: fileURL)
        var channels: [Speaker: [Float]] = [:]
        for speaker in manifest.header.channels {
            channels[speaker] = try? WAVFile.readSamples(folder.appendingPathComponent("\(speaker.rawValue).wav"))
        }
        do {
            let document = try await FinalPass.render(
                channels: channels, header: manifest.header, using: env.transcriber, timeZone: env.timeZone)
            try file.replaceAtomically(with: document)
            if env.keepAudio() { keepAudio(from: folder, next: fileURL) }
            try FileManager.default.removeItem(at: folder)
            pendingRetries.removeAll { $0 == folder }
            DebugLogger.log("Final transcript written: \(fileURL.lastPathComponent)", subsystem: "Calls")
        } catch {
            DebugLogger.log("Final pass failed: \(error)", subsystem: "Calls")
            var header = manifest.header
            header.status = .endedLiveOnly
            try? file.rewriteHeader(header, timeZone: env.timeZone)
            if !pendingRetries.contains(folder) { pendingRetries.append(folder) }
        }
    }

    private func keepAudio(from folder: URL, next transcript: URL) {
        let base = transcript.deletingPathExtension().path
        for speaker in Speaker.allCases {
            let source = folder.appendingPathComponent("\(speaker.rawValue).wav")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: "\(base).\(speaker.rawValue).wav"))
        }
    }

    func retryPending() async {
        let folders = pendingRetries
        for folder in folders {
            guard let manifest = loadManifest(in: folder) else { continue }
            runFinalization(folder: folder, manifest: manifest)
        }
        await waitForFinalization()
    }

    // MARK: - Recovery and termination

    /// Finishes sessions left behind by a crash or quit.
    func recoverOrphanedSessions() async {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: env.sessionsRoot, includingPropertiesForKeys: nil) else { return }
        for folder in folders where folder.hasDirectoryPath {
            guard var manifest = loadManifest(in: folder) else { continue }
            if manifest.header.ended == nil {
                let samples = (try? WAVFile.readSamples(folder.appendingPathComponent("you.wav")))?.count ?? 0
                manifest.header.ended = manifest.header.started.addingTimeInterval(Double(samples) / 16_000)
            }
            if !fm.fileExists(atPath: manifest.transcriptPath) {
                var header = manifest.header
                header.status = .processing
                _ = try? TranscriptFile.create(at: URL(fileURLWithPath: manifest.transcriptPath), header: header, timeZone: env.timeZone)
            }
            runFinalization(folder: folder, manifest: manifest)
        }
        await waitForFinalization()
    }

    /// Called from applicationWillTerminate. Synchronous: leaves everything on disk for recovery.
    func handleTermination() {
        detector?.stopMonitoring()
        guard let rec = active else { return }
        active = nil
        rec.capture.stop()
        rec.sink.sync {
            for writer in rec.writers.values { try? writer.finalize() }
            try? rec.file.finishLiveText()
            try? rec.file.setStatus(.processing)
            rec.file.removeLivePointer()
            rec.file.close()
        }
        var manifest = rec.manifest
        manifest.header.ended = env.now()
        try? saveManifest(manifest, in: rec.folder)
    }

    // MARK: - Helpers

    private func saveManifest(_ manifest: SessionManifest, in folder: URL) throws {
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
    }

    private func loadManifest(in folder: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }

    func drainForTesting() async {
        guard let rec = active else { return }
        await drain(rec.sink)
    }

    /// The calendar event happening now, or starting within 5 minutes.
    static func currentCalendarEventTitle() -> String? {
        let now = Date()
        let events = CalendarIntegration.shared.getTodayEvents()
        let event = events.first { $0.startDate <= now && $0.endDate >= now }
            ?? events.first { (0...300).contains($0.startDate.timeIntervalSince(now)) }
        guard let title = event?.title, !title.isEmpty else { return nil }
        return title
    }
}

/// Lets live results that arrive before the transcript file exists be written once it does.
/// Only read and written on the sink queue.
nonisolated private final class FileBox: @unchecked Sendable {
    var file: TranscriptFile?
}
```

Two notes for the implementer:
- `CalendarIntegration.shared` must exist. Check with `grep -n 'static let shared' Talk/Talk/Integrations/CalendarIntegration.swift`. If it is missing, use how `MeetingState` used it before Task 1 (`CalendarIntegration.shared.getTodayEvents()` compiled there, so it exists).
- Results that arrive before `fileBox.file` is set are dropped by the `try?` on a nil file. That window is only the few milliseconds between `capture.start` and file creation, and the final pass covers it.

- [ ] **Step 6: Add a placeholder prompt panel so the session compiles**

`CallSession.callDetected` uses `CallPromptPanel`, which Task 11 builds. Create `Talk/Talk/CallTranscript/Views/CallPromptPanel.swift` now with its real interface; Task 11 fills in the view:

```swift
import AppKit
import SwiftUI

@MainActor
final class CallPromptPanel {
    static let shared = CallPromptPanel()

    func show(app: CallApp, onAnswer: @escaping (Bool) -> Void) {}
    func dismiss() {}
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run with `<Suite>` = `CallSessionTests`.
Expected: 7 tests pass. Then run the full suite.

- [ ] **Step 8: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk/Talk/CallTranscript Talk/TalkTests/CallTestSupport.swift Talk/TalkTests/CallSessionTests.swift
git commit -q -m "Add CallSession: live streaming, final pass, recovery, termination

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 11: UI and app wiring

**Files:**
- Modify: `Talk/Talk/CallTranscript/Views/CallPromptPanel.swift` (real panel)
- Create: `Talk/Talk/CallTranscript/Views/CallTranscriptSettingsTab.swift`
- Modify: `Talk/Talk/MenuBar/MenuBarView.swift`, `Talk/Talk/Views/SettingsView.swift`, `Talk/Talk/TalkApp.swift`, `Talk/Talk/AppDelegate.swift`
- Modify: `Talk/Talk.xcodeproj/project.pbxproj` (Info.plist keys)

**Interfaces:**
- Consumes: `CallSession`, `CallSettings`, `CallApp`, `TranscriptRenderer.timestamp`, `PermissionManager.shared.openScreenRecordingSettings()`.

UI has no automated tests; verification is a build plus the manual checks in Step 9.

- [ ] **Step 1: Write the prompt panel**

Replace `Talk/Talk/CallTranscript/Views/CallPromptPanel.swift` with:

```swift
import AppKit
import SwiftUI

/// "Transcribe this call?" panel. Non activating, so it never takes focus from the call app.
@MainActor
final class CallPromptPanel {
    static let shared = CallPromptPanel()

    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    func show(app: CallApp, onAnswer: @escaping (Bool) -> Void) {
        dismiss()
        var answered = false
        let answer: (Bool) -> Void = { [weak self] accepted in
            guard !answered else { return }
            answered = true
            self?.dismiss()
            onAnswer(accepted)
        }
        let view = CallPromptView(appName: app.name, onTranscribe: { answer(true) }, onDismiss: { answer(false) })

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: view)
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 356, y: frame.maxY - 92))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { answer(false) }
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CallPromptView: View {
    let appName: String
    let onTranscribe: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.and.waveform.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribe this call?")
                    .font(.headline)
                Text(appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not now", action: onDismiss)
            Button("Transcribe", action: onTranscribe)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .frame(width: 340, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Write the settings tab**

`Talk/Talk/CallTranscript/Views/CallTranscriptSettingsTab.swift`:

```swift
import AppKit
import SwiftUI

struct CallTranscriptSettingsTab: View {
    @AppStorage(CallSettings.folderKey) private var folderPath = CallSettings.defaultFolder.path
    @AppStorage(CallSettings.autoDetectKey) private var autoDetect = true
    @AppStorage(CallSettings.keepAudioKey) private var keepAudio = false

    var body: some View {
        Form {
            Section("Transcripts folder") {
                HStack {
                    Text(folderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                    Button("Open") { NSWorkspace.shared.open(CallSettings.folderURL) }
                }
                Text("Each call is saved as a Markdown file here. While a call is being transcribed, _live.md in this folder points to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calls") {
                Toggle("Offer to transcribe when a call starts", isOn: $autoDetect)
                Toggle("Keep call audio next to transcripts", isOn: $keepAudio)
            }

            Section("Permissions") {
                Text("The first call asks for System Audio Recording permission, which lets DictAI hear the other side of the call. If you declined it, allow DictAI under Privacy & Security, Screen & System Audio Recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    PermissionManager.shared.openScreenRecordingSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = CallSettings.folderURL
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
```

- [ ] **Step 3: Add the Calls tab to SettingsView**

In `Talk/Talk/Views/SettingsView.swift`, insert before `ClipboardSettingsTab()`:

```swift
            CallTranscriptSettingsTab()
                .tabItem {
                    Label("Calls", systemImage: "phone.and.waveform")
                }

```

- [ ] **Step 4: Add the call section to the menu bar**

In `Talk/Talk/MenuBar/MenuBarView.swift`:

1. After `@EnvironmentObject var whisperState: WhisperState`, add `@EnvironmentObject var callSession: CallSession`.
2. In `body`, after the status section's `Divider().padding(.vertical, 8)`, insert:

```swift
            // Call transcripts
            callSection

            Divider()
                .padding(.vertical, 8)

```

3. Before `// MARK: - Mode Section`, add:

```swift
    // MARK: - Call Section

    private var callSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch callSession.phase {
            case let .recording(started, app):
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Transcribing \(app?.name ?? "call") · \(TranscriptRenderer.timestamp(context.date.timeIntervalSince(started)))")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Stop") {
                        Task { await callSession.stop() }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.red.opacity(0.08))
                .cornerRadius(6)
            case .idle:
                Button {
                    Task { await callSession.startManually() }
                } label: {
                    Label("Transcribe Call", systemImage: "phone.and.waveform")
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }

            if callSession.finalizingCount > 0 {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Finishing transcript…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let warning = callSession.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !callSession.pendingRetries.isEmpty {
                Button("Retry final transcript") {
                    Task { await callSession.retryPending() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            Button {
                NSWorkspace.shared.open(CallSettings.folderURL)
            } label: {
                Label("Open Transcripts Folder", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }

```

4. In `#Preview`, add `.environmentObject(CallSession.shared)`.

- [ ] **Step 5: Wire CallSession into the app**

In `Talk/Talk/TalkApp.swift`:
1. After `@StateObject private var hotkeyManager = HotkeyManager.shared`, add `@StateObject private var callSession = CallSession.shared`.
2. In the `MenuBarExtra` content, after `.environmentObject(whisperState)`, add `.environmentObject(callSession)`.
3. Change the label to `MenuBarIcon(isRecording: appState.isRecording, isCallRecording: callSession.isRecording)`.

In `Talk/Talk/AppDelegate.swift`:
1. After the clipboard history block in `applicationDidFinishLaunching`, add:

```swift
        // Call transcripts: detect calls and finish any transcript left by a crash.
        CallSession.shared.bootstrap()
```

2. In `applicationWillTerminate`, after `ClipboardManager.shared.stop()`, add:

```swift
        CallSession.shared.handleTermination()
```

- [ ] **Step 6: Add the Info.plist usage descriptions**

```bash
cd /Users/ak/code/DictAI/Talk
python3 - <<'EOF'
p = 'Talk.xcodeproj/project.pbxproj'
s = open(p).read()
anchor = 'INFOPLIST_KEY_NSMicrophoneUsageDescription = "DictAI needs microphone access to record your voice for transcription.";'
add = anchor + '\n\t\t\t\tINFOPLIST_KEY_NSAudioCaptureUsageDescription = "DictAI records the other side of your calls so it can transcribe them on your Mac.";' \
      + '\n\t\t\t\tINFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "DictAI transcribes your calls on your Mac.";'
assert s.count(anchor) == 2, s.count(anchor)
open(p, 'w').write(s.replace(anchor, add))
EOF
grep -c 'NSAudioCaptureUsageDescription' Talk.xcodeproj/project.pbxproj
```

Expected: `2`.

- [ ] **Step 7: Build and confirm the keys reached Info.plist**

```bash
cd /Users/ak/code/DictAI/Talk && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build 2>&1 | grep -E "error:|BUILD" | tail -5
plutil -p /tmp/TalkBuild/Build/Products/Debug/DictAI.app/Contents/Info.plist | grep -E 'NSAudioCapture|NSSpeechRecognition'
```

Expected: `** BUILD SUCCEEDED **` and both keys printed.

If a key is missing, Xcode does not support it as an `INFOPLIST_KEY_` setting. Then create `Talk/Talk/Info.plist` containing only the missing keys, set `INFOPLIST_FILE = Talk/Info.plist;` next to `GENERATE_INFOPLIST_FILE = YES;` in both app configurations, remove the unsupported `INFOPLIST_KEY_` lines, and rebuild. Xcode merges the file with the generated keys.

- [ ] **Step 8: Run the full suite**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Manual smoke test**

```bash
pkill -x DictAI 2>/dev/null; open /tmp/TalkBuild/Build/Products/Debug/DictAI.app
```

Check, and write the results in the task report:
1. Menu bar shows **Transcribe Call** and **Open Transcripts Folder**. Settings has a **Calls** tab.
2. Start a FaceTime or Zoom test call. Within about 3 s the **Transcribe this call?** panel appears without taking focus.
3. Click **Transcribe**. `~/Documents/DictAI Transcripts/_live.md` exists; `tail -f` on it shows lines within about 2 s of each pause.
4. End the call. About 10 s later the header shows `processing`, then `final`.

- [ ] **Step 10: Commit**

```bash
cd /Users/ak/code/DictAI
git add Talk
git commit -q -m "Add call transcript UI: prompt panel, menu bar section, Calls settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

### Task 12: Whisper end to end test, docs and spec update

**Files:**
- Modify: `Talk/TalkTests/CallEndToEndTests.swift` (final pass test)
- Modify: `README.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-09-29-call-transcripts-design.md`

**Interfaces:**
- Consumes: `WhisperContext.createContext(path:)`, `WhisperContext.transcribeSegments`, `WhisperState.shared.modelURL`, `FinalPass`, `ScriptedCall`, `wordAccuracy`.

- [ ] **Step 1: Add the Whisper final pass end to end test**

Inside `struct CallEndToEndTests`, add:

```swift
    /// Uses the app's downloaded Whisper model directly, without WhisperState.
    struct ContextTranscriber: UtteranceTranscribing {
        let context: WhisperContext
        func transcribe(samples: [Float], prompt: String?) async throws -> [WhisperSegment] {
            guard let segments = await context.transcribeSegments(samples: samples, initialPrompt: prompt, beamSize: 5) else {
                throw FakeError.failed
            }
            return segments
        }
    }

    @MainActor
    @Test func finalPassOnScriptedCall() async throws {
        let modelPath = WhisperState.shared.modelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "No Whisper model at \(modelPath)")
        let context = try await WhisperContext.createContext(path: modelPath)
        let call = try ScriptedCall.make()
        var header = sampleHeader()
        header.ended = sampleStart.addingTimeInterval(seconds(call.you.count))
        let doc = try await FinalPass.render(
            channels: [.you: call.you, .them: call.them], header: header,
            using: ContextTranscriber(context: context), timeZone: utc)

        let youText = doc.components(separatedBy: "**You** · ").dropFirst()
            .map { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? "" }.joined(separator: " ")
        let themText = doc.components(separatedBy: "**Them** · ").dropFirst()
            .map { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? "" }.joined(separator: " ")
        #expect(wordAccuracy(expected: call.youText, actual: youText) >= 0.9, "You: \(youText)")
        #expect(wordAccuracy(expected: call.themText, actual: themText) >= 0.9, "Them: \(themText)")
        #expect(!doc.contains("BLANK_AUDIO"))
        #expect(doc.lowercased().contains("next week"))

        // Turns alternate You, Them, You, Them, You, Them.
        let order = doc.components(separatedBy: "\n").compactMap { line -> String? in
            line.hasPrefix("**You**") ? "you" : line.hasPrefix("**Them**") ? "them" : nil
        }
        #expect(order == ["you", "them", "you", "them", "you", "them"])
    }
```

The `youText` and `themText` extraction keeps only each turn's text line: after splitting on the heading marker, each piece is `00:00:00\ntext\n...`, and the part after the first newline is the text. Because the next heading was used as the split point, trailing blank lines do not affect word accuracy.

- [ ] **Step 2: Run the end to end suite**

Run the Task 7 Step 3 command.
Expected: both `liveTranscriberHearsBothChannels` and `finalPassOnScriptedCall` pass.

AppDelegate notes that booting whisper and Metal inside the test host can abort at process exit (`ggml_metal_rsets_free`). If the test passes but the run reports a crash after the last test, record it in the task report. The end to end suite is opt in, so this does not affect the normal suite.

- [ ] **Step 3: Document the agent contract in the README**

In `README.md`, in the Features list, add this bullet directly after the bullet that starts with `- **Clipboard history.**`:

```markdown
- **Call transcripts.** When Zoom, Teams, Meet or another call app starts, DictAI offers to transcribe the call on your Mac. The transcript is written live to a Markdown file, then replaced with a more accurate final version when the call ends.
```

Add this section after the `## Usage` section:

````markdown
## Call transcripts

Transcripts are saved in `~/Documents/DictAI Transcripts/` (change it in **Settings → Calls**), one file per call, named `YYYY-MM-DD HHMM <title>.md`. The title comes from your calendar when a meeting is on, otherwise from the call app.

Your side is labeled **You** and everyone else is **Them**. The text is cleaned but never reworded: filler sounds, stutters and speech engine artifacts are removed, nothing else.

### Reading transcripts from agents

- While a call is being transcribed, `_live.md` in the transcripts folder is a symlink to its file. It disappears when the call ends.
- The file starts with YAML front matter. Its `status` field moves through:
  - `live`: the call is in progress. Text is only ever appended at the end, so `tail -f` works.
  - `processing`: the call has ended and the final transcript is being made.
  - `final`: the file was replaced by the final version. Read it again in full.
  - `ended-live-only`: the final pass failed. The live text is the result.
- `channels: you` means the other side could not be recorded (check System Audio Recording permission).

```bash
tail -f ~/Documents/DictAI\ Transcripts/_live.md
```
````

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, in the project structure tree, add after the `Processing/` block:

```
│   ├── CallTranscript/
│   │   ├── CallSession.swift      # Coordinator: capture, live file, final pass, recovery
│   │   ├── CallDetector.swift     # Detects call apps using the mic
│   │   ├── CallAudioCapture.swift # Mic (echo cancelled) + ProcessTap (call app audio)
│   │   ├── LiveTranscriber.swift  # Apple SpeechTranscriber, streams the live file
│   │   ├── FinalPass.swift        # Whisper re-transcription after the call
│   │   ├── TranscriptCleaner.swift # Cleaning rules (no rewording)
│   │   └── TranscriptFile.swift   # The only writer of transcript files
```

Under `## Permissions Required`, add:

```
- **System Audio Recording** - For recording the other side of calls (asked on first call)
```

Under `## Development Commands`, add:

```bash
# Tests without a development certificate
cd Talk && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme DictAI \
  -destination 'platform=macOS' -only-testing:TalkTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

# End to end call tests (real speech engines), add DICTAI_E2E=1
```

- [ ] **Step 5: Write the spec deltas back into the spec**

In `docs/superpowers/specs/2026-09-29-call-transcripts-design.md`:
1. Change `**Status:**` to `Implemented`.
2. Add a section at the end titled `## Changes made during planning` containing the ten numbered items from this plan's "Spec deltas decided while planning", copied verbatim.
3. In the TranscriptCleaner layout rule, replace `remove spaces before \`, . ? ! ; :\`, ensure one space after them, and capitalize` with `remove spaces before \`, . ? ! ; :\` and capitalize`.

- [ ] **Step 6: Run the full suite one last time**

Expected: `** TEST SUCCEEDED **`, end to end and hardware suites skipped.

- [ ] **Step 7: Commit**

```bash
cd /Users/ak/code/DictAI
git add README.md CLAUDE.md docs/superpowers/specs/2026-09-29-call-transcripts-design.md Talk/TalkTests/CallEndToEndTests.swift
git commit -q -m "Add Whisper end to end test and document call transcripts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LnWSkagBVscH9BQuPctVZp"
```

---

## Manual verification before release (for the user)

1. A real Zoom or Meet call **with headphones**: both sides present, in order, labeled correctly.
2. The same **on speakers**: the You channel does not repeat what Them said (echo cancellation). Note whether other apps got quieter during the call.
3. **Force quit** DictAI mid call (`pkill -9 -x DictAI`), relaunch: a final transcript appears.
4. `tail -f "~/Documents/DictAI Transcripts/_live.md"` during a call shows lines within about 2 s of each pause.
