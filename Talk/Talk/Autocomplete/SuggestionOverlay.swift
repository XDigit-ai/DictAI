import AppKit
import SwiftUI

@MainActor
final class SuggestionOverlay {
    private var panel: NSPanel?

    func show(suggestion: String, anchoredTo axRect: CGRect) {
        let panel = ensurePanel()

        // Render SwiftUI view with the suggestion
        panel.contentView = NSHostingView(rootView: GhostTextView(text: suggestion))
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 200, height: 24)
        let width = max(60, min(fitting.width, 600))
        let height = max(20, fitting.height)

        // Convert AX rect (top-left origin) to Cocoa screen coords (bottom-left origin)
        let cocoaOrigin = convertAXPointToCocoa(axRect: axRect)
        let frame = NSRect(
            x: cocoaOrigin.x + axRect.width,   // place to the right of the caret
            y: cocoaOrigin.y,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 24),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        self.panel = panel
        return panel
    }

    private func convertAXPointToCocoa(axRect: CGRect) -> NSPoint {
        let axTopLeft = NSPoint(x: axRect.origin.x, y: axRect.origin.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(axTopLeft) }) ?? NSScreen.main
        guard let screen else { return .zero }
        let screenFrame = screen.frame
        // AX y is from screen top; Cocoa y is from screen bottom
        let cocoaY = screenFrame.maxY - axRect.origin.y - axRect.height
        return NSPoint(x: axRect.origin.x, y: cocoaY)
    }
}

private struct GhostTextView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.55))
                )
            Text("⇥")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                )
        }
        .fixedSize()
    }
}
