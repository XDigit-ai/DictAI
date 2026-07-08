import Testing
import Foundation
import AppKit
@testable import DictAI

struct ClipboardPreviewTests {

    @Test func derivePreviewPrefersImage() {
        // NSImage(size:) alone has no drawn representations, so tiffRepresentation
        // returns nil until something is actually rendered into it.
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        let png = image.tiffRepresentation ?? Data()
        let reps = [
            ClipboardItem.Rep(type: .string, data: Data("caption".utf8)),
            ClipboardItem.Rep(type: .tiff, data: png)
        ]
        if case .image = ClipboardManager.derivePreview(from: reps) {
            // ok
        } else {
            Issue.record("expected .image preview")
        }
    }

    @Test func derivePreviewFilesWhenFileURL() {
        let url = URL(fileURLWithPath: "/tmp/hello.txt")
        let reps = [ClipboardItem.Rep(type: .fileURL, data: url.dataRepresentation)]
        #expect(ClipboardManager.derivePreview(from: reps) == .files(["hello.txt"]))
    }

    @Test func derivePreviewTextWhenString() {
        let reps = [ClipboardItem.Rep(type: .string, data: Data("hello world".utf8))]
        #expect(ClipboardManager.derivePreview(from: reps) == .text("hello world"))
    }

    @Test func derivePreviewOtherWhenUnknown() {
        let reps = [ClipboardItem.Rep(type: NSPasteboard.PasteboardType("com.foo.bar"), data: Data([0x1]))]
        #expect(ClipboardManager.derivePreview(from: reps) == .other("com.foo.bar"))
    }
}
