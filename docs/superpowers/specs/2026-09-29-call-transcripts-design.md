# Call Transcripts: Design

**Date:** 2026-09-29
**App:** DictAI (macOS menu bar dictation app)
**Status:** Implemented
**Replaces:** the Meeting feature (`Talk/Talk/Meeting/`)

## Summary

Replace the Meeting feature with a lean call transcript tool. When another app starts a call,
DictAI offers to transcribe it. Your side (mic) and their side (the call app's audio) are
transcribed on device, cleaned without rewording, and streamed into a Markdown file as people
speak, so local agents can follow the call almost live.

Two engines, each doing what it is best at:

- **Live:** Apple's SpeechAnalyzer with SpeechTranscriber (macOS 26), which is built for
  streaming long form audio. It writes the live file.
- **Final:** Whisper (the model selected in Settings, large-v3-turbo by default). When the call
  ends, it transcribes the full recording with complete context and replaces the file with the
  final version.

DictAI already requires macOS 26.1, so both engines are available to every user.

## Why the current Meeting feature is being replaced

Findings from reviewing the code on 2026-09-29. All 31 unit tests pass, but none cover capture,
chunking, transcription or saving.

1. Default capture is microphone only (`MeetingState.swift:33`). With headphones, the other
   participants are never recorded.
2. The last chunk is dropped. `ChunkedTranscriber.stop()` dispatches the final transcription in
   a detached task, and `finalizeTranscription()` snapshots `liveSegments` without waiting
   (`ChunkedTranscriber.swift:42,83`, `MeetingState.swift:268`). Up to 30 s is lost per call.
3. Audio is cut on a 30 s wall clock timer with no overlap, often mid word. The overlap
   dedup logic assumes an overlap that does not exist (`ChunkedTranscriber.swift:33,49`).
4. Conversation order is lost. Each window yields one "me" block and one "other" block with the
   same start time, appended in whichever order Whisper finishes (`ChunkedTranscriber.swift:52-80`).
5. Voice detection averages RMS over a whole 30 s chunk, and Whisper silence hallucinations
   ("Thank you.", `[BLANK_AUDIO]`) are never filtered (`ChunkedTranscriber.swift:19,70`).
6. Mic resampling from 48 kHz to 16 kHz is naive linear interpolation with no anti aliasing
   (`MeetingAudioEngine.swift:143`). On speakers, the mic also records the other side.
7. Output lives only in SwiftData. The only "cleaning" is LLM notes, which summarize and rewrite.
8. Each save creates a throwaway `ModelContext` (`MeetingState.swift:100,313`), so edits after
   the first insert may never persist (suspected, not verified).

## Goals

- Capture both sides of a call on device: **You** (mic) and **Them** (the call app's audio).
- Offer to transcribe automatically when a call starts; stop automatically when it ends.
- Stream a cleaned transcript into a Markdown file during the call, append only, with a delay
  of about 1 to 2 s after each speaker pauses.
- After the call, replace the file with a higher accuracy final version, atomically.
- Clean without altering: remove non-speech junk, fillers and stutters, and tidy layout. Never
  add, reword, reorder or summarize.
- Never lose a transcript to a crash: audio is kept on disk until the final file is written.
- Give agents a stable, documented contract for finding and reading live transcripts.

## Non-goals (YAGNI)

- No meeting window, live transcript view, bookmarks, jotted notes or LLM notes.
- No LLM involvement in transcripts at all.
- No identification of individual remote speakers. Everyone on the far side is **Them**.
- English only. No language detection.
- No `.txt` output, only `.md`.
- No editable list of call apps in Settings.
- No migration of meetings stored by the old feature. The old SwiftData store file is left
  untouched on disk; it is not deleted.
- No network API or MCP server for agents in this version. Agents read files.

## User facing behaviour

### Starting and stopping

- When a known call app takes the microphone for 3 s, a small non activating panel appears:
  "Transcribe this call? (Zoom)" with **Transcribe** and **Not now**. It does not steal focus.
  It dismisses itself after 30 s with no recording.
- Known call apps (by bundle ID): Zoom, Microsoft Teams (new and classic), Slack, FaceTime,
  Webex, Discord, WhatsApp, Google Chrome, Safari, Arc, Microsoft Edge, Firefox, Brave.
  Browsers are included because Google Meet runs in them.
- Recording stops automatically 10 s after the call app releases the microphone, or when the
  user clicks **Stop** in the menu bar.
- The menu bar menu gains: **Transcribe Call** (manual start), **Stop Transcribing (mm:ss)**
  while recording, and **Open Transcripts Folder**. The menu bar icon shows a recording state.
- Manual start works for any app. If no call app is detected, the title is "Call".

### Settings

A **Call Transcripts** section replaces the Meeting tab:

| Setting | Default |
|---|---|
| Transcripts folder | `~/Documents/DictAI Transcripts/` |
| Offer to transcribe when a call starts | On |
| Keep call audio next to transcripts | Off |
| System Audio Recording permission status, with a button to grant it | |

### The transcript file

Path: `<folder>/YYYY-MM-DD HHMM <title>.md`. The title is the calendar event that overlaps the
current time (reusing `CalendarIntegration`), else `<App name> call`. Characters that are
invalid in file names are replaced with a space. On a name collision, ` (2)`, ` (3)` and so on
is appended.

```markdown
---
title: Weekly sync with Sara
app: Zoom
started: 2026-09-29T14:30:05+04:00
ended: 2026-09-29T15:02:41+04:00
duration: 00:32:36
channels: you, them
language: en
status: final
---

# Weekly sync with Sara

**You** · 00:00:04
So I looked at the numbers from last week and the drop is mostly on mobile.

**Them** · 00:00:11
Right, that matches what support saw. Can you send me the breakdown?
```

- `ended` and `duration` are present only once the call has ended.
- Timestamps are `HH:MM:SS` from the start of recording.
- `channels` is `you, them`, or `you` when system audio could not be captured.
- `live: unavailable` is added only when the live engine could not run (see LiveTranscriber).
  The body then stays empty until the final pass.

### Agent contract

Documented in the README.

- While a call is being transcribed, `<folder>/_live.md` is a symlink to its transcript file.
  It is removed when the call ends.
- `status` moves through `live` → `processing` → `final`.
  - `live`: the file only grows. New text is appended at the end. Earlier bytes never change,
    except the single `status:` line in the header.
  - `processing`: the call has ended and the final pass is running. The file is unchanged.
  - `final`: the file has been atomically replaced by the final version. Re-read it in full.
  - `ended-live-only`: the final pass failed. The live text is the final result.
- The `status` value is right padded with spaces to 15 characters, the length of the longest
  value `ended-live-only`, so `status: live` is written as `status: live` followed by 11
  spaces. Changing it rewrites the same bytes in place and never shifts the body. This keeps byte
  offsets valid for readers that tail the file.

## Architecture

New code lives in `Talk/Talk/CallTranscript/`. Each unit has one job and is testable alone.

| Unit | File | Responsibility |
|---|---|---|
| `CallDetector` | `CallDetector.swift` | Watch Core Audio for processes running audio input; emit `callStarted(app)` after 3 s and `callEnded` after 10 s of release. Ignore DictAI's own process. |
| `CallAudioCapture` | `CallAudioCapture.swift` | Produce two 16 kHz mono Float streams, `you` and `them`. Write each to a WAV file. |
| `ProcessTap` | `ProcessTap.swift` | Core Audio process tap on the call app's process (macOS 14.2+), used by `CallAudioCapture` for the `them` channel. |
| `LiveTranscriber` | `LiveTranscriber.swift` | One Apple `SpeechAnalyzer` + `SpeechTranscriber` per channel; emits finalized results with time ranges. Behind a `LiveTranscribing` protocol so tests can use a fake. |
| `SpeechSegmenter` | `SpeechSegmenter.swift` | Split a channel's recorded audio into utterances at pauses, for the final pass. Pure logic. |
| `WhisperFinalTranscriber` | `WhisperFinalTranscriber.swift` | Actor. Transcribe final pass utterances one at a time with the shared `WhisperContext`. |
| `TranscriptCleaner` | `TranscriptCleaner.swift` | The four cleaning rules. Pure functions. |
| `TranscriptRenderer` | `TranscriptRenderer.swift` | Turn header data and speaker turns into Markdown text. Pure functions. |
| `TranscriptFile` | `TranscriptFile.swift` | The only writer of transcript files: create, append, update status, atomic replace, `_live.md` symlink. |
| `FinalPass` | `FinalPass.swift` | After the call, transcribe both WAVs fully, merge by time, clean, render. |
| `CallSession` | `CallSession.swift` | `@MainActor` coordinator and state machine; crash recovery at launch. |
| Prompt panel | `Views/CallPromptPanel.swift` | "Transcribe this call?" non activating panel. |
| Settings | `Views/CallTranscriptSettingsView.swift` | The Settings section above. |

### CallDetector

- Uses `kAudioHardwarePropertyProcessObjectList`, and for each process object
  `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID` and
  `kAudioProcessPropertyPID` (macOS 14.2+). Listens for property changes rather than polling;
  falls back to a 1 s poll if listeners are not delivered.
- Only processes whose bundle ID is in the known call app list trigger the prompt.
- The Core Audio calls sit behind a small `AudioProcessSource` protocol so tests can drive the
  detector with a fake.
- States: `idle` → `candidate(app, since)` → `inCall(app)` → `releasing(since)` → `idle`.

### CallAudioCapture

- **You:** `AVAudioEngine` input node with `setVoiceProcessingEnabled(true)` for echo
  cancellation, and ducking of other audio set to the minimum.
- **Them:** `ProcessTap` on the detected call app's PID, via `CATapDescription` and
  `AudioHardwareCreateProcessTap`, read through an aggregate device. On a manual start with no
  detected app, the tap covers all system output except DictAI.
- Each channel is converted with `AVAudioConverter` twice: to 16 kHz mono for the WAV file
  (Whisper's format), and to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` for the
  live transcriber.
- Requires `NSAudioCaptureUsageDescription` in Info.plist. If the tap cannot be created
  (permission denied or any error), capture continues with `you` only and the header shows
  `channels: you`.
- Each channel's converted audio goes to a `WAVWriter` (16 bit PCM) in the session folder and to
  that channel's `LiveTranscriber` input stream. Audio callbacks never block. Hand off is through
  a lock protected ring buffer drained on a dedicated serial queue.

### LiveTranscriber

- One `SpeechAnalyzer` per channel, each with a `SpeechTranscriber` for `en-US`, reporting only
  finalized results (no volatile results, so nothing written is ever retracted), with the
  `audioTimeRange` and `transcriptionConfidence` attributes enabled.
- Audio is fed as `AnalyzerInput` buffers through an `AsyncStream`.
- Each finalized result becomes `LiveResult(channel, start, text, confidence)`, where `start` is
  the result's audio time range start, counted from the start of recording. It goes to
  `TranscriptCleaner`, then `TranscriptFile.append(speaker:, at:, text:)`.
- `finish()` calls `finalizeAndFinishThroughEndOfInput()` and awaits the last results.
  `CallSession` awaits both channels' `finish()` before changing the status to `processing`,
  which fixes finding 2.
- The speech model is a system asset. On first use, `AssetInventory` installs it, with progress
  shown in the menu bar. If it cannot be installed (for example offline on first use), the call
  is still recorded, the header shows `live: unavailable`, the body stays empty, and the final
  pass produces the transcript as usual.

### SpeechSegmenter

Used by the final pass to cut each recorded channel into utterances. Processes 30 ms frames:

- Keeps an adaptive noise floor: a slow moving average of frame energy during non speech.
- A frame is speech when its energy exceeds `max(noiseFloor × 3, 0.002)`.
- An utterance starts after 150 ms of speech, and includes 300 ms of pre roll.
- It ends after 700 ms of non speech, and includes 200 ms of post roll.
- Utterances shorter than 400 ms are discarded.
- Utterances are capped at 28 s, just under Whisper's 30 s window. At the cap, the cut goes at
  the quietest frame in the last 3 s.
- Utterances less than 1 s apart are merged, as long as the result stays under the cap.
- Output: `Utterance(channel, startSample, samples)`. Sample offsets are counted from the start
  of recording, so timestamps stay exact.

### WhisperFinalTranscriber

- An actor that transcribes utterances strictly in order.
- Whisper parameters: beam search with beam size 5, `language = "en"`, `no_speech_thold = 0.6`
  (Whisper drops segments it judges to be silence), `suppress_blank`, `suppress_nst`, threads
  set to cores minus 2, and `initial_prompt` set to the last 200 characters of cleaned text
  from the same channel. The prompt is context only; it is never written to the file.
- Each Whisper segment yields text, absolute start time (segment `t0` plus the utterance
  offset) and a confidence: the mean of its tokens' `p` values from
  `whisper_full_get_token_data`.
- The dictation pipeline shares `WhisperContext`. Both go through the actor, so a dictation
  request waits at most for the utterance currently being transcribed.

### TranscriptCleaner

Rules run in this order on each utterance's text. Anything ambiguous is left unchanged.

1. **Junk**
   - Remove non speech tags from a fixed list, in square brackets or parentheses, matched
     case insensitively: `BLANK_AUDIO`, `MUSIC`, `NOISE`, `SILENCE`, `APPLAUSE`, `LAUGHTER`,
     `INAUDIBLE`, and phrases ending in "music".
   - Drop the whole utterance when it consists only of a known hallucination phrase:
     "thanks for watching", "thank you for watching", "please subscribe",
     "subtitles by …", "like and subscribe".
   - Drop a lone "Thank you." or "Bye." only when its confidence is below 0.5 (Apple's
     `transcriptionConfidence` live, mean token probability in the final pass). With no
     confidence available, keep it.
   - Reduce a sentence repeated 3 or more times in a row to one copy.
2. **Fillers**
   - Remove standalone `um`, `umm`, `uh`, `uhh`, `er`, `erm`, `ah`, `hmm`, case insensitive,
     together with an attached comma.
   - Kept: `mm-hmm`, `uh-huh`, `like`, `you know`, `so`, `well`.
3. **Stutters**
   - Collapse exact immediate repeats of a 1 to 3 word sequence, case and punctuation
     insensitive: "I I I think" becomes "I think"; "we should we should go" becomes
     "we should go".
   - Exceptions kept as spoken: `that that`, `had had`.
4. **Layout**
   - Collapse runs of whitespace, remove spaces before `, . ? ! ; :`, and
     capitalize the first letter of the utterance and of each sentence.
   - No word is added, removed or reordered by this rule.

If cleaning leaves an empty string, nothing is written. The junk rules mostly matter for the
final pass; Apple's live engine does not produce Whisper style hallucinations, but the same
cleaner runs on both so the rules are consistent.

### TranscriptFile

- `create(header:)` writes the header and title with `status: live` padded, and creates the
  `_live.md` symlink. An existing `_live.md` is replaced.
- `append(speaker:, at:, text:)`:
  - Same speaker as the last written turn: appends `" " + text` to the current paragraph.
  - Otherwise: appends a blank line, `**You** · HH:MM:SS` or `**Them** · HH:MM:SS`, a newline
    and the text.
  - Uses a `FileHandle` opened for append, and calls `synchronize()` after each append so
    readers see complete lines.
- `setStatus(_:)` overwrites the padded status value in place.
- `replaceAtomically(with:)` writes to a temporary file in the same folder, then uses
  `FileManager.replaceItemAt` over the transcript.
- `removeLivePointer()` deletes `_live.md` when it points at this file.

Live append order is the order utterances finish transcription. When the two sides talk over
each other, a short interjection can appear before the end of a longer sentence it
interrupted. The final pass corrects this.

### FinalPass

- Segments each full WAV with `SpeechSegmenter`, which gives Whisper whole thoughts rather than
  silence, and transcribes the utterances with `WhisperFinalTranscriber`.
- Merges both channels' segments sorted by start time (ties: `you` first), groups consecutive
  same speaker segments into turns, cleans, renders, and calls `replaceAtomically`.
- On success: status `final`, and the session folder is deleted, or its WAVs are moved next to
  the transcript as `<name>.you.wav` and `<name>.them.wav` when "Keep audio" is on.
- On failure: the live file is kept, status `ended-live-only`, and the session folder is kept
  so the final pass can be retried from the menu ("Retry final transcript").

### CallSession

- States: `idle`, `prompting(app)`, `recording(session)`, `finalizing(session)`.
- **Start:**
  1. Make sure the Apple speech asset is installed (see LiveTranscriber). Capture starts
     immediately regardless.
  2. Create the session folder `~/Library/Application Support/DictAI/Sessions/<uuid>/` with
     `session.json` (title, app, start time, transcript path).
  3. Create the transcript file and start capture.
- **Stop:**
  1. Stop capture and close the WAV files.
  2. Await `finish()` on both live transcribers, then status `processing`, and remove
     `_live.md`.
  3. Load the Whisper model if needed, then run `FinalPass` in a background task.
- **Launch recovery:** for each folder in `Sessions/`, run `FinalPass` from its WAVs and
  `session.json`. If its transcript file is missing, create it first.
- **App quit while recording:** stop capture, close the WAV files cleanly and set status
  `processing`. Recovery runs the final pass on the next launch.

## Removals

- All of `Talk/Talk/Meeting/`.
- The SwiftData `ModelContainer` setup and `MeetingState` wiring in `TalkApp.swift`, together
  with any meeting UI entry points in `MenuBarView` and `SettingsView`.
- `WhisperState.transcribeMeetingChunk` and `WhisperContext.transcribeMeeting`, replaced by the
  `WhisperFinalTranscriber` API.
- The SwiftData references in `AppDelegate.swift` that exist only for meetings.
- `MeetingModelTests`, `ChunkedTranscriberTests`, `MeetingNotesGeneratorTests`.

## Platform and permissions

- No deployment target change. The project already targets macOS 26.1, which covers the process
  tap (14.2+), the process object properties (14.2+) and SpeechAnalyzer (26.0+).
- New Info.plist key `NSAudioCaptureUsageDescription`: "DictAI records the other side of your
  calls so it can transcribe them on your Mac."
- Existing: Microphone (required), Calendar (optional, titles only).
- Screen Recording is no longer needed for calls.

## Error handling summary

| Situation | Behaviour |
|---|---|
| System audio permission denied or tap fails | Record `you` only, header `channels: you`, menu bar warning with a link to grant permission |
| Microphone unavailable | Do not start; show an error in the menu bar |
| Apple speech asset missing and cannot be installed | Record anyway; header `live: unavailable`; final pass writes the transcript |
| Live transcriber errors mid call | Log it, restart that channel's analyzer from the current audio; a gap in the live file is filled by the final pass |
| Whisper model not loaded at the end of the call | Load it before the final pass |
| Whisper fails on one utterance in the final pass | Log it and skip that utterance; the rest of the final file is still written |
| Final pass fails | Status `ended-live-only`, keep audio, offer "Retry final transcript" |
| Crash or quit mid call | Audio on disk; final pass runs at next launch |
| Transcripts folder missing or not writable | Recreate it; if that fails, fall back to `~/Documents/DictAI Transcripts/` and warn |

## Testing

Unit tests, all pure or driven by fakes:

- **TranscriptCleaner:** table driven. Includes a must not change set: "I had had enough",
  "mm-hmm, yes", "Thank you." with a low no speech probability, "I like it",
  "that that is true".
- **SpeechSegmenter:** synthetic signals: tone bursts with gaps (expected boundaries and
  timestamps), a 45 s continuous signal (cap and quiet point cut), sub 400 ms blips (dropped),
  a rising noise floor (no false starts), and gaps under 1 s (merged).
- **CallSession live flow:** a fake `LiveTranscribing` emitting scripted results: appends reach
  the file in order, `finish()` is awaited before `processing`, and `live: unavailable` is
  written when the fake reports a missing asset.
- **TranscriptRenderer:** header and turns, including `channels: you`.
- **TranscriptFile:** create, append same and different speaker, in place status update keeps
  the byte length, atomic replace, `_live.md` created, replaced and removed.
- **FinalPass merge:** overlapping You and Them segments come out ordered by time.
- **CallDetector:** fake `AudioProcessSource`: 3 s debounce, 10 s release, ignores DictAI and
  unknown apps.
- **CallSession recovery:** an orphaned session folder with WAVs and `session.json` produces a
  final file.

End to end tests, on a scripted call: two scripts voiced with macOS `say`, written as
`you.wav` and `them.wav` with alternating turns and one overlap.

- **Live path** (skipped when the Apple speech asset is not installed): the WAVs are streamed
  through `LiveTranscriber`, cleaner and `TranscriptFile`. Assertions: word accuracy of at
  least 85%, every turn present, and the last sentence present after `finish()`.
- **Final pass** (skipped when no Whisper model is present): the same WAVs through
  `FinalPass`. Assertions: word accuracy of at least 90%, correct You and Them order, the last
  sentence present, and no `[BLANK_AUDIO]` in the output.

Test runs on machines without a development certificate:

```bash
cd Talk
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme DictAI \
  -destination 'platform=macOS' -only-testing:TalkTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Manual checks before release:

- A real Zoom or Meet call with headphones: both sides present and ordered.
- The same call on speakers: echo cancellation keeps "Them" out of the You channel.
- Force quit DictAI mid call, relaunch: a final file appears.
- `tail -f "<folder>/_live.md"` during a call shows lines appearing within about 2 s of each
  pause.

## Risks

- **Voice processing side effects.** Enabling voice processing on the input node can lower
  other apps' volume or change the mic's sound for the call app. Mitigation: ducking set to
  minimum, verified in the manual speakers check. If it is unacceptable, voice processing
  becomes a setting that defaults to off when headphones are the output device.
- **Process tap on browsers.** Tapping Chrome for Google Meet also captures any other audio
  playing in Chrome during the call. Accepted for this version.
- **Live accuracy.** Apple's live engine may be less accurate than Whisper. Accepted, because
  the final pass replaces the live text; the live end to end test sets the floor at 85%.
- **Two concurrent analyzers.** Running two `SpeechAnalyzer` sessions at once (one per channel)
  must work reliably. Verified in the first implementation task with the scripted call; if it
  does not, the two channels are transcribed by one analyzer taking turns on pauses.

## Changes made during planning

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

## Changes made during implementation

1. Sentence capitalization skips the word after an abbreviation (a word with an inner period such as `U.S.` or `e.g.`, or a single letter), so "the U.S. market" is left unchanged.
2. `NSAudioCaptureUsageDescription` is not a supported `INFOPLIST_KEY_` build setting, so it lives in a partial `Talk/DictAI-Info.plist` merged through `INFOPLIST_FILE`.
3. Call transcript documentation is in `docs/CALL-TRANSCRIPTS.md`.
