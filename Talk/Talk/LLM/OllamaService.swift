import Foundation
import SwiftUI
import Combine

@MainActor
class OllamaService: ObservableObject, LLMProviderProtocol {
    static let shared = OllamaService()

    // Settings
    @AppStorage("ollamaBaseURL") var baseURL: String = "http://localhost:11434"
    @AppStorage("ollamaModel") var selectedModel: String = "qwen2.5:3b"

    // State
    @Published var isConnected = false
    @Published var availableModels: [String] = []
    @Published var isLoading = false

    var name: String { "Ollama" }

    var isConfigured: Bool {
        isConnected && !selectedModel.isEmpty
    }

    private init() {
        Task {
            await checkConnection()
        }
    }

    // MARK: - Connection

    func checkConnection() async {
        guard let url = URL(string: baseURL) else {
            isConnected = false
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                isConnected = httpResponse.statusCode == 200
            } else {
                isConnected = false
            }

            if isConnected {
                await refreshModels()
            }
        } catch {
            isConnected = false
        }
    }

    func refreshModels() async {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            availableModels = response.models.map { $0.name }
        } catch {
            availableModels = []
        }
    }

    // MARK: - Generation

    func generate(text: String, systemPrompt: String) async throws -> String {
        // Retry connection check if not connected (init check may not have completed)
        if !isConnected {
            await checkConnection()
        }
        guard isConnected else {
            throw LLMError.connectionFailed
        }

        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw LLMError.connectionFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120  // 2 minute timeout

        let body: [String: Any] = [
            "model": selectedModel,
            "prompt": text,
            "system": systemPrompt,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "top_p": 0.9,
                "num_ctx": 8192          // call notes send a few thousand tokens per request
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.requestFailed(errorBody)
        }

        let ollamaResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)

        guard !ollamaResponse.response.isEmpty else {
            throw LLMError.noContent
        }

        return ollamaResponse.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Response Types

struct OllamaTagsResponse: Codable {
    let models: [OllamaModel]
}

struct OllamaModel: Codable {
    let name: String
    let modifiedAt: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
    }
}

struct OllamaGenerateResponse: Codable {
    let model: String
    let response: String
    let done: Bool
}
