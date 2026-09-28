import SwiftUI
import WebKit

struct TerminalView: NSViewRepresentable {
    var content: String
    var onInput: (String) -> Void
    var onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "input")
        configuration.userContentController.add(context.coordinator, name: "resize")
        let webView = WKWebView(frame: .zero, configuration: configuration)
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
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onInput: ((String) -> Void)?
        var onResize: ((Int, Int) -> Void)?
        private var ready = false
        private var delivered = ""
        private var pending = ""

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
