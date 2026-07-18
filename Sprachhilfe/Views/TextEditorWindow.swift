import AppKit
import SwiftUI

/// Presents a resizable, standalone window for editing long text (system prompt presets,
/// workflow prompts) as an alternative to cramped inline `TextEditor` boxes. Modeled directly on
/// `PluginSettingsWindowManager`. Live-syncs through the same `Binding<String>` the caller passes
/// in, so the inline box updates immediately — there is no separate save step here.
@MainActor
final class TextEditorWindowManager {
    static let shared = TextEditorWindowManager()

    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: TextEditorWindowDelegate] = [:]

    private init() {}

    func present(autosaveKey: String, title: String, text: Binding<String>) {
        if let window = windows[autosaveKey] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: EditableTextKitView(text: text)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        hostingView.sizingOptions = []
        window.title = title
        window.contentMinSize = NSSize(width: 500, height: 350)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        if !window.setFrameUsingName(autosaveKey) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveKey)

        let delegate = TextEditorWindowDelegate(key: autosaveKey) { [weak self] key in
            self?.windows[key] = nil
            self?.delegates[key] = nil
        }
        delegates[autosaveKey] = delegate
        windows[autosaveKey] = window
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class TextEditorWindowDelegate: NSObject, NSWindowDelegate {
    private let key: String
    private let onClose: (String) -> Void

    init(key: String, onClose: @escaping (String) -> Void) {
        self.key = key
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose(key)
    }
}
