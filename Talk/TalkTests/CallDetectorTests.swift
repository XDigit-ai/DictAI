import Testing
import Foundation
@testable import DictAI

@MainActor
struct CallDetectorTests {
    let source = FakeProcessSource()
    let clock = TestClock()
    let zoom = AudioProcessInfo(pid: 500, bundleID: "us.zoom.xos", isRunningInput: true)

    func makeDetector() -> (CallDetector, started: () -> [CallApp], ended: () -> [CallApp]) {
        let detector = CallDetector(source: source, ownPID: 999, now: { [clock] in clock.now })
        var started: [CallApp] = []
        var ended: [CallApp] = []
        detector.onCallStarted = { started.append($0) }
        detector.onCallEnded = { ended.append($0) }
        return (detector, { started }, { ended })
    }

    /// Advances the clock second by second, evaluating each tick like the 1 s timer.
    func tick(_ detector: CallDetector, seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(1)
            detector.evaluate()
        }
    }

    @Test func startsAfterThreeSecondsOfMicUse() {
        let (detector, started, _) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 2)
        #expect(started().isEmpty)
        tick(detector, seconds: 1)
        #expect(started() == [CallApp(bundleKey: "us.zoom.xos", name: "Zoom")])
        tick(detector, seconds: 5)
        #expect(started().count == 1)
    }

    @Test func briefMicUseDoesNotStart() {
        let (detector, started, _) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 2)
        source.processes = []
        tick(detector, seconds: 5)
        #expect(started().isEmpty)
        #expect(detector.state == .idle)
    }

    @Test func endsTenSecondsAfterRelease() {
        let (detector, _, ended) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 3)
        source.processes = []
        detector.evaluate()                      // the release is seen when it happens
        tick(detector, seconds: 9)
        #expect(ended().isEmpty)
        tick(detector, seconds: 1)
        #expect(ended().map(\.name) == ["Zoom"])
    }

    @Test func reacquiringTheMicCancelsTheEnd() {
        let (detector, started, ended) = makeDetector()
        source.processes = [zoom]
        detector.evaluate()
        tick(detector, seconds: 3)
        source.processes = []
        tick(detector, seconds: 5)
        source.processes = [zoom]
        tick(detector, seconds: 1)
        source.processes = []
        tick(detector, seconds: 9)
        #expect(ended().isEmpty)
        #expect(started().count == 1)
    }

    @Test func ignoresDictAIAndUnknownApps() {
        let (detector, started, _) = makeDetector()
        source.processes = [
            AudioProcessInfo(pid: 999, bundleID: "us.zoom.xos", isRunningInput: true),
            AudioProcessInfo(pid: 600, bundleID: "com.example.recorder", isRunningInput: true),
            AudioProcessInfo(pid: 700, bundleID: "com.google.Chrome", isRunningInput: false),
        ]
        detector.evaluate()
        tick(detector, seconds: 5)
        #expect(started().isEmpty)
    }

    @Test func matchesHelperProcessesAndSafari() {
        #expect(KnownCallApps.match("com.google.Chrome.helper") == CallApp(bundleKey: "com.google.Chrome", name: "Google Chrome"))
        #expect(KnownCallApps.match("com.microsoft.teams2.helper")?.name == "Microsoft Teams")
        #expect(KnownCallApps.match("com.apple.WebKit.GPU")?.name == "Safari")
        #expect(KnownCallApps.match("com.google.Chromebook") == nil)
    }
}
