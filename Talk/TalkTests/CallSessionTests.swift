import Testing
import Foundation
import AVFoundation
@testable import DictAI

@MainActor
struct CallSessionTests {
    let transcripts = makeTempDirectory()
    let sessions = makeTempDirectory()
    let capture = FakeCapture()
    var lives: [Speaker: FakeLive] = [.you: FakeLive(speaker: .you), .them: FakeLive(speaker: .them)]

    func makeSession(
        transcriber: UtteranceTranscribing = FakeTranscriber(responses: [[seg("final words", 0)]]),
        liveAssets: Bool = true, keepAudio: Bool = false, startDelay: Duration = .zero
    ) -> CallSession {
        let lives = self.lives
        let capture = self.capture
        let env = CallSessionEnvironment(
            transcriptsFolder: { [transcripts] in transcripts },
            sessionsRoot: sessions,
            makeCapture: { capture },
            makeLive: { lives[$0]! },
            liveAssetsReady: {
                if startDelay > .zero { try? await Task.sleep(for: startDelay) }
                return liveAssets
            },
            transcriber: transcriber,
            calendarTitle: { nil },
            keepAudio: { keepAudio },
            now: { sampleStart },
            timeZone: utc)
        return CallSession(environment: env)
    }

    func transcriptText() throws -> String {
        let name = try FileManager.default.contentsOfDirectory(atPath: transcripts.path)
            .first { $0.hasSuffix(".md") && $0 != "_live.md" }!
        return try String(contentsOf: transcripts.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func liveResultsStreamIntoTheFileThenFinalReplacesIt() async throws {
        let session = makeSession()
        await session.start(app: CallApp(bundleKey: "us.zoom.xos", name: "Zoom"))
        #expect(session.isRecording)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        capture.emit(.them, silence(1) + tone(2) + silence(1))
        lives[.you]!.emit("um, hello there", at: 1.2)
        lives[.them]!.emit("hi", at: 2.5)
        await session.drainForTesting()

        let live = try transcriptText()
        #expect(live.contains("title: \"Zoom call\""))
        #expect(live.contains("status: live           \n"))
        #expect(live.hasSuffix("**You** · 00:00:01\nHello there\n\n**Them** · 00:00:02\nHi"))
        #expect(FileManager.default.fileExists(atPath: transcripts.appendingPathComponent("_live.md").path))

        await session.stop()
        await session.waitForFinalization()
        #expect(capture.stopped)
        #expect(lives[.you]!.finished && lives[.them]!.finished)
        let final = try transcriptText()
        #expect(final.contains("status: final          \n"))
        #expect(final.contains("Final words"))
        #expect(!FileManager.default.fileExists(atPath: transcripts.appendingPathComponent("_live.md").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
    }

    @Test func missingSpeechAssetsMarksLiveUnavailable() async throws {
        let session = makeSession(liveAssets: false)
        await session.start(app: nil)
        #expect(try transcriptText().contains("live: unavailable\n"))
        #expect(lives[.you]!.appendedFrames == 0)
        await session.stop()
        await session.waitForFinalization()
    }

    /// Review Focus 3: permission denied, the tap delivers only zeros.
    @Test func silentThemChannelBecomesYouOnly() async throws {
        let session = makeSession()
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        capture.emit(.them, silence(4))
        await session.stop()
        await session.waitForFinalization()
        #expect(try transcriptText().contains("channels: you\n"))
        #expect(session.warning?.contains("System Audio Recording") == true)
    }

    /// Review Focus 5: Whisper unavailable keeps the live text.
    @Test func failedFinalPassKeepsLiveText() async throws {
        let session = makeSession(transcriber: FakeTranscriber(responses: [], failAll: true))
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        lives[.you]!.emit("keep me", at: 1)
        await session.stop()
        await session.waitForFinalization()
        let text = try transcriptText()
        #expect(text.contains("status: ended-live-only\n"))
        #expect(text.contains("Keep me\n"))
        #expect(session.pendingRetries.count == 1)
    }

    /// Review Focus 4: crash recovery from an orphaned session with unfinalized WAVs.
    @Test func recoversOrphanedSession() async throws {
        let folder = sessions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var wav = WAVFile.header(dataBytes: 0)
        for s in silence(1) + tone(2) + silence(1) {
            var v = Int16(s * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        try wav.write(to: folder.appendingPathComponent("you.wav"))
        let path = transcripts.appendingPathComponent("2026-09-29 1430 Crashed call.md").path
        let manifest = SessionManifest(
            header: TranscriptHeader(title: "Crashed call", app: "Zoom", started: sampleStart, ended: nil,
                                     channels: [.you], liveUnavailable: false, status: .live),
            transcriptPath: path, appBundleKey: nil)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("session.json"))

        let session = makeSession()
        await session.recoverOrphanedSessions()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("status: final          \n"))
        #expect(text.contains("duration: 00:00:04\n"))
        #expect(text.contains("Final words"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func keepAudioMovesWavsNextToTranscript() async throws {
        let session = makeSession(keepAudio: true)
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        capture.emit(.them, silence(1) + tone(1) + silence(2))
        await session.stop()
        await session.waitForFinalization()
        let names = try FileManager.default.contentsOfDirectory(atPath: transcripts.path)
        #expect(names.contains { $0.hasSuffix(".you.wav") })
        #expect(names.contains { $0.hasSuffix(".them.wav") })
    }

    @Test func secondCallCanStartWhileFirstIsFinalizing() async throws {
        let session = makeSession()
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        await session.stop()
        await session.start(app: nil)
        #expect(session.isRecording)
        await session.stop()
        await session.waitForFinalization()
        let files = try FileManager.default.contentsOfDirectory(atPath: transcripts.path).filter { $0.hasSuffix(".md") }
        #expect(files.count == 2)
    }

    // MARK: - Review fixes

    /// Review Important 3: a double click must not start two recordings.
    @Test func concurrentStartsRecordOnce() async throws {
        let session = makeSession(startDelay: .milliseconds(50))
        async let first: Void = session.start(app: nil)
        async let second: Void = session.start(app: nil)
        _ = await (first, second)
        #expect(capture.startCount == 1)
        #expect(session.isRecording)
        await session.stop()
        await session.waitForFinalization()
    }

    /// Review Important 3: the call ending while start is still setting up stops it.
    @Test func stopDuringStartStopsOnceReady() async throws {
        let session = makeSession(startDelay: .milliseconds(100))
        async let starting: Void = session.start(app: nil)
        try await Task.sleep(for: .milliseconds(20))
        await session.stop()
        await starting
        await session.waitForFinalization()
        #expect(!session.isRecording)
        #expect(capture.stopped)
        #expect(!(try transcriptText()).contains("status: live "))
    }

    /// Review Important 4: a failed start leaves nothing running and nothing on disk.
    @Test func failedCaptureStartCleansUp() async throws {
        capture.failStart = true
        let session = makeSession()
        await session.start(app: nil)
        #expect(!session.isRecording)
        #expect(session.warning != nil)
        #expect(lives[.you]!.finished && lives[.them]!.finished)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: transcripts.path).isEmpty)
    }

    /// Review Important 5: clicking Retry twice must finalize once and keep the final status.
    @Test func doubleRetryFinalizesOnce() async throws {
        let session = makeSession(transcriber: FakeTranscriber(responses: [[seg("final words", 0)]], failFirst: 1))
        await session.start(app: nil)
        capture.emit(.you, silence(1) + tone(2) + silence(1))
        await session.stop()
        await session.waitForFinalization()
        #expect(try transcriptText().contains("status: ended-live-only"))

        async let r1: Void = session.retryPending()
        async let r2: Void = session.retryPending()
        _ = await (r1, r2)
        let text = try transcriptText()
        #expect(text.contains("status: final "))
        #expect(session.pendingRetries.isEmpty)
    }
}
