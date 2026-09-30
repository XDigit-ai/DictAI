# Talk - Mac Dictation App

A native macOS menu bar app for voice dictation with local Whisper transcription and intelligent text processing.

## Quick Start

```bash
# Build and run (no Xcode GUI needed)
cd Talk
xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build
open /tmp/TalkBuild/Build/Products/Debug/DictAI.app

# Or open in Xcode
open Talk/Talk.xcodeproj
```

## Building whisper.xcframework (if needed)

The whisper.xcframework is already included in `Talk/Talk/whisper.xcframework/`. If you need to rebuild:

```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp && ./build-xcframework.sh
# Copy whisper.xcframework to Talk/Talk/
```

## Project Structure

```
Talk/
├── Talk.xcodeproj/
├── Talk/
│   ├── TalkApp.swift              # @main entry point with MenuBarExtra
│   ├── AppDelegate.swift          # App lifecycle, recording panel, auto-launch Ollama
│   ├── AppState.swift             # Central state management
│   │
│   ├── Core/
│   │   ├── Recorder.swift         # AVAudioRecorder (16kHz, mono, PCM)
│   │   ├── CursorPaster.swift     # CGEvent Cmd+V simulation
│   │   └── SoundManager.swift     # Audio feedback
│   │
│   ├── Whisper/
│   │   ├── WhisperContext.swift   # Actor wrapping whisper.cpp
│   │   └── WhisperState.swift     # Transcription state machine
│   │
│   ├── Processing/
│   │   └── SimpleCleanupProcessor.swift  # Filler word removal
│   │
│   ├── CallTranscript/
│   │   ├── CallSession.swift      # Coordinator: capture, live file, final pass, recovery
│   │   ├── CallDetector.swift     # Detects call apps using the mic
│   │   ├── CallAudioCapture.swift # Mic (echo cancelled) + ProcessTap (call app audio)
│   │   ├── LiveTranscriber.swift  # Apple SpeechTranscriber, streams the live file
│   │   ├── FinalPass.swift        # Whisper re-transcription after the call
│   │   ├── TranscriptCleaner.swift # Cleaning rules (no rewording)
│   │   └── TranscriptFile.swift   # The only writer of transcript files
│   │
│   ├── LLM/
│   │   ├── LLMProvider.swift      # Protocol + LLMProviderType enum
│   │   ├── OllamaManager.swift    # Ollama lifecycle: install detection, auto-launch, model download
│   │   ├── OllamaService.swift    # Ollama API calls
│   │   ├── ClaudeService.swift    # Claude API
│   │   ├── OpenAIService.swift    # OpenAI API
│   │   └── AIEnhancementService.swift  # Provider orchestration
│   │
│   ├── Hotkey/
│   │   └── HotkeyManager.swift    # Global hotkey (Right Cmd)
│   │
│   ├── MenuBar/
│   │   └── MenuBarView.swift      # Menu bar UI
│   │
│   ├── Services/
│   │   └── PermissionManager.swift # Mic + Accessibility permissions
│   │
│   ├── Views/
│   │   ├── MiniRecorderView.swift # Recording overlay
│   │   ├── SettingsView.swift     # Preferences (5 tabs) + ModelBrowserView
│   │   └── PermissionsView.swift  # Onboarding
│   │
│   ├── Assets.xcassets/           # App icons
│   ├── Talk.entitlements          # Entitlements file
│   └── whisper.xcframework/       # Built from whisper.cpp
│
└── docs/
    ├── ARCHITECTURE.md
    ├── DESIGN.md
    ├── FEATURES.md
    └── TODO.md
```

## Key Technologies

- **Swift/SwiftUI** - Native macOS 14.0+ app
- **whisper.cpp** - Local speech-to-text (Metal-accelerated)
- **Ollama** - Local LLM with auto-launch and in-app model management
- **Claude/OpenAI** - Cloud LLM alternatives
- **CGEvent** - Keyboard simulation for paste

## Two Processing Modes

1. **Simple**: Regex-based filler word removal, repeated word cleanup
2. **Advanced**: LLM-powered grammar, punctuation, structure enhancement

## Ollama Integration

The app has full Ollama lifecycle management:
- **Auto-detection**: Checks if Ollama is installed
- **Auto-launch**: Starts Ollama on app launch if installed but not running
- **In-app model browser**: Download recommended models without terminal
- **Model management**: Switch between installed models, delete unused ones

