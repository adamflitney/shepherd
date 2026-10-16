import AppKit
import WebKit

/// The dashboard: a window around the page the app's own web server serves at `/dashboard.html` (session list on the left,
/// the selected session's terminal on the right). The page talks to the server over HTTP and a WebSocket like any other
/// browser would; this class only supplies what a web view cannot do for itself: a window that remembers where it was, the
/// Edit menu (without it Cmd+C and Cmd+V do nothing in an app with no menu bar), dropped files, links, and `confirm()`.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    private let serverPort: () async -> UInt16?
    private var window: NSWindow?
    private var web: DashboardWebView?
    private var origin: String?
    private var loaded = false
    private var pendingSelection: String?

    /// `serverPort` makes sure the web server is running and returns its port (nil if it could not start).
    init(serverPort: @escaping () async -> UInt16?) {
        self.serverPort = serverPort
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }
    private var isFrontmost: Bool { window?.isKeyWindow == true && NSApp.isActive }

    /// Shows the window (creating it on first use) and, if given, selects that session.
    func show(selecting sessionID: String? = nil) async {
        guard let port = await serverPort() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The dashboard can't start"
            alert.informativeText = "Shepherd's web server couldn't start, probably because its port is in use. Mobile Access shows which port it uses."
            alert.runModal()
            return
        }
        ensureWindow(port: port)
        if let sessionID {
            pendingSelection = sessionID
            if loaded { selectPending() }
        }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let web { window.makeFirstResponder(web) }
        if let path = ProcessInfo.processInfo.environment["SHEPHERD_DASHBOARD_SNAPSHOT"], loaded { snapshot(to: path, after: 1.5) }
    }

    /// The hotkey: bring it up, or put it away when it is already what you are looking at.
    func toggle() async {
        if isFrontmost { window?.orderOut(nil) } else { await show() }
    }

    // MARK: window

    private func ensureWindow(port: UInt16) {
        let newOrigin = "http://127.0.0.1:\(port)"
        if window != nil, origin == newOrigin { return }
        origin = newOrigin

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.removeAllScriptMessageHandlers()
        configuration.userContentController.add(self, name: "native")
        let web = DashboardWebView(frame: .zero, configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.onFiles = { [weak self] urls in self?.typeIntoTerminal(urls.map { shellQuote($0.path) }.joined(separator: " ") + " ") }
        self.web = web
        loaded = false

        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Shepherd"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 720, height: 420)
            if !window.setFrameUsingName("ShepherdDashboard") { window.center() }
            window.setFrameAutosaveName("ShepherdDashboard")
            self.window = window
        }
        window?.contentView = web
        web.load(URLRequest(url: URL(string: newOrigin + "/dashboard.html")!))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        web?.evaluateJavaScript("window.shepherd && window.shepherd.focusTerminal()", completionHandler: nil)
    }

    // MARK: talking to the page

    private func selectPending() {
        guard let id = pendingSelection, let literal = jsonLiteral(id) else { return }
        pendingSelection = nil
        web?.evaluateJavaScript("window.shepherd && window.shepherd.show(\(literal))", completionHandler: nil)
    }

    /// Types text into the terminal the page is showing (the page owns the connection).
    private func typeIntoTerminal(_ text: String) {
        guard let literal = jsonLiteral(text) else { return }
        web?.evaluateJavaScript("window.__send && window.__send(\(literal))", completionHandler: nil)
    }

    private func jsonLiteral(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]), let text = String(data: data, encoding: .utf8) else { return nil }
        return "\(text)[0]"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "openURL":
            if let text = body["uri"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    // MARK: web view delegates

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        selectPending()
        if let path = ProcessInfo.processInfo.environment["SHEPHERD_DASHBOARD_SNAPSHOT"] { snapshot(to: path, after: 3) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // The page never navigates by itself; a clicked link goes to the browser, never into this window.
        if action.navigationType == .linkActivated {
            if ["http", "https"].contains(url.scheme?.lowercased()) { NSWorkspace.shared.open(url) }
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()) { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    // MARK: development

    /// `SHEPHERD_DASHBOARD_SNAPSHOT=<png path>` writes a picture of the page once it has loaded, to look at the layout
    /// without screen-recording permission.
    private func snapshot(to path: String, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.web?.takeSnapshot(with: nil) { image, _ in
                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

/// A web view that takes dropped files natively. WebKit would hand the page a file with no path; the terminal wants the
/// path, quoted, as if it had been dragged into a terminal window.
final class DashboardWebView: WKWebView {
    var onFiles: (([URL]) -> Void)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles?(urls)
        return true
    }
}

/// `'it'\''s'`: a path as one shell word (plain paths are left as they are).
func shellQuote(_ s: String) -> String {
    s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A menu bar app has no main menu, which leaves Cmd+C, Cmd+V, Cmd+A and Cmd+W with nothing to run when a window is key.
/// This installs the smallest one that makes them work.
@MainActor
enum DashboardMenu {
    static func install() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String, mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let app = NSMenuItem(); main.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(item("Quit Shepherd", #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenuItem(); main.addItem(file)
        let fileMenu = NSMenu(title: "File"); file.submenu = fileMenu
        fileMenu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))

        let edit = NSMenuItem(); main.addItem(edit)
        let editMenu = NSMenu(title: "Edit"); edit.submenu = editMenu
        editMenu.addItem(item("Undo", Selector(("undo:")), "z"))
        editMenu.addItem(item("Redo", Selector(("redo:")), "z", mods: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        NSApp.mainMenu = main
    }
}
