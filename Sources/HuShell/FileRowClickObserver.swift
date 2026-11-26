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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView(coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        context.coordinator.update(onSelect: onSelect,
                                   onDoubleClick: onDoubleClick,
                                   onRename: onRename)
        view.dragItem = dragItem
        view.canDrop = canDrop
        view.onDrop = onDrop
    }

    final class Coordinator: NSObject {
        private var onSelect: ((NSEvent.ModifierFlags) -> Bool)?
        private var onDoubleClick: (() -> Void)?
        private var onRename: (() -> Void)?
        private var selectedBeforePress = false
        private var modifiersAtPress: NSEvent.ModifierFlags = []

        func update(onSelect: @escaping (NSEvent.ModifierFlags) -> Bool,
                    onDoubleClick: @escaping () -> Void,
                    onRename: (() -> Void)?) {
            self.onSelect = onSelect
            self.onDoubleClick = onDoubleClick
            self.onRename = onRename
        }

        func mouseDown(with event: NSEvent) {
            selectedBeforePress = onSelect?(event.modifierFlags) ?? false
            modifiersAtPress = event.modifierFlags
        }

        @objc func handleSingleClick(_ recognizer: NSClickGestureRecognizer) {
            guard Self.shouldStartRename(isSelected: selectedBeforePress,
                                         modifiers: modifiersAtPress) else { return }
            onRename?()
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            onDoubleClick?()
        }

        static func shouldStartRename(isSelected: Bool,
                                      modifiers: NSEvent.ModifierFlags) -> Bool {
            let disallowed: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            return isSelected && modifiers.intersection(disallowed).isEmpty
        }
    }

    final class ClickView: NSView, NSDraggingSource {
        weak var coordinator: Coordinator?
        var dragItem: RemoteFileDragItem?
        var canDrop: ((RemoteFileDragItem) -> Bool)?
        var onDrop: ((RemoteFileDragItem) -> Void)?
        private var dragging = false

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            registerForDraggedTypes([RemoteFileDragItem.pasteboardType])
            wantsLayer = true

            let singleClick = SingleClickGestureRecognizer(target: coordinator,
                                                           action: #selector(Coordinator.handleSingleClick(_:)))
            singleClick.numberOfClicksRequired = 1
            let doubleClick = NSClickGestureRecognizer(target: coordinator,
                                                       action: #selector(Coordinator.handleDoubleClick(_:)))
            doubleClick.numberOfClicksRequired = 2
            addGestureRecognizer(singleClick)
            addGestureRecognizer(doubleClick)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([RemoteFileDragItem.pasteboardType])
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseDown(with event: NSEvent) {
            dragging = false
            coordinator?.mouseDown(with: event)
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

private final class SingleClickGestureRecognizer: NSClickGestureRecognizer {
    override func shouldRequireFailure(of otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let other = otherGestureRecognizer as? NSClickGestureRecognizer else { return false }
        return other.numberOfClicksRequired > numberOfClicksRequired
    }
}
