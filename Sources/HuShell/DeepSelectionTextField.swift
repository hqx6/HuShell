import AppKit
import SwiftUI

struct DeepSelectionTextField: NSViewRepresentable {
    static let selectionBackground = NSColor(srgbRed: 0.73, green: 0.84, blue: 1.00, alpha: 1.00)
    static let selectionForeground = NSColor(srgbRed: 0.08, green: 0.12, blue: 0.23, alpha: 1.00)

    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    let textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> EditableTextField {
        let field = EditableTextField()
        field.stringValue = text
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = textColor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: EditableTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = textColor
        field.requestEditingFocus()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DeepSelectionTextField
        private var finishing = false

        init(parent: DeepSelectionTextField) {
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
            if window != nil { requestEditingFocus() }
        }

        func requestEditingFocus() {
            guard window != nil else { return }
            if requestedFocus, currentEditor() != nil { return }
            requestedFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
                self.applySelectionAppearance()
            }
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                DispatchQueue.main.async { [weak self] in self?.applySelectionAppearance() }
            }
            return accepted
        }

        override func textDidChange(_ notification: Notification) {
            super.textDidChange(notification)
            applySelectionAppearance()
        }

        private func applySelectionAppearance() {
            guard let editor = currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: DeepSelectionTextField.selectionBackground,
                .foregroundColor: DeepSelectionTextField.selectionForeground
            ]
            editor.insertionPointColor = .white
        }
    }
}
