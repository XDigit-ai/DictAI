import Foundation

/// Pure, in-memory ring buffer of clipboard items. Newest first, capped at `maxItems`.
/// Re-ingesting existing content moves it to the front instead of duplicating.
struct ClipboardBuffer {
    private(set) var items: [ClipboardItem] = []
    let maxItems: Int

    init(maxItems: Int = 20) {
        self.maxItems = maxItems
    }

    mutating func ingest(_ item: ClipboardItem) {
        // Re-copying the current front item is a no-op.
        if let front = items.first, front == item { return }
        // If it exists deeper in the buffer, remove it so it moves to the front.
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
    }

    mutating func clear() {
        items.removeAll()
    }
}
