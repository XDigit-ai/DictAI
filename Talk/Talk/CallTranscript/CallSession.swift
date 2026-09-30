@preconcurrency import AVFoundation
import AppKit
import Combine
import EventKit

nonisolated struct SessionManifest: Codable, Equatable {
    var header: TranscriptHeader
    var transcriptPath: String
    var appBundleKey: String?
}

struct CallSessionEnvironment {
    var transcriptsFolder: () -> URL
    var sessionsRoot: URL
    var makeCapture: () -> CallCapturing
    var makeLive: (Speaker) -> LiveTranscribing
    /// True if live transcription can run now. Must return quickly; never waits for a download.
    var liveAssetsReady: () async -> Bool
    var transcriber: UtteranceTranscribing
    var calendarTitle: () -> String?
    var keepAudio: () -> Bool
    var now: () -> Date
    var timeZone: TimeZone = .current

    static var live: CallSessionEnvironment {
        CallSessionEnvironment(
            transcriptsFolder: { CallSettings.folderURL },
            sessionsRoot: CallSettings.sessionsRoot,
            makeCapture: { CallAudioCapture() },
            makeLive: { AppleLiveTranscriber(speaker: $0) },
            liveAssetsReady: {
                if await LiveSpeechAssets.isInstalled() { return true }
                Task.detached { _ = await LiveSpeechAssets.ensureInstalled() }   // ready for the next call
                return false
            },
            transcriber: WhisperFinalTranscriber(),
            calendarTitle: { CallSession.currentCalendarEventTitle() },
            keepAudio: { CallSettings.keepAudio },
            now: Date.init)
    }
}

/// Everything belonging to the call being recorded. After `start` returns, the WAV
/// writers, live transcriber input and transcript file are only touched on `sink`.
nonisolated private final class ActiveRecording: @unchecked Sendable {
    let folder: URL
    var manifest: SessionManifest
    let file: TranscriptFile
    let capture: CallCapturing
    let live: [Speaker: LiveTranscribing]
    let writers: [Speaker: WAVWriter]
    let sink: DispatchQueue

    init(folder: URL, manifest: SessionManifest, file: TranscriptFile, capture: CallCapturing,
         live: [Speaker: LiveTranscribing], writers: [Speaker: WAVWriter], sink: DispatchQueue) {
        self.folder = folder
        self.manifest = manifest
        self.file = file
        self.capture = capture
        self.live = live
        self.writers = writers
        self.sink = sink
    }
}

nonisolated private func drain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
}

@MainActor
final class CallSession: ObservableObject {
    static let shared = CallSession(environment: .live)

    enum Phase: Equatable {
        case idle
        case recording(started: Date, app: CallApp?)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var warning: String?
    @Published private(set) var pendingRetries: [URL] = []
    @Published private(set) var finalizingCount = 0

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private let env: CallSessionEnvironment
    private var active: ActiveRecording?
    private var finalizations: [Task<Void, Never>] = []
    private var detector: CallDetector?

    init(environment: CallSessionEnvironment) {
        self.env = environment
    }

    // MARK: - App lifecycle

    func bootstrap() {
        let detector = CallDetector(source: CoreAudioProcessSource())
        detector.onCallStarted = { [weak self] app in self?.callDetected(app) }
        detector.onCallEnded = { [weak self] app in self?.callEnded(app) }
        detector.startMonitoring()
        self.detector = detector
        Task { await recoverOrphanedSessions() }
        Task.detached { _ = await LiveSpeechAssets.ensureInstalled() }   // so the first call has live text
    }

    private func callDetected(_ app: CallApp) {
        guard CallSettings.autoDetect, !isRecording else { return }
        CallPromptPanel.shared.show(app: app) { [weak self] accepted in
            guard accepted else { return }
            Task { await self?.start(app: app) }
        }
    }

    private func callEnded(_ app: CallApp) {
        CallPromptPanel.shared.dismiss()
        if case let .recording(_, recordingApp) = phase, recordingApp == app {
            Task { await stop() }
        }
    }

    /// Menu bar "Transcribe Call": uses the call app if one is on the mic.
    func startManually() async {
        await start(app: detector?.activeCallApp())
    }

    // MARK: - Recording

