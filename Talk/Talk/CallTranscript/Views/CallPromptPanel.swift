import AppKit
import SwiftUI

@MainActor
final class CallPromptPanel {
    static let shared = CallPromptPanel()

    func show(app: CallApp, onAnswer: @escaping (Bool) -> Void) {}
    func dismiss() {}
}
