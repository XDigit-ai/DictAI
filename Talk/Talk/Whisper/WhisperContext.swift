import Foundation

// Note: This file requires the whisper.xcframework to be integrated.
// The actual whisper.cpp integration will be done after building the framework.

#if canImport(whisper)
import whisper
#endif

/// One Whisper segment. Times are seconds relative to the samples passed in.
nonisolated struct WhisperSegment: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// Mean probability of the segment's text tokens, or nil if it has none.
    let confidence: Double?
}

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

    // MARK: - Segments (call transcripts)

    /// Transcribes and reads results in one actor call, so a dictation request
    /// cannot run in between and overwrite the results.
    func transcribeSegments(samples: [Float], initialPrompt: String?, beamSize: Int) -> [WhisperSegment]? {
        #if canImport(whisper)
        guard let ctx = context, !samples.isEmpty,
              !samples.contains(where: { $0.isNaN || $0.isInfinite }) else { return nil }

        var params = whisper_full_default_params(beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 2))
        params.beam_search.beam_size = Int32(beamSize)
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.no_speech_thold = 0.6
        params.suppress_blank = true
        params.suppress_nst = true

        let prompt = initialPrompt ?? ""
        let ok: Bool = "en".withCString { lang in
            prompt.withCString { promptPtr in
                params.language = lang
                params.initial_prompt = prompt.isEmpty ? nil : promptPtr
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count)) == 0
                }
            }
        }
        guard ok else { return nil }

        let eot = whisper_token_eot(ctx)
        return (0..<whisper_full_n_segments(ctx)).compactMap { i in
            guard let cText = whisper_full_get_segment_text(ctx, i) else { return nil }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var probabilities: [Float] = []
            for j in 0..<whisper_full_n_tokens(ctx, i) where whisper_full_get_token_id(ctx, i, j) < eot {
                probabilities.append(whisper_full_get_token_p(ctx, i, j))
            }
            let confidence = probabilities.isEmpty
                ? nil : Double(probabilities.reduce(0, +) / Float(probabilities.count))
            // Segment t0 and t1 are in 10 ms units.
            return WhisperSegment(
                text: text,
                start: Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                end: Double(whisper_full_get_segment_t1(ctx, i)) / 100,
                confidence: confidence)
        }
        #else
        return [WhisperSegment(text: "[whisper unavailable]", start: 0, end: 1, confidence: nil)]
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
