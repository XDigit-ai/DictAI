import AppKit
import SwiftUI

/// "Transcribe this call?" panel. Non activating, so it never takes focus from the call app.
@MainActor
final class CallPromptPanel {
    static let shared = CallPromptPanel()

    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    func show(app: CallApp, onAnswer: @escaping (Bool) -> Void) {
        dismiss()
        var answered = false
        let answer: (Bool) -> Void = { [weak self] accepted in
            guard !answered else { return }
            answered = true
            self?.dismiss()
            onAnswer(accepted)
        }
        let view = CallPromptView(appName: app.name, onTranscribe: { answer(true) }, onDismiss: { answer(false) })

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: view)
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 356, y: frame.maxY - 92))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { answer(false) }
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CallPromptView: View {
    let appName: String
    let onTranscribe: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.and.waveform.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribe this call?")
                    .font(.headline)
                Text(appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not now", action: onDismiss)
            Button("Transcribe", action: onTranscribe)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .frame(width: 340, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
