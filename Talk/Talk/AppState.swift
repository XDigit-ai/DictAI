import SwiftUI
import Combine

// MARK: - Processing Mode
enum ProcessingMode: String, CaseIterable, Codable {
    case simple = "Simple"
    case advanced = "Advanced"

    var description: String {
        switch self {
        case .simple:
            return "Basic cleanup - removes filler words and repeated words"
        case .advanced:
            return "LLM enhancement - grammar, punctuation, and structure"
        }
    }

    var icon: String {
        switch self {
        case .simple:
            return "wand.and.rays"
        case .advanced:
            return "sparkles"
        }
    }
}

// MARK: - Recording Mode
enum RecordingMode: String, CaseIterable, Codable {
    case pushToTalk = "Push to Talk"
    case toggle = "Toggle"

    var description: String {
        switch self {
        case .pushToTalk:
            return "Hold the hotkey while speaking, release to transcribe"
        case .toggle:
            return "Press to start recording, press again to stop"
        }
    }
}

// MARK: - Live dictation output
enum LiveOutput: String, CaseIterable, Codable {
    /// Each clip is pasted into the app at the cursor as soon as it is transcribed.
    case cursor = "Cursor"
    /// The text so far is shown in the recording overlay; pasted once on release.
    case overlay = "Overlay"
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    // Recording state
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0

    // Processing state
    @Published var isProcessing = false
    @Published var processingStatus: String = ""

    // Settings (persisted)
    @AppStorage("processingMode") var processingMode: ProcessingMode = .simple
    @AppStorage("recordingMode") var recordingMode: RecordingMode = .pushToTalk
    @AppStorage("playSoundFeedback") var playSoundFeedback: Bool = true
    /// Transcribe clips while recording and show the text in the overlay.
    @AppStorage("liveDictation") var liveDictation: Bool = true
    /// Target clip length in seconds for live dictation.
    @AppStorage("liveClipSeconds") var liveClipSeconds: Double = 7
    /// Where live clips go. At the cursor, Simple cleanup is applied per clip.
    @AppStorage("liveDictationOutput") var liveDictationOutput: LiveOutput = .cursor

    /// True when the overlay should show the text so far.
    var showsLiveText: Bool { liveDictation && liveDictationOutput == .overlay }
    /// True when clips are pasted as they arrive.
    var typesLive: Bool { liveDictation && liveDictationOutput == .cursor }
    /// Clips pasted so far in the current take (live typing).
    private var livePastes = 0
    private var livePasteEndedWithSpace = false

    /// Text transcribed so far in the current take (live dictation).
    @Published var liveText = ""
    private var session: DictationSession?
    @AppStorage("preserveClipboard") var preserveClipboard: Bool = true
    @AppStorage("autoAddTrailingSpace") var autoAddTrailingSpace: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("showDockIcon") var showDockIcon: Bool = false {
        didSet {
            updateDockIconVisibility()
        }
    }

    func updateDockIconVisibility() {
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Last transcription result
    @Published var lastTranscription: String = ""
    @Published var lastProcessedText: String = ""

    // Error state (shown briefly, then cleared)
    @Published var lastError: String? = nil

    // Current session processing mode (set by hotkey, overrides default)
    @Published var currentSessionMode: ProcessingMode? = nil

    private var recordingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Recording Control

    func startRecording(withMode mode: ProcessingMode? = nil) {
        debugLog("startRecording called, mode=\(mode?.rawValue ?? "nil"), isRecording=\(isRecording)")
        guard !isRecording else {
            debugLog("startRecording BLOCKED - already recording")
            return
        }

        isRecording = true
        recordingDuration = 0
        liveText = ""
        currentSessionMode = mode  // Store the mode for this recording session

        let session = DictationSession(live: liveDictation, clipSeconds: liveClipSeconds) { samples, prompt in
            try await WhisperState.shared.transcribeText(samples: samples, prompt: prompt)
        }
        session.onText = { [weak self] text in self?.liveText = text }
        if typesLive {
            livePastes = 0
            livePasteEndedWithSpace = false
            session.onClip = { [weak self] piece, isLast in self?.pasteLive(piece, isLast: isLast) }
        }
        self.session = session

        // Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration += 0.1
            }
        }

        // Play start sound
        if playSoundFeedback {
            SoundManager.shared.playStartSound()
        }

        // Start audio recording
        do {
            try Recorder.shared.startRecording { [weak self] samples, level in
                Task { @MainActor [weak self] in
                    guard let self, self.session === session else { return }
                    self.audioLevel = level
                    session.append(samples)
                }
            }
        } catch {
            debugLog("startRecording FAILED: \(error)")
            isRecording = false
            recordingTimer?.invalidate()
            recordingTimer = nil
            self.session = nil
            lastError = "Recording failed: \(error.localizedDescription)"
            if playSoundFeedback { SoundManager.shared.playErrorSound() }
            return
        }