    func start(app: CallApp?) async {
        guard !isRecording else { return }
        warning = nil
        let started = env.now()
        let title = env.calendarTitle() ?? app.map { "\($0.name) call" } ?? "Call"
        var header = TranscriptHeader(
            title: title, app: app?.name ?? "Unknown", started: started, ended: nil,
            channels: [.you, .them], liveUnavailable: false, status: .live)
        do {
            let folder = env.sessionsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writers: [Speaker: WAVWriter] = [
                .you: try WAVWriter(url: folder.appendingPathComponent("you.wav")),
                .them: try WAVWriter(url: folder.appendingPathComponent("them.wav")),
            ]
            let sink = DispatchQueue(label: "ai.xdigit.dictai.callsink", qos: .userInitiated)

            // The file does not exist yet; live results wait on the sink until it does.
            let fileBox = FileBox()
            let liveOK = await env.liveAssetsReady()
            header.liveUnavailable = !liveOK
            var live: [Speaker: LiveTranscribing] = [:]
            if liveOK {
                for speaker in Speaker.allCases {
                    let transcriber = env.makeLive(speaker)
                    do {
                        try await transcriber.start { result in
                            sink.async {
                                let text = TranscriptCleaner.clean(result.text, confidence: result.confidence)
                                try? fileBox.file?.append(speaker: result.speaker, at: result.start, text: text)
                            }
                        }
                        live[speaker] = transcriber
                    } catch {
                        DebugLogger.log("Live transcriber \(speaker.rawValue) failed to start: \(error)", subsystem: "Calls")
                    }
                }
            }

            let capture = env.makeCapture()
            capture.onAudio = { [live] speaker, buffer in
                let samples = buffer.monoSamples
                // Each buffer is a fresh converted copy, owned by this hand off alone.
                nonisolated(unsafe) let owned = buffer
                sink.async {
                    try? writers[speaker]?.write(samples)
                    live[speaker]?.append(owned)
                }
            }
            header.channels = try capture.start(appBundleKey: app?.bundleKey)

            let file = try TranscriptFile.create(in: env.transcriptsFolder(), header: header, timeZone: env.timeZone)
            sink.sync { fileBox.file = file }
            let manifest = SessionManifest(header: header, transcriptPath: file.url.path, appBundleKey: app?.bundleKey)
            try saveManifest(manifest, in: folder)
            active = ActiveRecording(folder: folder, manifest: manifest, file: file, capture: capture,
                                     live: live, writers: writers, sink: sink)
            phase = .recording(started: started, app: app)
            DebugLogger.log("Call recording started: \(title)", subsystem: "Calls")
        } catch {
            warning = "Could not start transcribing: \(error.localizedDescription)"
            DebugLogger.log("Call start failed: \(error)", subsystem: "Calls")
        }
    }

    func stop() async {
        guard let rec = active else { return }
        active = nil
        phase = .idle
        rec.capture.stop()
        await drain(rec.sink)
        for transcriber in rec.live.values { await transcriber.finish() }
        await drain(rec.sink)                     // appends queued by the last live results

        var header = rec.manifest.header
        header.ended = env.now()
        let silentThem = header.channels.contains(.them) && (rec.sink.sync { rec.writers[.them]?.peak ?? 0 }) == 0
        if silentThem {
            header.channels = [.you]
            warning = "No audio came from the call app. Check that DictAI is allowed under System Settings, Privacy & Security, Screen & System Audio Recording."
        }
        rec.sink.sync {
            for writer in rec.writers.values { try? writer.finalize() }
            try? rec.file.finishLiveText()
            try? rec.file.setStatus(.processing)
            rec.file.removeLivePointer()
            rec.file.close()
        }
        var manifest = rec.manifest
        manifest.header = header
        try? saveManifest(manifest, in: rec.folder)
        runFinalization(folder: rec.folder, manifest: manifest)
    }

    // MARK: - Final pass

    private func runFinalization(folder: URL, manifest: SessionManifest) {
        finalizingCount += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finalize(folder: folder, manifest: manifest)
            self.finalizingCount -= 1
        }
        finalizations.append(task)
    }

    func waitForFinalization() async {
        while !finalizations.isEmpty {
            let pending = finalizations
            finalizations.removeAll()
            for task in pending { await task.value }
        }
    }

