# DictAI Pro

**Voice dictation with local AI transcription and auto-paste**

DictAI Pro is a macOS menu bar app that transcribes your voice and automatically pastes the text wherever your cursor is. All transcription happens locally on your Mac using Whisper - your audio never leaves your device.

## Download

**[Download the latest DictAI Pro](https://github.com/XDigit-ai/DictAI/releases/latest/download/DictAI-Pro.dmg)**

*Requires macOS 14.0 or later*

## Features

- **Local Transcription** - Uses Whisper AI locally, no cloud required
- **Auto-Paste** - Text appears instantly at your cursor
- **AI Enhancement** - Optional grammar and punctuation cleanup with Ollama, Claude, or OpenAI
- **Global Hotkey** - Hold Right Command to record, release to transcribe
- **Privacy-First** - Your voice data stays on your Mac

## Installation

1. Download the DMG file above
2. Open the DMG and drag DictAI to Applications
3. **First launch:** Open DictAI from Applications. It is signed and notarized by Apple, so no security workaround is needed.
4. Grant permissions when prompted:
   - **Microphone** - For recording your voice
   - **Accessibility** - For pasting text at cursor

## Usage

1. Click the waveform icon in your menu bar to access settings
2. Hold **Right Command** (or your chosen hotkey) and speak
3. Release the key - your speech is transcribed and pasted automatically

## AI Enhancement (Optional)

For smarter text cleanup, install [Ollama](https://ollama.com):

```bash
# Install Ollama
brew install ollama

# Download a model (in the app: Settings → Enhancement → Download Models)
ollama pull qwen2.5:3b
```

## Privacy

DictAI Pro processes all audio locally. We only collect your email (optional) to send product updates. See our [Privacy Policy](PRIVACY.md).

## Support

Questions or issues? [Open an issue on GitHub](https://github.com/akoneshot/talk/issues)

---

Made with care by [XD.AI](https://xd.ai)