### Recommended Models for Text Enhancement
| Model | Size | Description |
|-------|------|-------------|
| qwen2.5:3b | 1.9 GB | Excellent for text tasks, fast (default) |
| phi3 | 2.2 GB | Microsoft, very fast |
| gemma2:2b | 1.6 GB | Google, lightweight |
| mistral | 4.1 GB | High quality, balanced |
| llama3.2 | 2.0 GB | Meta, good all-around |

## Permissions Required

- **Microphone** - For audio recording
- **Accessibility** - For simulating Cmd+V paste
- **System Audio Recording** - For recording the other side of calls (asked on first call)

## Development Commands

```bash
# Build only
cd Talk
xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build

# Build and run
pkill -9 Talk 2>/dev/null
xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build
open /tmp/TalkBuild/Build/Products/Debug/DictAI.app

# Copy to Desktop for sharing
cp -R /tmp/TalkBuild/Build/Products/Debug/DictAI.app ~/Desktop/

# Clean extended attributes (if code signing fails)
xattr -cr Talk Talk.xcodeproj

# Check if Ollama is running
curl -s http://localhost:11434

# List Ollama models
curl -s http://localhost:11434/api/tags | jq '.models[].name'
```

```bash
# Tests without a development certificate
cd Talk && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme DictAI \
  -destination 'platform=macOS' -only-testing:TalkTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

# End to end call tests (real speech engines): prefix with TEST_RUNNER_DICTAI_E2E=1
# (xcodebuild strips TEST_RUNNER_ and passes DICTAI_E2E=1 to the tests)
```

## Distribution

### Quick Build (for testing)
```bash
cd Talk
xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build
open /tmp/TalkBuild/Build/Products/Debug/DictAI.app
```

### Release Build (for distribution)
```bash
# Build release package (DMG + ZIP)
./scripts/build-release.sh

# Output in dist/ folder:
#   • Talk.app
#   • DictAI-YYYY.MM.DD.dmg (in ~/code/releases/DictAI, outside iCloud)
#   • Talk-YYYY.MM.DD.zip
```

### Notarization (requires Developer ID - $99/year)
```bash
# One-time setup: store Apple ID credentials
xcrun notarytool store-credentials "AC_PASSWORD" \
    --apple-id "your@email.com" \
    --team-id "YOUR_TEAM_ID" \
    --password "xxxx-xxxx-xxxx-xxxx"

# Notarize the DMG
./scripts/notarize.sh
```

### For Recipients (ad-hoc signed builds)
1. Install Ollama from https://ollama.com/download
2. Unzip/mount the DMG
3. Run: `xattr -cr Talk.app` (removes quarantine)
4. Right-click → Open (first time, to bypass Gatekeeper)
5. Grant Microphone + Accessibility permissions
6. Download a model via Settings → Enhancement → "Download More Models..."

### For Recipients (notarized builds)
1. Install Ollama from https://ollama.com/download
2. Mount DMG, drag to Applications
3. Open Talk (no quarantine removal needed)
4. Grant permissions when prompted

## Troubleshooting

### Error -10810 (App won't launch)

If you see `LSOpenURLsWithCompletionHandler() failed with error -10810`:

1. **Remove quarantine attributes**:
   ```bash
   xattr -cr /path/to/Talk.app
   ```

2. **Re-sign the app** (for unsigned builds):
   ```bash
   codesign --force --deep --sign - /path/to/Talk.app
   ```

3. **Check permissions**:
   ```bash
   chmod -R 755 /path/to/Talk.app
   ```

4. **Verify the app bundle**:
   ```bash
   # Check if executable exists
   ls -la /path/to/Talk.app/Contents/MacOS/Talk

   # Test if it's executable
   file /path/to/Talk.app/Contents/MacOS/Talk
   ```

5. **If downloaded from the internet**: macOS may block the app. After `xattr -cr`, right-click and select "Open" to bypass Gatekeeper.

### Menu bar icon not visible

On MacBooks with a notch, the menu bar icon may be hidden when too many apps are running:
- Go to **Settings → General → Show Dock icon** to enable an alternative access point
- This adds a Dock icon you can click to access Talk

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - System design and data flow
- [Design System](docs/DESIGN.md) - UI/UX guidelines
- [Features](docs/FEATURES.md) - Complete feature list
- [TODO](docs/TODO.md) - Remaining tasks and future plans
- [Call Transcripts](docs/CALL-TRANSCRIPTS.md) - Transcript files and the agent contract
