import Foundation
import SwiftUI
import Combine

@MainActor
class AIEnhancementService: ObservableObject {
    static let shared = AIEnhancementService()

    // Settings
    @AppStorage("selectedLLMProvider") var selectedProvider: LLMProviderType = .ollama
    @AppStorage("customSystemPrompt") var customSystemPrompt: String = ""
    @AppStorage("useCustomPrompt") var useCustomPrompt: Bool = false

    // Services
    let ollamaService = OllamaService.shared
    let claudeService = ClaudeService.shared
    let openAIService = OpenAIService.shared

    private init() {}

    // MARK: - Configuration Status

    var isConfigured: Bool {
        switch selectedProvider {
        case .ollama:
            return ollamaService.isConfigured
        case .claude:
            return claudeService.isConfigured
        case .openai:
            return openAIService.isConfigured
        }
    }

    var configurationStatus: String {
        switch selectedProvider {
        case .ollama:
            if ollamaService.isConnected {
                return "Connected to Ollama (\(ollamaService.selectedModel))"
            } else {
                return "Ollama not connected - is it running?"
            }
        case .claude:
            return claudeService.isConfigured ? "Claude API configured" : "Claude API key required"
        case .openai:
            return openAIService.isConfigured ? "OpenAI API configured" : "OpenAI API key required"
        }
    }

    // MARK: - Enhancement

    func enhance(_ text: String, prompt: String? = nil) async throws -> String {
        let systemPrompt = prompt ?? effectiveSystemPrompt

        // Detect voice directions in the text
        let (processedText, direction) = detectVoiceDirection(in: text)
        let finalPrompt = direction.map { "\(systemPrompt)\n\nUser's additional instruction: \($0)" } ?? systemPrompt
        return try await generate(text: processedText, systemPrompt: finalPrompt)
    }

    /// Sends text to the selected provider as is: no voice direction detection.
    func generate(text: String, systemPrompt: String) async throws -> String {
        switch selectedProvider {
        case .ollama:
            return try await ollamaService.generate(text: text, systemPrompt: systemPrompt)
        case .claude:
            return try await claudeService.generate(text: text, systemPrompt: systemPrompt)
        case .openai:
            return try await openAIService.generate(text: text, systemPrompt: systemPrompt)
        }
    }

    private var effectiveSystemPrompt: String {
        if useCustomPrompt && !customSystemPrompt.isEmpty {
            return customSystemPrompt
        }
        return LLMPrompts.enhancement
    }

    // MARK: - Voice Direction Detection

    /// Detects and extracts voice directions from the transcribed text
    /// e.g., "make this formal: here is my message" -> ("here is my message", "make this formal")
    func detectVoiceDirection(in text: String) -> (cleanedText: String, direction: String?) {
        let patterns = [
            // "make this formal: ..."
            "^(make (?:this|it) \\w+):?\\s*(.+)$",
            // "format as bullet points: ..."
            "^(format (?:as|like) [\\w\\s]+):?\\s*(.+)$",
            // "convert to ...: ..."
            "^(convert to [\\w\\s]+):?\\s*(.+)$",
            // "rewrite as ...: ..."
            "^(rewrite (?:as|this as) [\\w\\s]+):?\\s*(.+)$",
            // "... and make it formal"
            "^(.+?)\\s*(?:and |then |,\\s*)?(make (?:this|it) \\w+)$",
            // "... please make this formal"
            "^(.+?)\\s*(?:please |and )?(make (?:this|it) \\w+)$"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                // Check which group is the direction vs content
                if match.numberOfRanges >= 3 {
                    let group1Range = Range(match.range(at: 1), in: text)
                    let group2Range = Range(match.range(at: 2), in: text)

                    if let g1 = group1Range, let g2 = group2Range {
                        let group1 = String(text[g1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let group2 = String(text[g2]).trimmingCharacters(in: .whitespacesAndNewlines)

                        // Determine which is direction and which is content
                        if group1.lowercased().starts(with: "make") ||
                           group1.lowercased().starts(with: "format") ||
                           group1.lowercased().starts(with: "convert") ||
                           group1.lowercased().starts(with: "rewrite") {
                            return (group2, group1)
                        } else {
                            return (group1, group2)
                        }
                    }
                }
            }
        }

        return (text, nil)
    }
}

