import AppKit

/// A single captured clipboard entry, preserving all pasteboard representations
/// so it can be re-pasted with full fidelity. In-memory only.
struct ClipboardItem: Identifiable {
    let id: UUID
    let createdAt: Date
    let representations: [Rep]
    let preview: Preview

    /// One pasteboard representation: a UTI type and its raw bytes.
    struct Rep: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    /// How a row renders in the picker. Derived, not part of identity.
    enum Preview: Equatable {
        case text(String)
        case image(NSImage)
        case files([String])
        case other(String)
    }

    /// Convenience for text-only items (used by tests and simple captures).
    static func text(_ string: String, id: UUID = UUID(), createdAt: Date = Date()) -> ClipboardItem {
        let data = Data(string.utf8)
        return ClipboardItem(
            id: id,
            createdAt: createdAt,
            representations: [Rep(type: .string, data: data)],
            preview: .text(string)
        )
    }
}

extension ClipboardItem: Equatable {
    /// Identity is the clipboard content (its representations), not id/time/preview.
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.representations == rhs.representations
    }
}
