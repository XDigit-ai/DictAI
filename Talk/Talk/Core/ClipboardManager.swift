import AppKit
import SwiftUI
import Combine

/// Owns clipboard capture (polling) and the in-memory history buffer.
/// Recall (showPicker/paste) is wired in a later task.
@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []
    @AppStorage("clipboardHistoryEnabled") var enabled: Bool = true

    private var buffer = ClipboardBuffer(maxItems: 20)
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard enabled, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Capture

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        if let item = ClipboardManager.capture(from: pb) {
            ingest(item)
        }
    }

    /// Resync our polling baseline to the pasteboard's current changeCount.
    ///
    /// Call this immediately after ANY programmatic write to `NSPasteboard.general` that
    /// should NOT be captured into history (our own paste-back, or the dictation
    /// auto-paste/clipboard-restore path in `CursorPaster`). Because it reads the change
    /// count synchronously right after the write, it's robust to multiple back-to-back
    /// writes (e.g. write-then-restore): each write is followed by its own resync before
    /// the next poll tick can observe it.
    func markPasteboardSynced() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func ingest(_ item: ClipboardItem) {
        buffer.ingest(item)
        items = buffer.items
    }

    func clear() {
        buffer.clear()
        items = buffer.items
    }

    // MARK: - Pure helpers (unit-tested)

    /// Snapshot the first pasteboard item's representations into a ClipboardItem.
    nonisolated static func capture(from pasteboard: NSPasteboard) -> ClipboardItem? {
        guard let pbItem = pasteboard.pasteboardItems?.first else { return nil }
        var reps: [ClipboardItem.Rep] = []
        for type in pbItem.types {
            if let data = pbItem.data(forType: type) {
                reps.append(ClipboardItem.Rep(type: type, data: data))
            }
        }
        guard !reps.isEmpty else { return nil }
        return ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            representations: reps,
            preview: derivePreview(from: reps)
        )
    }

    /// Choose how a captured item renders, by type priority: image > files > text > other.
    nonisolated static func derivePreview(from reps: [ClipboardItem.Rep]) -> ClipboardItem.Preview {
        // Image
        if let imageRep = reps.first(where: { $0.type == .tiff || $0.type == .png }),
           let image = NSImage(data: imageRep.data) {
            return .image(image)
        }
        // Files
        let fileReps = reps.filter { $0.type == .fileURL }
        if !fileReps.isEmpty {
            let names = fileReps.compactMap { rep -> String? in
                guard let url = URL(dataRepresentation: rep.data, relativeTo: nil) else { return nil }
                return url.lastPathComponent
            }
            if !names.isEmpty { return .files(names) }
        }
        // Text
        if let stringRep = reps.first(where: { $0.type == .string }),
           let string = String(data: stringRep.data, encoding: .utf8) {
            return .text(string)
        }
        // Fallback
        return .other(reps.first?.type.rawValue ?? "unknown")
    }

    // MARK: - Recall

    func showPicker() {
        // Feature disabled: ⌘⌥V and the menu item are a no-op (spec §Disabled).
        guard enabled else { return }
        ClipboardHistoryPanel.shared.toggle(items: items) { [weak self] item in
            self?.paste(item)
        }
    }

    func paste(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pbItem = NSPasteboardItem()
        for rep in item.representations {
            pbItem.setData(rep.data, forType: rep.type)
        }
        pb.writeObjects([pbItem])
        markPasteboardSynced()
        // Small delay so the pasteboard is ready before the synthetic ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CursorPaster.pasteViaCmdV()
        }
    }
}
