import Foundation
import CoreAudio

nonisolated struct AudioProcessInfo: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
}

nonisolated protocol AudioProcessSource: AnyObject {
    func currentProcesses() -> [AudioProcessInfo]
}

nonisolated final class CoreAudioProcessSource: AudioProcessSource {
    func currentProcesses() -> [AudioProcessInfo] {
        CoreAudioHelpers.processObjectIDs().compactMap { object in
            guard let pid = CoreAudioHelpers.pid(of: object),
                  let bundleID = CoreAudioHelpers.bundleID(of: object) else { return nil }
            return AudioProcessInfo(pid: pid, bundleID: bundleID, isRunningInput: CoreAudioHelpers.isRunningInput(object))
        }
    }
}

nonisolated struct CallApp: Equatable, Codable, Sendable {
    /// The known bundle ID the process matched; used to find the processes to tap.
    let bundleKey: String
    let name: String
}

nonisolated enum KnownCallApps {
    static let names: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.apple.WebKit.GPU": "Safari",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
    ]

    /// Exact bundle ID, or a helper whose ID starts with a known ID plus ".".
    static func match(_ bundleID: String) -> CallApp? {
        for (key, name) in names where bundleID == key || bundleID.hasPrefix(key + ".") {
            return CallApp(bundleKey: key, name: name)
        }
        return nil
    }
}

/// Notices when a known call app starts and stops using the microphone.
@MainActor
final class CallDetector {
    enum State: Equatable {
        case idle
        case candidate(CallApp, since: Date)
        case inCall(CallApp)
        case releasing(CallApp, since: Date)
    }

    var onCallStarted: ((CallApp) -> Void)?
    var onCallEnded: ((CallApp) -> Void)?
    private(set) var state: State = .idle

    private let source: AudioProcessSource
    private let ownPID: pid_t
    private let now: () -> Date
    private let startDelay: TimeInterval
    private let releaseDelay: TimeInterval
    private var timer: Timer?

    init(
        source: AudioProcessSource, ownPID: pid_t = getpid(), now: @escaping () -> Date = Date.init,
        startDelay: TimeInterval = 3, releaseDelay: TimeInterval = 10
    ) {
        self.source = source
        self.ownPID = ownPID
        self.now = now
        self.startDelay = startDelay
        self.releaseDelay = releaseDelay
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func activeCallApp() -> CallApp? {
        for process in source.currentProcesses() where process.isRunningInput && process.pid != ownPID {
            if let app = KnownCallApps.match(process.bundleID) { return app }
        }
        return nil
    }

    func evaluate() {
        let active = activeCallApp()
        let t = now()
        switch state {
        case .idle:
            if let active { state = .candidate(active, since: t) }
        case let .candidate(app, since):
            if active != app {
                state = active.map { .candidate($0, since: t) } ?? .idle
            } else if t.timeIntervalSince(since) >= startDelay {
                state = .inCall(app)
                onCallStarted?(app)
            }
        case let .inCall(app):
            if active != app { state = .releasing(app, since: t) }
        case let .releasing(app, since):
            if active == app {
                state = .inCall(app)
            } else if t.timeIntervalSince(since) >= releaseDelay {
                state = .idle
                onCallEnded?(app)
            }
        }
    }
}
