import Foundation

nonisolated enum WAVFileError: Error {
    case tooShort
}

/// 16 bit PCM, mono, 16 kHz WAV helpers.
nonisolated enum WAVFile {
    static let headerSize = 44

    static func header(dataBytes: Int, sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// Reads every complete sample after the header, ignoring the header's sizes,
    /// so files left behind by a crash are read in full.
    static func readSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= headerSize else { throw WAVFileError.tooShort }
        let count = (data.count - headerSize) / 2
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: headerSize + i * 2, as: Int16.self))
                return Float(v) / Float(Int16.max)
            }
        }
    }
}

/// Streams samples to a WAV file. The header's sizes are patched in `finalize()`.
/// Used from one serial queue.
nonisolated final class WAVWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private(set) var sampleCount = 0
    private(set) var peak: Float = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: WAVFile.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.url = url
    }

    func write(_ samples: [Float]) throws {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            peak = max(peak, abs(clamped))
            var v = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func finalize() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVFile.header(dataBytes: sampleCount * 2))
        try handle.synchronize()
        try handle.close()
    }
}
