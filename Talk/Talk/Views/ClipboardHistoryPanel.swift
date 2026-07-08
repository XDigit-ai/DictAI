import AppKit
import SwiftUI

/// Floating, non-activating picker for clipboard history.
/// Non-activating so the previously focused app stays frontmost and receives the paste.
@MainActor
final class ClipboardHistoryPanel {
    static let shared = ClipboardHistoryPanel()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var onPick: ((ClipboardItem) -> Void)?
    private var items: [ClipboardItem] = []
    private var selection: Int = 0

    private init() {}

    func toggle(items: [ClipboardItem], onPick: @escaping (ClipboardItem) -> Void) {
        if panel != nil { hide(); return }
        self.items = items
        self.onPick = onPick
        self.selection = 0
        show()
    }

    private func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = ClipboardHistoryView(
            items: items,
            selection: Binding(get: { [weak self] in self?.selection ?? 0 },
                               set: { [weak self] in self?.selection = $0 }),
            onPick: { [weak self] item in self?.pick(item) }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        // .nonactivatingPanel lets this become key (so the local keyDown monitor
        // receives arrow/Enter/1-9/Esc) WITHOUT activating DictAI, so the
        // previously-frontmost app stays frontmost for the later synthetic ⌘V.
        panel.makeKeyAndOrderFront(nil)

        installKeyMonitor()
        self.panel = panel
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: // down arrow
                self.move(1); return nil
            case 126: // up arrow
                self.move(-1); return nil
            case 36, 76: // return / enter
                self.confirm(); return nil
            case 53: // escape
                self.hide(); return nil
            default:
                // number keys 1–9 jump to that item
                if let chars = event.charactersIgnoringModifiers,
                   let digit = Int(chars), (1...9).contains(digit),
                   digit <= self.items.count {
                    self.selection = digit - 1
                    self.confirm()
                    return nil
                }
                return event
            }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
        // Rebuild content so SwiftUI reflects the new selection.
        if let panel, let hosting = panel.contentView as? NSHostingView<ClipboardHistoryView> {
            hosting.rootView = ClipboardHistoryView(
                items: items,
                selection: Binding(get: { [weak self] in self?.selection ?? 0 },
                                   set: { [weak self] in self?.selection = $0 }),
                onPick: { [weak self] item in self?.pick(item) }
            )
        }
    }

    private func confirm() {
        guard items.indices.contains(selection) else { hide(); return }
        pick(items[selection])
    }

    private func pick(_ item: ClipboardItem) {
        hide()
        onPick?(item)
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The list UI hosted inside the panel.
struct ClipboardHistoryView: View {
    let items: [ClipboardItem]
    @Binding var selection: Int
    let onPick: (ClipboardItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clipboard History")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if items.isEmpty {
                Text("No clipboard history yet")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(index: index, item: item)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Divider()
            Text("↑↓ select   ⏎ paste   1–9 quick   esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 420, height: 360, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(index: Int, item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            } else {
                Spacer().frame(width: 16)
            }
            previewLabel(item.preview)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onPick(item) }
    }

    @ViewBuilder
    private func previewLabel(_ preview: ClipboardItem.Preview) -> some View {
        switch preview {
        case .text(let string):
            Text(string.trimmingCharacters(in: .whitespacesAndNewlines))
                .lineLimit(1)
        case .image(let image):
            HStack(spacing: 6) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
                Text("Image").foregroundStyle(.secondary)
            }
        case .files(let names):
            Label(names.joined(separator: ", "), systemImage: "doc").lineLimit(1)
        case .other(let type):
            Label(type, systemImage: "questionmark.square.dashed")
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
