import Foundation

enum CallSettings {
    static let folderKey = "callTranscriptsFolder"
    static let autoDetectKey = "callAutoDetect"
    static let keepAudioKey = "callKeepAudio"

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictAI Transcripts", isDirectory: true)
    }

    /// The chosen folder if it exists or can be created, else the default.
    static var folderURL: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: url.path) {
                return url
            }
            DebugLogger.log("Transcripts folder \(path) not writable, using default", subsystem: "Calls")
        }
        return defaultFolder
    }

    static var autoDetect: Bool {
        UserDefaults.standard.object(forKey: autoDetectKey) as? Bool ?? true
    }

    static var keepAudio: Bool {
        UserDefaults.standard.bool(forKey: keepAudioKey)
    }

    static var sessionsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictAI/Sessions", isDirectory: true)
    }
}
