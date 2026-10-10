import SwiftUI
import WebKit

final class SearchableTerminalWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            evaluateJavaScript("window.huOpenFind?.()")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct TerminalView: NSViewRepresentable {
    var content: String
    var findRequest: Int
    var onInput: (String) -> Void
    var onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "input")
        configuration.userContentController.add(context.coordinator, name: "resize")
        let webView = SearchableTerminalWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        let bundled = Bundle.main.resourceURL ?? URL(fileURLWithPath: "")
        let resources = FileManager.default.fileExists(atPath: bundled.appendingPathComponent("terminal.html").path)
            ? bundled : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/HuShell/Resources")
        let html = resources.appendingPathComponent("terminal.html")
        webView.loadFileURL(html, allowingReadAccessTo: resources)
        return webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.update(content)
        context.coordinator.updateFindRequest(findRequest)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onInput: ((String) -> Void)?
        var onResize: ((Int, Int) -> Void)?
        private var ready = false
        private var delivered = ""
        private var pending = ""
        private var lastFindRequest = 0
        private var pendingFind = false

        func updateFindRequest(_ request: Int) {
            guard request != lastFindRequest else { return }
            lastFindRequest = request
            pendingFind = true
            openPendingFind()
        }

        private func openPendingFind() {
            guard ready, pendingFind, let webView else { return }
            pendingFind = false
            webView.evaluateJavaScript("window.huOpenFind()")
        }

        func update(_ content: String) {
            pending = content
            guard ready, let webView else { return }
            if !content.hasPrefix(delivered) {
                webView.evaluateJavaScript("window.huClear()")
                delivered = ""
            }
            let delta = String(content.dropFirst(delivered.count))
            guard !delta.isEmpty else { return }
            delivered = content
            let argument = String(decoding: try! JSONEncoder().encode(delta), as: UTF8.self)
            webView.evaluateJavaScript("window.huAppend(\(argument))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            update(pending)
            openPendingFind()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "input", let text = message.body as? String { onInput?(text) }
            if message.name == "resize", let dimensions = message.body as? [String: Int],
               let columns = dimensions["cols"], let rows = dimensions["rows"] {
                onResize?(columns, rows)
            }
        }
    }
}
