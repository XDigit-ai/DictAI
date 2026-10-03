# DictAI status

Last updated: 2026-10-03. Read this first when picking the project up again.

## Where things stand

- **Latest release:** [v2026.10.02.2-pro](https://github.com/XDigit-ai/DictAI/releases/tag/v2026.10.02.2-pro), signed with the Developer ID and notarized. The website and README download links use `releases/latest/download/DictAI-Pro.dmg`, so they always serve the newest release.
- **Installed:** the same build is in `/Applications/DictAI.app` on AK's Mac Studio.
- **Tests:** 92 unit tests pass. Opt-in suites (real speech engines, audio hardware) are skipped by default; see "Testing" below.

## Done in the 2026-09-29 to 2026-10-03 sessions

1. **Release pipeline fixed.** `scripts/build-release.sh` signs with the Developer ID (or ad hoc without the hardened runtime when no certificate is present). `scripts/notarize.sh` notarizes and staples.
2. **README and website.** README with install, features, call transcripts and About me. GitHub Pages download buttons follow the latest release. macOS requirement corrected to 26.1.
3. **Call transcripts** replaced the old Meeting feature. Spec: `docs/superpowers/specs/2026-09-29-call-transcripts-design.md`. User and agent docs: `docs/CALL-TRANSCRIPTS.md`.
   - Live transcript via Apple SpeechTranscriber, final pass via Whisper, Markdown files in `~/Documents/DictAI Transcripts/`, `_live.md` pointer for agents.
4. **Fixes from the final code review:** dictation/final pass Whisper race (dictation could paste call text), recovery vs model load race, double start, partial start cleanup, double retry, second app on the mic ending a call, cleaner rewording, crash on non-finite timestamps.
5. **Screen Recording dialog loop fixed.** The permission check prompted on every launch; now uses `CGPreflightScreenCaptureAccess()`.
6. **Agent mode removed** (Right Option voice commands, integrations, Agent settings, Apple Events entitlement). A slim read-only `CalendarIntegration` stays for naming call transcripts.
7. **Advanced mode works from the hotkey again.** The hotkey used to force Simple mode; it now follows the selected mode.
8. **Website:** the DictAI page in `xd-website-v2` (`src/content/lab/dictai.md`) was refreshed; PR open in that repo.

## Next

In rough priority order:

1. **Real call check, by hand** (never done on hardware):
   - Zoom or Meet with headphones: prompt appears, `tail -f ~/Documents/DictAI\ Transcripts/_live.md` shows lines within about 2 s, file ends `status: final`.
   - Same call on speakers: You channel does not repeat Them (echo cancellation); note whether other apps get quieter.
   - Connect AirPods mid call, and a call fully on AirPods. Capture does not handle audio route changes yet (open review finding).
   - Force quit mid call, relaunch: final transcript appears.
   - FaceTime, Firefox and Arc calls: check detection and that the Them channel is not silent.
2. **Language setting is ignored.** Settings has a Language picker, but `WhisperContext.transcribe` hardcodes `"en"` (`Talk/Talk/Whisper/WhisperContext.swift`, `transcribe(samples:)`). Fix it, then the website can mention Arabic and other languages again.
3. **Email registration.** On first setup DictAI sends the email (and optional name) to the Supabase project in `Services/UserRegistrationService.swift`. The website now says so. Confirm this is still wanted.
4. **Website PR:** merge it in `xd-website-v2` so Vercel deploys the refreshed DictAI page.
5. **Deferred review findings** (minor):
   - No warning when the system audio tap fails outright; warning has no link; a muted remote side looks like a permission problem.
   - Settings does not show System Audio Recording status; unwritable transcripts folder fallback is only logged.
   - Layout rule joins ".NET" and ".5" onto the previous word.
   - File name limit counts characters, not UTF-8 bytes; `\r` and U+2028 not stripped from titles.
   - Final pass reads whole WAVs on the main actor (about 460 MB per channel for a 2 hour call).
   - Missing or unreadable WAVs count as an empty successful final pass.
   - Live `finish()` has no timeout; a failed live start leaks its results task.
   - After a crash, `_live.md` and `status: live` stay until the next launch.
6. **Housekeeping:**
   - App version still reads 1.0 (build 2); releases are tagged by date.
   - The September 29 release notes still say macOS 14.0 (superseded, not Latest).
   - Autocomplete is a work in progress from July; its state is unknown.
   - `docs/STRATEGIC-EVOLUTION-PLAN.md` describes the agent strategy that was removed.

## How to release

Xcode is installed but `xcode-select` points at the Command Line Tools, so prefix builds with `DEVELOPER_DIR`.

```bash
cd ~/code/DictAI
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/build-release.sh                       # output in ~/code/releases/DictAI/
codesign --force --timestamp --sign "Developer ID Application: Abdulkader Lamaa (QD4JZG5C85)" ~/code/releases/DictAI/DictAI-<date>.dmg
./scripts/notarize.sh                            # keychain profile AC_PASSWORD
# Upload as DictAI-Pro.dmg, mark Latest:
gh release create v<date>-pro DictAI-Pro.dmg --title "DictAI Pro (...)" --notes-file notes.md --latest
```

If notarization says "No Keychain password item found for profile: AC_PASSWORD", save the app specific password again with `xcrun notarytool store-credentials "AC_PASSWORD" --apple-id ak@oneshot.me --team-id QD4JZG5C85 --password ...`.

## Testing

```bash
cd ~/code/DictAI/Talk
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme DictAI \
  -destination 'platform=macOS' -only-testing:TalkTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

- Real speech engine tests: prefix with `TEST_RUNNER_DICTAI_E2E=1` (needs the Whisper model downloaded and Apple's English speech model).
- Audio hardware test: prefix with `TEST_RUNNER_DICTAI_HW=1` (needs System Audio Recording permission, which ad hoc test builds cannot keep).
- Avoid launching extra copies of DictAI (test or debug builds): each gets its own macOS permission entries. If Accessibility looks granted but is not, run `tccutil reset Accessibility ai.xdigit.talk` and grant it again for `/Applications/DictAI.app`.
