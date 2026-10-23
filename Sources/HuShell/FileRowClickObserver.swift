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
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    var dragItem: RemoteFileDragItem? = nil
    var canDrop: ((RemoteFileDragItem) -> Bool)? = nil
    var onDrop: ((RemoteFileDragItem) -> Void)? = nil

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) {
        view.onSelect = onSelect
        view.onDoubleClick = onDoubleClick
        view.dragItem = dragItem
        view.canDrop = canDrop
        view.onDrop = onDrop
    }

    final class ClickView: NSView, NSDraggingSource {
        var onSelect: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var dragItem: RemoteFileDragItem?
        var canDrop: ((RemoteFileDragItem) -> Bool)?
        var onDrop: ((RemoteFileDragItem) -> Void)?
        private var dragging = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([RemoteFileDragItem.pasteboardType])
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseDown(with event: NSEvent) {
            dragging = false
            onSelect?()
            if event.clickCount == 2 { onDoubleClick?() }
        }

        override func mouseDragged(with event: NSEvent) {
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
