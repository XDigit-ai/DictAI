import SwiftUI
import Combine

@MainActor
final class AutocompleteState: ObservableObject {
    static let shared = AutocompleteState()

    @AppStorage("autocompleteEnabled") var enabled: Bool = false {
        didSet {
            AutocompleteEngine.shared.applyEnabled(enabled)
        }
    }

    @AppStorage("autocompleteIdleMs") var idleDelayMs: Int = 350
    @AppStorage("autocompleteMaxChars") var maxChars: Int = 80
    @AppStorage("autocompleteContextChars") var contextChars: Int = 600
    @AppStorage("autocompleteModelOverride") var modelOverride: String = ""
    @AppStorage("autocompleteBlocklist") var blocklistCSV: String =
        "com.apple.Terminal,com.googlecode.iterm2,com.1password.1password7,com.agilebits.onepassword7,com.apple.keychainaccess"

    @AppStorage("autocompleteUseOCR") var useOCR: Bool = false
    @AppStorage("autocompleteOCRContextChars") var ocrMaxChars: Int = 1500

    @Published var currentSuggestion: String = ""
    @Published var isFetching: Bool = false
    @Published var lastError: String? = nil

    var blocklist: Set<String> {
        Set(
            blocklistCSV
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    private init() {}
}

extension LLMPrompts {
    static let completion = """
    You are an inline text completion engine. The user is typing inside a text field on macOS. Predict the natural continuation of what they are currently writing.

    The user's message will contain two sections:

    [CONTEXT] — text visible elsewhere on screen (e.g., the email they are replying to, the document they are commenting on, the conversation they are in). This is REFERENCE material only. Use it to understand recipients, tone, topic, and what is being responded to. NEVER quote or repeat it directly.

    [TYPING] — the text the user has typed so far, immediately before their caret. Your job is to continue THIS text.

    Rules:
    1. Output ONLY the continuation of [TYPING]. Do not repeat any of [TYPING] or [CONTEXT].
    2. Do NOT wrap the output in quotes, code fences, or commentary.
    3. Stop at the end of a natural clause or sentence. Never write more than one sentence.
    4. Match the user's tone, register, and capitalization style from [TYPING]. Use [CONTEXT] to inform topic and recipient.
    5. If [TYPING] already ends a complete thought, output a single space and continue with a plausible next clause.
    6. If you have no useful continuation, output an empty string.
    7. If only [TYPING] is provided (no [CONTEXT] section), just continue [TYPING] naturally.
    """
}
