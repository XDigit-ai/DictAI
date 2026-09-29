import AppKit
import ScreenCaptureKit
import Vision

/// Captures the focused window via ScreenCaptureKit, runs Vision OCR, and returns the
/// recognized text as plain prose. Results are cached per-(pid, windowID) with a short TTL
/// so we don't re-OCR on every keystroke.
@MainActor
final class ScreenContextProvider {
    static let shared = ScreenContextProvider()

    private struct CacheEntry {
        let text: String
        let capturedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<String, Never>] = [:]
    private let ttl: TimeInterval = 2.5

    private init() {}

    /// Returns OCR text for the currently focused window. May return cached text if a
    /// fresh capture happened within the last few seconds. Returns "" if anything fails
    /// (permission missing, no matching window, OCR yielded nothing).
    func context(for bundleId: String) async -> String {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == bundleId else {
            return ""
        }
        let pid = frontApp.processIdentifier

        // Cache key per app — if user has multiple windows of the same app, we OCR
        // whichever is frontmost at refresh time, which is the desired behavior.
        let key = "\(pid)"

        if let entry = cache[key], Date().timeIntervalSince(entry.capturedAt) < ttl {
            return entry.text
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<String, Never> { [weak self] in
            let text = await Self.captureAndOCR(pid: pid)
            self?.store(key: key, text: text)
            return text
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func store(key: String, text: String) {
        cache[key] = CacheEntry(text: text, capturedAt: Date())
    }

    // MARK: - Capture + OCR

    private static func captureAndOCR(pid: pid_t) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter { window in
                window.owningApplication?.processID == pid &&
                window.isOnScreen &&
                window.frame.width > 80 &&
                window.frame.height > 80
            }
            guard let window = pickBestWindow(candidates) else { return "" }

            let config = SCStreamConfiguration()
            // Capture at native resolution of the window
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            // SCStreamConfiguration on macOS 14 has captureResolution but we keep defaults.

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return await ocr(image: image)
        } catch {
            NSLog("[Autocomplete OCR] capture failed: \(error.localizedDescription)")
            return ""
        }
    }

    private static func pickBestWindow(_ windows: [SCWindow]) -> SCWindow? {
        if windows.isEmpty { return nil }
        // Prefer the lowest windowLayer (frontmost in z-order), break ties by largest area
        return windows
            .sorted {
                if $0.windowLayer != $1.windowLayer {
                    return $0.windowLayer < $1.windowLayer
                }
                return ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height)
            }
            .first
    }

    private static func ocr(image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.isEmpty }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[Autocomplete OCR] Vision failed: \(error.localizedDescription)")
                continuation.resume(returning: "")
            }
        }
    }
}
