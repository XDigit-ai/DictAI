import Foundation
@testable import DictAI

let utc = TimeZone(identifier: "UTC")!

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictai-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 2026-09-29 14:30:05 UTC.
let sampleStart = Date(timeIntervalSince1970: 1_790_692_205)

func sampleHeader(title: String = "Weekly sync", status: TranscriptStatus = .live) -> TranscriptHeader {
    TranscriptHeader(
        title: title, app: "Zoom", started: sampleStart, ended: nil,
        channels: [.you, .them], liveUnavailable: false, status: status
    )
}