        // Show recording panel
        debugLog("Showing recording panel")
        AppDelegate.shared?.showRecordingPanel()
    }

    func stopRecording() {
        guard isRecording else {
            debugLog("stopRecording BLOCKED - not recording")
            return
        }

        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        debugLog("stopRecording called, duration=\(recordingDuration)")

        // Play stop sound
        if playSoundFeedback {
            SoundManager.shared.playStopSound()
        }

        Recorder.shared.stopRecording()
        guard let session else {
            processingStatus = "Recording failed"
            debugLog("stopRecording FAILED - no session")
            return
        }
        self.session = nil

        // Hide recording panel
        if let appDelegate = AppDelegate.shared {
            appDelegate.hideRecordingPanel()
        }

        // Process the audio
        Task {
            await process(session)
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        Recorder.shared.cancelRecording()
        session?.cancel()
        session = nil
        liveText = ""

        if let appDelegate = AppDelegate.shared {
            appDelegate.hideRecordingPanel()
        }
    }

    // MARK: - Live typing

    /// Pastes one clip at the cursor. Clips after the first get a leading space; the last
    /// one gets the trailing space setting.
    private func pasteLive(_ piece: String, isLast: Bool) {
        let cleaned = SimpleCleanupProcessor.shared.process(piece)
        guard !cleaned.isEmpty else { return }
        var text = (livePastes > 0 ? " " : "") + cleaned
        if isLast, autoAddTrailingSpace { text += " " }
        CursorPaster.paste(text, preserveClipboard: preserveClipboard)
        livePastes += 1
        livePasteEndedWithSpace = text.hasSuffix(" ")
        debugLog("pasteLive clip \(livePastes) last=\(isLast) len=\(text.count)")
    }

    // MARK: - Audio Processing

    private func process(_ session: DictationSession) async {
        isProcessing = true
        processingStatus = "Transcribing..."

        // Use session mode if set (from hotkey), otherwise use default setting
        let activeMode = currentSessionMode ?? processingMode
        debugLog("processAudio start: mode=\(activeMode.rawValue) modelLoaded=\(WhisperState.shared.isModelLoaded) live=\(session.live)")

        do {
            // Transcribe with Whisper: in live mode only the last clip is left to do.
            let transcription = try await session.finish()
            liveText = ""
            lastTranscription = transcription
            debugLog("processAudio transcription='\(transcription.prefix(100))'")

            // Live typing: every clip is already at the cursor.
            if session.live, typesLive {
                if livePastes > 0, autoAddTrailingSpace, !livePasteEndedWithSpace {
                    CursorPaster.paste(" ", preserveClipboard: preserveClipboard)   // the last clip was silent
                }
                lastProcessedText = SimpleCleanupProcessor.shared.process(transcription)
                processingStatus = ""
                isProcessing = false
                currentSessionMode = nil
                if playSoundFeedback, livePastes > 0 { SoundManager.shared.playSuccessSound() }
                return
            }

            // Apply processing based on mode
            let processedText: String
            switch activeMode {
            case .simple:
                processingStatus = "Cleaning up..."
                processedText = SimpleCleanupProcessor.shared.process(transcription)
                debugLog("processAudio simple processed='\(processedText.prefix(100))'")
            case .advanced:
                // Check if LLM is configured before attempting enhancement
                if !AIEnhancementService.shared.isConfigured {
                    let provider = AIEnhancementService.shared.selectedProvider
                    let errorMsg: String
                    switch provider {
                    case .ollama:
                        errorMsg = "Ollama not configured. Please install Ollama and download a model in Settings → Enhancement."
                    case .claude:
                        errorMsg = "Claude API key not configured. Please add your API key in Settings → Enhancement."
                    case .openai:
                        errorMsg = "OpenAI API key not configured. Please add your API key in Settings → Enhancement."
                    }
                    throw NSError(domain: "AIEnhancement", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }
                processingStatus = "Enhancing with AI..."
                processedText = try await AIEnhancementService.shared.enhance(transcription)
            }

            lastProcessedText = processedText
            debugLog("processAudio lastProcessedText set, length=\(processedText.count)")

            // Paste at cursor
            processingStatus = "Pasting..."
            let textToPaste = autoAddTrailingSpace ? processedText + " " : processedText
            debugLog("processAudio pasting: sandboxed=\(CursorPaster.isSandboxed) axTrusted=\(AXIsProcessTrusted()) textLen=\(textToPaste.count)")
            CursorPaster.paste(textToPaste, preserveClipboard: preserveClipboard)

            processingStatus = ""
            isProcessing = false
            currentSessionMode = nil  // Clear session mode

            // Play success sound
            if playSoundFeedback {
                SoundManager.shared.playSuccessSound()
            }

        } catch {
            debugLog("processAudio ERROR: \(error)")
            processingStatus = "Error: \(error.localizedDescription)"
            lastError = error.localizedDescription
            isProcessing = false
            currentSessionMode = nil  // Clear session mode

            // Make sure the recording panel is gone after an error
            hideRecordingPanelAfterDelay()

            if playSoundFeedback {
                SoundManager.shared.playErrorSound()
            }

            // Clear error after 8 seconds
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    if self.lastError == error.localizedDescription {
                        self.lastError = nil
                    }
                }
            }
        }

        liveText = ""
    }

    // MARK: - Panel Helpers

    private func hideRecordingPanelAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let appDelegate = AppDelegate.shared {
                appDelegate.hideRecordingPanel()
            }
        }
    }

    // MARK: - Formatted Duration

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let tenths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    // MARK: - Debug

    private func debugLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] [AppState] \(message)\n"
        let path = "/tmp/dictai_appstate.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
