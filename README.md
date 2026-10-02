# DictAI

**Voice dictation for macOS with local Whisper transcription and auto-paste.**

DictAI lives in your menu bar. Hold a key, speak, let go, and your words are typed wherever your cursor is. Transcription runs on your Mac with Whisper, so your audio never leaves your device.

## Download

**[Download the latest DictAI (DMG)](https://github.com/XDigit-ai/DictAI/releases/latest/download/DictAI-Pro.dmg)**

Requires macOS 26.1 or later on an Apple Silicon Mac. See [all releases](https://github.com/XDigit-ai/DictAI/releases) for release notes.

## Features

- **Local transcription.** Whisper runs on device with Metal acceleration. No cloud, no internet needed.
- **Paste anywhere.** Text lands at your cursor in any app.
- **Clipboard history.** Press ⌘⌥V to bring back anything you copied or dictated and paste it again.
- **Call transcripts.** When Zoom, Teams, Meet or another call app starts, DictAI offers to transcribe the call on your Mac. A cleaned transcript is written live to a Markdown file, then replaced with a more accurate version when the call ends.
- **Two cleanup modes.** Simple mode strips filler words and repeats. Advanced mode uses an LLM for grammar, punctuation and structure.
- **Your choice of AI.** Local models through Ollama (managed in the app), or Claude and OpenAI with your own API key.
- **Global hotkey.** Hold Right Command to record, or pick another key and switch to toggle mode.

## Install

1. Download the DMG above and open it.
2. Drag **DictAI** into **Applications**.
3. Open DictAI. The app is signed and notarized by Apple, so it opens without security warnings.
4. Grant the permissions it asks for:
   - **Microphone**, to hear you.
   - **Accessibility**, to paste the text for you.

Updating from an earlier version? If pasting stops working, open **System Settings → Privacy & Security → Accessibility**, remove DictAI with the minus button, then add it again.

### Optional: AI enhancement with Ollama

Install [Ollama](https://ollama.com/download), then open **Settings → Enhancement → Download More Models...** to pick a model. DictAI starts Ollama for you when it launches. `qwen2.5:3b` is the default and a good starting point.

## Usage

1. Hold **Right Command** (or your chosen hotkey) and speak.
2. Release the key. Your speech is transcribed, cleaned up and pasted.
3. Click the menu bar icon for settings, models and history.

## Call transcripts

Transcripts are saved in `~/Documents/DictAI Transcripts/`, one Markdown file per call, with your side labeled **You** and everyone else **Them**. The text is cleaned (filler sounds, stutters and speech engine artifacts removed) but never reworded.

The first call asks for **System Audio Recording** permission, which lets DictAI hear the other side of the call. Everything runs on your Mac.

While a call is being transcribed, `_live.md` in that folder points to it, so other tools and AI agents can follow along:

```bash
tail -f ~/Documents/DictAI\ Transcripts/_live.md
```

See [docs/CALL-TRANSCRIPTS.md](docs/CALL-TRANSCRIPTS.md) for the file format and the status values agents should check.

## Build from source

Requires Xcode.

```bash
cd Talk
xcodebuild -scheme DictAI -configuration Debug -derivedDataPath /tmp/TalkBuild build
open /tmp/TalkBuild/Build/Products/Debug/DictAI.app
```

To make a distributable DMG, run `./scripts/build-release.sh`. More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/FEATURES.md](docs/FEATURES.md).

## About me

I'm AK, and I build DictAI at [XD.AI](https://xdigit.ai), where we work on AI-native digital transformation. I made DictAI because I wanted dictation that is fast, private and works in every app, and I use it every day.

- GitHub: [@ak-xdai](https://github.com/ak-xdai)
- Website: [xdigit.ai](https://xdigit.ai)

Feedback and bug reports are welcome in [Issues](https://github.com/XDigit-ai/DictAI/issues).
