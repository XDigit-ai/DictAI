import Foundation

// MARK: - LLM Provider Protocol

protocol LLMProviderProtocol {
    var name: String { get }
    var isConfigured: Bool { get }
    func generate(text: String, systemPrompt: String) async throws -> String
}

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable, Codable {
    case ollama = "Ollama"
    case claude = "Claude"
    case openai = "OpenAI"

    var description: String {
        switch self {
        case .ollama:
            return "Local LLM (requires Ollama running)"
        case .claude:
            return "Anthropic Claude API"
        case .openai:
            return "OpenAI API"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        case .claude, .openai: return true
        }
    }
}

// MARK: - LLM Error

enum LLMError: LocalizedError {
    case notConfigured
    case connectionFailed
    case requestFailed(String)
    case invalidResponse
    case noContent

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LLM provider is not configured"
        case .connectionFailed:
            return "Failed to connect to LLM service"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .invalidResponse:
            return "Invalid response from LLM"
        case .noContent:
            return "No content in LLM response"
        }
    }
}

// MARK: - Default Prompts

struct LLMPrompts {
    static let enhancement = """
    You are a transcription enhancement assistant. Your task is to improve dictated text while preserving the original meaning and voice.

    Instructions:
    1. Fix grammar, spelling, and punctuation errors
    2. Add proper capitalization
    3. Remove filler words (um, uh, like, you know, etc.)
    4. Structure into sentences and paragraphs if appropriate
    5. Keep the original intent and tone
    6. Do NOT add any explanations or commentary

    If the text contains specific instructions about formatting (e.g., "make this formal", "convert to bullet points", "reply to this email"), follow those instructions.

    Return ONLY the enhanced text, nothing else.
    """

    static let emailReply = """
    You are an email writing assistant. Convert the following dictated content into a professional email reply.

    Instructions:
    1. Use proper email formatting with greeting and sign-off
    2. Fix grammar and punctuation
    3. Maintain a professional but friendly tone
    4. Keep it concise
    5. Do NOT add placeholders - use the content provided

    Return ONLY the email text, nothing else.
    """

    static let formal = """
    You are a writing assistant. Convert the following text into formal, professional language.

    Instructions:
    1. Use formal vocabulary and sentence structure
    2. Remove casual expressions and slang
    3. Fix grammar and punctuation
    4. Maintain the original meaning

    Return ONLY the formal text, nothing else.
    """
}