    private func finalize(folder: URL, manifest: SessionManifest) async {
        let fileURL = URL(fileURLWithPath: manifest.transcriptPath)
        let file = TranscriptFile(url: fileURL)
        var channels: [Speaker: [Float]] = [:]
        for speaker in manifest.header.channels {
            channels[speaker] = try? WAVFile.readSamples(folder.appendingPathComponent("\(speaker.rawValue).wav"))
        }
        do {
            let document = try await FinalPass.render(
                channels: channels, header: manifest.header, using: env.transcriber, timeZone: env.timeZone)
            try file.replaceAtomically(with: document)
            if env.keepAudio() { keepAudio(from: folder, next: fileURL) }
            try FileManager.default.removeItem(at: folder)
            pendingRetries.removeAll { $0 == folder }
            DebugLogger.log("Final transcript written: \(fileURL.lastPathComponent)", subsystem: "Calls")
        } catch {
            DebugLogger.log("Final pass failed: \(error)", subsystem: "Calls")
            var header = manifest.header
            header.status = .endedLiveOnly
            try? file.rewriteHeader(header, timeZone: env.timeZone)
            if !pendingRetries.contains(folder) { pendingRetries.append(folder) }
        }
    }

    private func keepAudio(from folder: URL, next transcript: URL) {
        let base = transcript.deletingPathExtension().path
        for speaker in Speaker.allCases {
            let source = folder.appendingPathComponent("\(speaker.rawValue).wav")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: "\(base).\(speaker.rawValue).wav"))
        }
    }

    func retryPending() async {
        let folders = pendingRetries
        for folder in folders {
            guard let manifest = loadManifest(in: folder) else { continue }
            runFinalization(folder: folder, manifest: manifest)
        }
        await waitForFinalization()
    }

    // MARK: - Recovery and termination

    /// Finishes sessions left behind by a crash or quit.
    func recoverOrphanedSessions() async {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: env.sessionsRoot, includingPropertiesForKeys: nil) else { return }
        for folder in folders where folder.hasDirectoryPath {
            guard var manifest = loadManifest(in: folder) else { continue }
            if manifest.header.ended == nil {
                let samples = (try? WAVFile.readSamples(folder.appendingPathComponent("you.wav")))?.count ?? 0
                manifest.header.ended = manifest.header.started.addingTimeInterval(Double(samples) / 16_000)
            }
            if !fm.fileExists(atPath: manifest.transcriptPath) {
                var header = manifest.header
                header.status = .processing
                _ = try? TranscriptFile.create(at: URL(fileURLWithPath: manifest.transcriptPath), header: header, timeZone: env.timeZone)
            }
            runFinalization(folder: folder, manifest: manifest)
        }
        await waitForFinalization()
    }

    /// Called from applicationWillTerminate. Synchronous: leaves everything on disk for recovery.
    func handleTermination() {
        detector?.stopMonitoring()
        guard let rec = active else { return }
        active = nil
        rec.capture.stop()
        rec.sink.sync {
            for writer in rec.writers.values { try? writer.finalize() }
            try? rec.file.finishLiveText()
            try? rec.file.setStatus(.processing)
            rec.file.removeLivePointer()
            rec.file.close()
        }
        var manifest = rec.manifest
        manifest.header.ended = env.now()
        try? saveManifest(manifest, in: rec.folder)
    }

    // MARK: - Helpers

    private func saveManifest(_ manifest: SessionManifest, in folder: URL) throws {
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
    }

    private func loadManifest(in folder: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }

    func drainForTesting() async {
        guard let rec = active else { return }
        await drain(rec.sink)
    }

    /// The calendar event happening now, or starting within 5 minutes.
    static func currentCalendarEventTitle() -> String? {
        let now = Date()
        let events = CalendarIntegration.shared.getTodayEvents()
        let event = events.first { $0.startDate <= now && $0.endDate >= now }
            ?? events.first { (0...300).contains($0.startDate.timeIntervalSince(now)) }
        guard let title = event?.title, !title.isEmpty else { return nil }
        return title
    }
}

/// Lets live results that arrive before the transcript file exists be written once it does.
/// Only read and written on the sink queue.
nonisolated private final class FileBox: @unchecked Sendable {
    var file: TranscriptFile?
}
