import AppKit
import SwiftUI

struct RemoteFileDragItem: Codable {
    static let pasteboardType = NSPasteboard.PasteboardType("com.hushell.remote-file")
    let profileID: UUID
    let path: String
    let isDirectory: Bool

    func canMove(to directory: String, profileID: UUID) -> Bool {
        guard self.profileID == profileID else { return false }
        return (try? SSHService.moveDestination(from: path, toDirectory: directory)) != nil
    }
}

/// Native presses select immediately, without waiting for double-click recognition.
struct FileRowClickObserver: NSViewRepresentable {
    let onSelect: (NSEvent.ModifierFlags) -> Bool
    let onDoubleClick: () -> Void
    var onRename: (() -> Void)? = nil
    var dragItem: RemoteFileDragItem? = nil
    var canDrop: ((RemoteFileDragItem) -> Bool)? = nil
    var onDrop: ((RemoteFileDragItem) -> Void)? = nil

    func makeNSView(context: Context) -> ClickView { ClickView() }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onSelect = onSelect
        view.onDoubleClick = onDoubleClick
        view.onRename = onRename
        view.dragItem = dragItem
        view.canDrop = canDrop
        view.onDrop = onDrop
    }

    static func dismantleNSView(_ view: ClickView, coordinator: ()) {
        view.cancelPendingRename()
    }

    final class ClickView: NSView, NSDraggingSource {
        var onSelect: ((NSEvent.ModifierFlags) -> Bool)?
        var onDoubleClick: (() -> Void)?
        var onRename: (() -> Void)?
        var dragItem: RemoteFileDragItem?
        var canDrop: ((RemoteFileDragItem) -> Bool)?
        var onDrop: ((RemoteFileDragItem) -> Void)?
        private var dragging = false
        private var renameOnRelease = false
        private var pendingRename: DispatchWorkItem?
        private var renameMonitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([RemoteFileDragItem.pasteboardType])
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            dragging = false
            cancelPendingRename()
            window?.makeFirstResponder(self)
            let wasSelected = onSelect?(event.modifierFlags) ?? false
            let selectionModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            guard event.modifierFlags.intersection(selectionModifiers).isEmpty else { return }
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                renameOnRelease = event.clickCount == 1 && wasSelected && onRename != nil
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard renameOnRelease else { return }
            renameOnRelease = false
            guard window != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }

            // The system reports whether the next press belongs to a double click.
            // Only defer rename; selection has already been applied on mouse-down.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cancelPendingRename()
                if self.window?.isKeyWindow == true { self.onRename?() }
            }
            pendingRename = work
            renameMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                                                                        .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                self?.cancelPendingRename()
                return event
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancelPendingRename() }
        }

        func cancelPendingRename() {
            renameOnRelease = false
            pendingRename?.cancel()
            pendingRename = nil
            if let renameMonitor { NSEvent.removeMonitor(renameMonitor) }
            renameMonitor = nil
        }

        override func mouseDragged(with event: NSEvent) {
            cancelPendingRename()
            guard !dragging, let dragItem,
                  let data = try? JSONEncoder().encode(dragItem),
                  let value = String(data: data, encoding: .utf8) else { return }
            dragging = true
            let item = NSPasteboardItem()
            item.setString(value, forType: RemoteFileDragItem.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(systemSymbolName: dragItem.isDirectory ? "folder.fill" : "doc",
                                accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 20, height: 20))
            draggingItem.setDraggingFrame(NSRect(x: 0, y: 0, width: 24, height: 24), contents: image)
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let allowed = decodedItem(from: sender).map { canDrop?($0) ?? false } ?? false
            layer?.borderColor = allowed ? NSColor.controlAccentColor.cgColor : nil
            layer?.borderWidth = allowed ? 2 : 0
            return allowed ? .move : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            layer?.borderWidth = 0
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            layer?.borderWidth = 0
            guard let item = decodedItem(from: sender), canDrop?(item) == true else { return false }
            onDrop?(item)
            return true
        }

        private func decodedItem(from sender: NSDraggingInfo) -> RemoteFileDragItem? {
            guard let string = sender.draggingPasteboard.string(forType: RemoteFileDragItem.pasteboardType),
                  let data = string.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RemoteFileDragItem.self, from: data)
        }
    }
}
