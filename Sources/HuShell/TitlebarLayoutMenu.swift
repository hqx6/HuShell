import AppKit
import SwiftUI

/// A titlebar menu that opens on mouse-down, including the first click after WKWebView focus.
struct TitlebarLayoutMenu: NSViewRepresentable {
    let selected: FilePanelPosition
    let enabled: Bool
    let onSelect: (FilePanelPosition) -> Void

    func makeNSView(context: Context) -> MenuView {
        let view = MenuView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.popUpButton)
        view.setAccessibilityLabel("布局设置")
        return view
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.selected = selected
        view.enabled = enabled
        view.onSelect = onSelect
    }

    final class MenuView: NSView {
        var selected: FilePanelPosition = .bottom
        var enabled = false
        var onSelect: ((FilePanelPosition) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard enabled else { return }
            let menu = NSMenu()
            for (title, position, action) in [
                ("文件栏在底部", FilePanelPosition.bottom, #selector(selectBottom)),
                ("文件栏在右侧", FilePanelPosition.right, #selector(selectRight))
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.state = selected == position ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
        }

        @objc private func selectBottom() { onSelect?(.bottom) }
        @objc private func selectRight() { onSelect?(.right) }
    }
}
