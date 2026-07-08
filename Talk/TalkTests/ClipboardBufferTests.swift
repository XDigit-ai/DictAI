import Testing
import Foundation
@testable import DictAI

struct ClipboardBufferTests {

    @Test func ingestInsertsAtFront() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("first"))
        buffer.ingest(.text("second"))
        #expect(buffer.items.count == 2)
        #expect(buffer.items.first?.preview == .text("second"))
    }

    @Test func ingestCapsAtMax() {
        var buffer = ClipboardBuffer(maxItems: 20)
        for i in 0..<25 { buffer.ingest(.text("item\(i)")) }
        #expect(buffer.items.count == 20)
        #expect(buffer.items.first?.preview == .text("item24"))
        #expect(buffer.items.last?.preview == .text("item5"))
    }

    @Test func ingestDuplicateOfFrontIsNoOp() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("same"))
        buffer.ingest(.text("same"))
        #expect(buffer.items.count == 1)
    }

    @Test func ingestDuplicateDeeperMovesToFront() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("a"))
        buffer.ingest(.text("b"))
        buffer.ingest(.text("c"))
        buffer.ingest(.text("a"))   // re-copy an older item
        #expect(buffer.items.count == 3)
        #expect(buffer.items.first?.preview == .text("a"))
        #expect(buffer.items.map(\.preview) == [.text("a"), .text("c"), .text("b")])
    }

    @Test func clearEmptiesBuffer() {
        var buffer = ClipboardBuffer()
        buffer.ingest(.text("a"))
        buffer.clear()
        #expect(buffer.items.isEmpty)
    }
}
