import Foundation

// Note: This file requires the whisper.xcframework to be integrated.
// The actual whisper.cpp integration will be done after building the framework.

#if canImport(whisper)
import whisper
#endif

/// Actor wrapper around whisper.cpp context for thread-safe transcription
actor WhisperContext {
    private var context: OpaquePointer?

    private init() {}

    deinit {
        #if canImport(whisper)
        if let ctx = context {
            whisper_free(ctx)
        }
        #endif
    }

    // MARK: - Factory

    static func createContext(path: String) async throws -> WhisperContext {
        #if canImport(whisper)
        var params = whisper_context_default_params()
        params.flash_attn = true  // Enable Metal acceleration

        guard let ptr = whisper_init_from_file_with_params(path, params) else {
            throw WhisperError.modelNotLoaded
        }
        let ctx = WhisperContext()
        await ctx.setContext(ptr)
        return ctx
        #else
        // Stub for development without whisper framework
        print("Warning: whisper framework not available, using stub")
        return WhisperContext()
        #endif
    }

    /// Sets the whisper context pointer (actor-isolated)
    private func setContext(_ ptr: OpaquePointer) {
        self.context = ptr
    }

    // MARK: - Transcription

    func transcribe(samples: [Float]) -> Bool {
        #if canImport(whisper)
        guard let ctx = context else { return false }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // Optimize parameters for dictation
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false

        // Use most available cores, leaving 2 for system
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 2))

        // Lower temperature for more deterministic output
        params.temperature = Float(0.0)
        params.temperature_inc = Float(0.2)

        // Language settings
        let langStr = strdup("en")
        params.language = UnsafePointer(langStr)
        params.translate = false

        // Single segment for faster processing
        params.single_segment = true

        // Suppress non-speech tokens
        params.suppress_blank = true
        params.suppress_nst = true

        return samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count)) == 0
        }
        #else
        // Stub for development
        return true
        #endif
    }

    func getTranscription() -> String {
        #if canImport(whisper)
        guard let ctx = context else { return "" }

        var result = ""
        let segmentCount = whisper_full_n_segments(ctx)

        for i in 0..<segmentCount {
            if let text = whisper_full_get_segment_text(ctx, i) {
                result += String(cString: text)
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        // Stub for development - return placeholder text
        return "[Transcription placeholder - whisper framework not integrated]"
        #endif
    }

    // MARK: - Model Info

    func getLanguage() -> String {
        #if canImport(whisper)
        guard let ctx = context else { return "unknown" }
        let langId = whisper_full_lang_id(ctx)
        if let langStr = whisper_lang_str(langId) {
            return String(cString: langStr)
        }
        return "unknown"
        #else
        return "en"
        #endif
    }
}
