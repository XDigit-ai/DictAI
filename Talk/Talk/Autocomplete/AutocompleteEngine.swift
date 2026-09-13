import AppKit
import Combine

@MainActor
final class AutocompleteEngine: FocusedFieldMonitorDelegate {
    static let shared = AutocompleteEngine()

    private let monitor = FocusedFieldMonitor()
    private let overlay = SuggestionOverlay()
    private let interceptor = KeyInterceptor()

    private var idleWorkItem: DispatchWorkItem?
    private var requestGeneration: Int = 0
    private var pendingTask: Task<Void, Never>?

    private var currentSuggestion: String = ""
    private var currentSnapshot: FocusedFieldSnapshot?

    private init() {}

    func bootstrap() {
        monitor.delegate = self
        interceptor.onAccept = { [weak self] in self?.acceptSuggestion() }
        interceptor.onDismiss = { [weak self] in self?.dismiss() }
        applyEnabled(AutocompleteState.shared.enabled)
    }

    func applyEnabled(_ enabled: Bool) {
        if enabled {
            monitor.start()
            interceptor.install()
        } else {
            monitor.stop()
            interceptor.uninstall()
            dismiss()
        }
    }

    // MARK: - FocusedFieldMonitorDelegate

    func focusedFieldDidChange(_ snapshot: FocusedFieldSnapshot) {
        if AutocompleteState.shared.blocklist.contains(snapshot.bundleId) {
            dismiss()
            return
        }
        // Snapshot changed → invalidate any visible suggestion (text moved underneath us)
        if currentSuggestion.isEmpty == false, currentSnapshot != snapshot {
            dismiss()
        }
        currentSnapshot = snapshot
        scheduleRequest()
    }

    func focusedFieldDidClear() {
        currentSnapshot = nil
        dismiss()
    }

    // MARK: - Request scheduling

    private func scheduleRequest() {
        idleWorkItem?.cancel()
        let delay = max(50, AutocompleteState.shared.idleDelayMs)
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.fireRequest()
            }
        }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
    }

    private func fireRequest() {
        guard let snap = currentSnapshot else { return }

        // Skip very short prefixes — model rarely produces useful continuations
        let trimmedPrefix = snap.textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrefix.count >= 3 else { return }

        let contextLen = max(80, AutocompleteState.shared.contextChars)
        let prefix = String(snap.textBeforeCaret.suffix(contextLen))

        requestGeneration += 1
        let gen = requestGeneration
        AutocompleteState.shared.isFetching = true

        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            do {
                // Fetch screen context (may be cached). Empty string if OCR disabled or fails.
                let screenContext: String
                if AutocompleteState.shared.useOCR {
                    screenContext = await ScreenContextProvider.shared.context(for: snap.bundleId)
                } else {
                    screenContext = ""
                }
                guard !Task.isCancelled, gen == self.requestGeneration else { return }

                let suggestion = try await generate(prefix: prefix, screenContext: screenContext)
                guard !Task.isCancelled, gen == self.requestGeneration else { return }
                self.handleSuggestion(suggestion, for: snap)
            } catch {
                AutocompleteState.shared.lastError = error.localizedDescription
            }
            if gen == self.requestGeneration {
                AutocompleteState.shared.isFetching = false
            }
        }
    }

    private func generate(prefix: String, screenContext: String) async throws -> String {
        let ollama = OllamaService.shared
        let originalModel = ollama.selectedModel
        let override = AutocompleteState.shared.modelOverride
        if !override.isEmpty {
            ollama.selectedModel = override
        }
        defer {
            if !override.isEmpty {
                ollama.selectedModel = originalModel
            }
        }
        let userMessage = buildUserMessage(prefix: prefix, screenContext: screenContext)
        return try await ollama.generate(text: userMessage, systemPrompt: LLMPrompts.completion)
    }

    private func buildUserMessage(prefix: String, screenContext: String) -> String {
        let cleanedContext = sanitizeOCRContext(screenContext, excluding: prefix)
        if cleanedContext.isEmpty {
            return "[TYPING]\n\(prefix)"
        }
        return """
        [CONTEXT]
        \(cleanedContext)
        [/CONTEXT]

        [TYPING]
        \(prefix)
        """
    }

    /// Trim OCR text to a manageable size and try to remove echoed copies of the user's
    /// own typing (which appears both in the AX prefix and in the screen capture).
    private func sanitizeOCRContext(_ raw: String, excluding prefix: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // Drop any line that exactly contains the last 40+ chars of the user's typing —
        // that's almost certainly the very text they are mid-typing, captured by OCR.
        if prefix.count >= 40 {
            let needle = String(prefix.suffix(40)).trimmingCharacters(in: .whitespaces)
            if !needle.isEmpty {
                let lines = text.components(separatedBy: "\n")
                    .filter { !$0.contains(needle) }
                text = lines.joined(separator: "\n")
            }
        }

        let maxLen = max(200, AutocompleteState.shared.ocrMaxChars)
        if text.count > maxLen {
            // Keep the END of the OCR text — usually closest to where the user is typing
            // (e.g., quoted email body above the compose area).
            text = String(text.suffix(maxLen))
        }
        return text
    }

    private func handleSuggestion(_ raw: String, for snap: FocusedFieldSnapshot) {
        let cleaned = sanitize(raw, given: snap.textBeforeCaret)
        guard !cleaned.isEmpty else {
            dismiss()
            return
        }
        // If the field has moved since we fired the request, drop it
        guard let now = currentSnapshot, now == snap else { return }

        currentSuggestion = cleaned
        AutocompleteState.shared.currentSuggestion = cleaned
        interceptor.suggestionActive = true

        if let rect = snap.caretRect {
            overlay.show(suggestion: cleaned, anchoredTo: rect)
        } else {
            // No caret rect available — skip overlay rather than guess
            dismiss()
        }
    }

    private func sanitize(_ raw: String, given prefix: String) -> String {
        var text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        // If the model echoed the prefix, strip it
        if text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        // Stop at first newline — we only want one line of inline completion
        if let nl = text.firstIndex(of: "\n") {
            text = String(text[..<nl])
        }
        // Cap length
        let maxLen = max(10, AutocompleteState.shared.maxChars)
        if text.count > maxLen {
            text = String(text.prefix(maxLen))
        }
        // If the prefix doesn't end with whitespace and the suggestion doesn't start with
        // one, the join would mash two words together unless the suggestion begins with
        // punctuation. Add a leading space in that case.
        if let last = prefix.last, last.isLetter || last.isNumber,
           let first = text.first, first.isLetter || first.isNumber {
            text = " " + text
        }
        return text
    }

    // MARK: - Accept / dismiss

    private func acceptSuggestion() {
        let text = currentSuggestion
        guard !text.isEmpty else { return }
        dismiss()
        typeText(text)
    }

    func dismiss() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        pendingTask?.cancel()
        pendingTask = nil
        currentSuggestion = ""
        AutocompleteState.shared.currentSuggestion = ""
        AutocompleteState.shared.isFetching = false
        interceptor.suggestionActive = false
        overlay.hide()
    }

    private func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        // Use keyboardSetUnicodeString to inject arbitrary text without clipboard pollution.
        // We split into chunks of 20 chars (CGEvent's documented practical limit per event).
        let source = CGEventSource(stateID: .combinedSessionState)
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            let utf16 = Array(chunk.utf16)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                utf16.withUnsafeBufferPointer { buf in
                    keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: buf.baseAddress)
                }
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                utf16.withUnsafeBufferPointer { buf in
                    keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: buf.baseAddress)
                }
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
            index = end
        }
    }
}
