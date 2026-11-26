import AppKit
import SwiftUI

struct FileRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> EditableTextField {
        let field = EditableTextField()
        field.stringValue = text
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .textColor
        field.backgroundColor = .textBackgroundColor
        field.isEditable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: EditableTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil && field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FileRenameTextField
        private var finishing = false

        init(parent: FileRenameTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finish(commit: true)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                return true
            }
            return false
        }

        private func finish(commit: Bool) {
            guard !finishing else { return }
            finishing = true
            DispatchQueue.main.async { [parent] in
                if commit { parent.onCommit() } else { parent.onCancel() }
            }
        }
    }

    final class EditableTextField: NSTextField {
        private var requestedFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !requestedFocus else { return }
            requestedFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.selectText(nil)
            }
        }
    }
}
