import AppKit
import SwiftUI

/// Native presses select immediately, without waiting for double-click recognition.
struct FileRowClickObserver: NSViewRepresentable {
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) {
        view.onSelect = onSelect
        view.onDoubleClick = onDoubleClick
    }

    final class ClickView: NSView {
        var onSelect: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            onSelect?()
            if event.clickCount == 2 { onDoubleClick?() }
        }
    }
}
