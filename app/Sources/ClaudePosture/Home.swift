import AppKit
import WebKit

/// The Noodle window: a welcome screen with the whole cast idling, where you pick your noodle and
/// try a stretch. Opens from the menu bar, or when Noodle is opened again. See home.html.
@MainActor
final class HomeWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    /// (action, value): "character" with an id, "stretch", or "intro".
    var onAction: ((String, String?) -> Void)?
    /// Opens inside a full-screen app's space instead of switching back to the desktop.
    var floatsOverFullScreen = false

    private let resources: URL
    private var window: NSWindow?
    private var webView: WKWebView?
    private var ready = false
    private var queued: String?

    init(resources: URL) {
        self.resources = resources
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show(_ state: [String: Any]) {
        let w = window ?? make()
        w.collectionBehavior = floatsOverFullScreen ? [.moveToActiveSpace, .fullScreenAuxiliary] : []
        w.level = floatsOverFullScreen ? .floating : .normal
        let reopening = !w.isVisible
        push(state, animate: reopening)
        if reopening { w.center() }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
    }

    /// Keeps an open window current (a new pick from the menu, a stretch done) without replaying the welcome.
    func update(_ state: [String: Any]) {
        if isOpen { push(state, animate: false) }
    }

    private func push(_ state: [String: Any], animate: Bool) {
        let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
        let js = "window.home(\(String(decoding: data, as: UTF8.self)), \(animate))"
        if ready { webView?.evaluateJavaScript(js) } else { queued = js }
    }

    private func make() -> NSWindow {
        let size = NSRect(x: 0, y: 0, width: 680, height: 470)
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: size, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.ignoreWindowOcclusion()
        web.navigationDelegate = self
        cfg.userContentController.add(self, name: "home")
        let w = NSWindow(contentRect: size, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Noodle"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(name: nil) { appearance in   // matches home.html, so opening never flashes white
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x1D / 255, green: 0x19 / 255, blue: 0x17 / 255, alpha: 1)
                : NSColor(srgbRed: 0xFF / 255, green: 0xFC / 255, blue: 0xF9 / 255, alpha: 1)
        }
        w.contentView = web
        w.delegate = self
        web.loadFileURL(resources.appendingPathComponent("home.html"), allowingReadAccessTo: resources)
        window = w
        webView = web
        return w
    }

    // Blank the page as it closes, so reopening plays the welcome instead of flashing the old frame.
    func windowWillClose(_ notification: Notification) {
        webView?.evaluateJavaScript("document.body.classList.remove('shown')")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let js = queued { webView.evaluateJavaScript(js) }
        queued = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.loadFileURL(resources.appendingPathComponent("home.html"), allowingReadAccessTo: resources)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "close" { return window?.performClose(nil) ?? () }
        onAction?(action, body["value"] as? String)
    }
}
