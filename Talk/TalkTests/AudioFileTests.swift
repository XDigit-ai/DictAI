import Testing
import Foundation
import AVFoundation
@testable import DictAI

struct AudioFileTests {

    @Test func wavRoundTrip() throws {
        let url = makeTempDirectory().appendingPathComponent("a.wav")
        let writer = try WAVWriter(url: url)
        let input = tone(0.5) + silence(0.25)
        try writer.write(Array(input.prefix(3000)))
        try writer.write(Array(input.dropFirst(3000)))
        try writer.finalize()
        #expect(writer.sampleCount == input.count)
        #expect(abs(writer.peak - 0.1) < 0.001)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + input.count * 2)
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(UInt32(littleEndian: riffSize)) == 36 + input.count * 2)

        let back = try WAVFile.readSamples(url)
        #expect(back.count == input.count)
        #expect(zip(back, input).allSatisfy { abs($0 - $1) < 0.0001 })
    }

    /// Review Focus 4: a crash leaves the header claiming zero data bytes.
    @Test func readsUnfinalizedWav() throws {
        let url = makeTempDirectory().appendingPathComponent("crash.wav")
        var data = WAVFile.header(dataBytes: 0)
        for s in tone(0.1) {
            var v = Int16(s * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(0x7F)                                   // half a sample, as if cut mid write
        try data.write(to: url)
        #expect(try WAVFile.readSamples(url).count == tone(0.1).count)
    }

    @Test func converts48kStereoTo16kMono() throws {
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let converter = try #require(AudioBufferConverter(from: inFormat, to: AudioBufferConverter.whisperFormat))
        var out: [Float] = []
        var afterFirstSecond = 0
        for chunk in 0..<20 {                                // 2 s of 1 kHz in 100 ms chunks
            if chunk == 10 { afterFirstSecond = out.count }
            let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for i in 0..<4800 {
                let v = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(chunk * 4800 + i) / 48_000))
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
            }
            out += try #require(converter.convert(buffer)).monoSamples
        }
        // The resampler holds back a fixed filter latency (about 15 ms) but must not lose
        // frames per buffer, or timestamps would drift over a long call.
        #expect(abs((out.count - afterFirstSecond) - 16_000) <= 64)
        #expect(32_000 - out.count <= 320)
        let crossings = zip(out, out.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(crossings - 4000) <= 80)
    }

    @Test func mono16kBufferRoundTrip() {
        let samples = tone(0.2)
        #expect(AVAudioPCMBuffer.mono16k(samples).monoSamples == samples)
    }
}
