import Foundation
import SwiftUI
import Combine

/// Main state machine for Whisper transcription
@MainActor
class WhisperState: ObservableObject {
    static let shared = WhisperState()

    // Model state
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0
    @Published var loadError: String?

    // Transcription state
    @Published var isTranscribing = false

    // Settings
    @AppStorage("selectedWhisperModel") var selectedModel: WhisperModel = .baseEn
    @AppStorage("selectedLanguage") var selectedLanguage: String = "en"

    private var whisperContext: WhisperContext?

    private init() {}

    // MARK: - Model Management

    var modelURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelsDir = appSupport.appendingPathComponent("DictAI/Models", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        return modelsDir.appendingPathComponent(selectedModel.filename)
    }

    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    func loadModel() async {
        guard !isLoading else { return }

        isLoading = true
        loadError = nil

        do {
            if !isModelDownloaded {
                try await downloadModel()
            }

            whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            isModelLoaded = true
        } catch {
            loadError = error.localizedDescription
            isModelLoaded = false
        }

        isLoading = false
    }

    func downloadModel() async throws {
        guard let url = selectedModel.downloadURL else {
            throw WhisperError.invalidModelURL
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: nil)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WhisperError.downloadFailed
        }

        try FileManager.default.moveItem(at: tempURL, to: modelURL)
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL) async throws -> String {
        guard let context = whisperContext else {
            throw WhisperError.modelNotLoaded
        }

        isTranscribing = true
        defer { isTranscribing = false }

        // Load audio samples
        let samples = try Recorder.loadAudioSamples(from: audioURL)

        // Transcribe
        guard await context.transcribe(samples: samples) else {
            throw WhisperError.transcriptionFailed
        }

        return await context.getTranscription()
    }

    // MARK: - Meeting Transcription

    func transcribeMeetingChunk(samples: [Float]) async throws -> String {
        guard let context = whisperContext else {
            throw WhisperError.modelNotLoaded
        }

        // Validate samples before passing to whisper.cpp
        guard !samples.isEmpty else { return "" }
        guard !samples.contains(where: { $0.isNaN || $0.isInfinite }) else {
            throw WhisperError.transcriptionFailed
        }

        guard await context.transcribeMeeting(samples: samples) else {
            throw WhisperError.transcriptionFailed
        }

        let segments = await context.getSegmentedTranscription()
        return segments.map(\.text).joined(separator: " ")
    }

    func unloadModel() {
        whisperContext = nil
        isModelLoaded = false
    }
}

// MARK: - Whisper Models

enum WhisperModel: String, CaseIterable, Codable {
    case tinyEn = "tiny.en"
    case baseEn = "base.en"
    case smallEn = "small.en"
    case mediumEn = "medium.en"
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"

    var displayName: String {
        switch self {
        case .tinyEn: return "Tiny (English)"
        case .baseEn: return "Base (English)"
        case .smallEn: return "Small (English)"
        case .mediumEn: return "Medium (English)"
        case .tiny: return "Tiny (Multilingual)"
        case .base: return "Base (Multilingual)"
        case .small: return "Small (Multilingual)"
        case .medium: return "Medium (Multilingual)"
        }
    }

    var filename: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL? {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")
    }

    var sizeDescription: String {
        switch self {
        case .tinyEn, .tiny: return "~75 MB"
        case .baseEn, .base: return "~148 MB"
        case .smallEn, .small: return "~488 MB"
        case .mediumEn, .medium: return "~1.5 GB"
        }
    }

    var speedDescription: String {
        switch self {
        case .tinyEn, .tiny: return "Fastest"
        case .baseEn, .base: return "Fast"
        case .smallEn, .small: return "Moderate"
        case .mediumEn, .medium: return "Slow"
        }
    }
}

// MARK: - Errors

enum WhisperError: LocalizedError {
    case modelNotLoaded
    case invalidModelURL
    case downloadFailed
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        case .invalidModelURL:
            return "Invalid model download URL"
        case .downloadFailed:
            return "Failed to download model"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
