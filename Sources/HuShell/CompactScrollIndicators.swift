import AppKit
import SwiftUI

private final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let narrow = NSRect(x: knob.midX - 2, y: knob.minY, width: 4, height: knob.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: narrow, xRadius: 2, yRadius: 2).fill()
    }
}

/// Uses the compact macOS overlay scroller for the file browser's nested scroll views.
struct CompactScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let scrollView = view?.enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            if !(scrollView.verticalScroller is ThinScroller) {
                scrollView.verticalScroller = ThinScroller()
            }
            if !(scrollView.horizontalScroller is ThinScroller) {
                scrollView.horizontalScroller = ThinScroller()
            }
        }
    }
}
