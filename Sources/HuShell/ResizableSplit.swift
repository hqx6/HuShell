import SwiftUI
import AppKit

struct ResizableSplit<First: View, Second: View>: View {
    let axis: Axis
    let minimumFirst: CGFloat
    let minimumSecond: CGFloat
    var maximumFirst: CGFloat? = nil
    var initialFirst: CGFloat? = nil
    var initialFraction: CGFloat = 0.6
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var preferredFirst: CGFloat?
    private let dividerSize: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let extent = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(0, extent - dividerSize)
            let upper = max(minimumFirst, min(available - minimumSecond, maximumFirst ?? available))
            let size = min(upper, max(minimumFirst, preferredFirst ?? initialFirst ?? available * initialFraction))
            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        first().frame(width: size)
                        handle(size: size, upper: upper).frame(width: dividerSize)
                        second().frame(width: max(0, available - size))
                    }
                } else {
                    VStack(spacing: 0) {
                        first().frame(height: size)
                        handle(size: size, upper: upper).frame(height: dividerSize)
                        second().frame(height: max(0, available - size))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: axis == .horizontal ? minimumFirst + minimumSecond + dividerSize : nil,
               minHeight: axis == .vertical ? minimumFirst + minimumSecond + dividerSize : nil)
    }

    private func handle(size: CGFloat, upper: CGFloat) -> some View {
        SplitResizeHandle(axis: axis, size: size) { value in
            preferredFirst = min(upper, max(minimumFirst, value))
        }
        .help(axis == .horizontal ? "拖动调整面板宽度" : "拖动调整面板高度")
        .accessibilityElement()
        .accessibilityLabel(axis == .horizontal ? "调整面板宽度" : "调整面板高度")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 20 : -20
            preferredFirst = min(upper, max(minimumFirst, size + delta))
        }
    }
}

struct SplitResizeHandle: NSViewRepresentable {
    let axis: Axis
    let size: CGFloat
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.axis = axis
        view.currentSize = size
        view.onChange = onChange
        view.toolTip = axis == .horizontal ? "拖动调整面板宽度" : "拖动调整面板高度"
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }

    final class HandleView: NSView {
        var axis: Axis = .horizontal
        var currentSize: CGFloat = 0
        var onChange: ((CGFloat) -> Void)?
        private var origin = NSPoint.zero
        private var originalSize: CGFloat = 0
        private var hovering = false
        private var tracking: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                     options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                     owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
            originalSize = currentSize
        }
        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            let offset = axis == .horizontal ? point.x - origin.x : origin.y - point.y
            onChange?(originalSize + offset)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(hovering ? 0.12 : 0.025).setFill()
            bounds.fill()
            let thumb = NSRect(x: (bounds.width - (axis == .horizontal ? 3 : 32)) / 2,
                               y: (bounds.height - (axis == .horizontal ? 32 : 3)) / 2,
                               width: axis == .horizontal ? 3 : 32,
                               height: axis == .horizontal ? 32 : 3)
            (hovering ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
