import AppKit
import WebKit

// Spike C2: a WKWebView host for the xterm.js client. Test control is by files in $C2_CTL (see poll()).
let env = ProcessInfo.processInfo.environment
let ctlDir = env["C2_CTL"] ?? "/tmp/c2ctl"
let logPath = ctlDir + "/host.log"
let bytesPath = ctlDir + "/bytes.log"
try? FileManager.default.createDirectory(atPath: ctlDir, withIntermediateDirectories: true)

func append(_ path: String, _ s: String) {
    let line = s + "\n"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
}
func log(_ s: String) { append(logPath, String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000)) + s) }

func shellQuote(_ s: String) -> String {
    s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// ---- the web view --------------------------------------------------------------------------------

final class TermWebView: WKWebView {
    var onFiles: (([URL]) -> Void)?
    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !fileURLs(sender).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }
    func webEntered(_ i: NSDraggingInfo) -> NSDragOperation { super.draggingEntered(i) }
    func webUpdated(_ i: NSDraggingInfo) -> NSDragOperation { super.draggingUpdated(i) }
    func webPerform(_ i: NSDraggingInfo) -> Bool { super.performDragOperation(i) }
    // The glue: take dropped files natively and type their quoted paths into the terminal
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        if !urls.isEmpty { log("native drop: \(urls.map(\.path))"); onFiles?(urls); return true }
        return super.performDragOperation(sender)
    }
}

final class Host: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    var web: TermWebView!
    var window: NSWindow!

    func start(url: URL) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "native")
        web = TermWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.onFiles = { [weak self] urls in
            let text = urls.map { shellQuote($0.path) }.joined(separator: " ") + " "
            let lit = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!
            self?.web.evaluateJavaScript("window.__send(\(lit)[0])", completionHandler: nil)
        }
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "c2host"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        web.load(URLRequest(url: url))
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let type = d["type"] as? String else { return }
        switch type {
        case "bytes": append(bytesPath, d["hex"] as? String ?? "")
        case "openURL":
            log("openURL requested: \(d["uri"] ?? "")")
            if env["C2_OPEN"] == "1", let s = d["uri"] as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        default: log("page: \(d)")
        }
    }
    // window.open from the page
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        log("createWebView (window.open) url=\(a.request.url?.absoluteString ?? "nil")")
        return nil
    }
    // confirm() / alert() from the page (xterm.js's default link handler confirms before opening)
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        log("confirm(): \(m)")
        completionHandler(true)
    }
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        log("alert(): \(m)"); completionHandler()
    }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = a.request.url, u.host != "127.0.0.1", a.navigationType == .linkActivated { log("external nav blocked: \(u)"); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("didFinish \(w.url?.absoluteString.prefix(60) ?? "")") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("didFail \(e)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("didFailProvisional \(e)") }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("WEB CONTENT PROCESS TERMINATED") }

    @objc func menuHit(_ s: NSMenuItem) { log("menu: \(s.title)") }
}

// ---- menus ---------------------------------------------------------------------------------------

func buildMenu(host: Host) {
    let main = NSMenu()
    func item(_ title: String, _ sel: Selector?, _ key: String, target: AnyObject? = nil, mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }
    let app = NSMenuItem(); main.addItem(app)
    let appMenu = NSMenu(); app.submenu = appMenu
    appMenu.addItem(item("Quit c2host", #selector(NSApplication.terminate(_:)), "q"))
    let file = NSMenuItem(); main.addItem(file)
    let fileMenu = NSMenu(title: "File"); file.submenu = fileMenu
    fileMenu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
    fileMenu.addItem(item("Session 1", #selector(Host.menuHit(_:)), "1", target: host))
    fileMenu.addItem(item("Session 2", #selector(Host.menuHit(_:)), "2", target: host))
    fileMenu.addItem(item("Clear Terminal", #selector(Host.menuHit(_:)), "k", target: host))
    if env["C2_NO_EDIT_MENU"] != "1" {
        let edit = NSMenuItem(); main.addItem(edit)
        let editMenu = NSMenu(title: "Edit"); edit.submenu = editMenu
        editMenu.addItem(item("Undo", Selector(("undo:")), "z"))
        editMenu.addItem(item("Redo", Selector(("redo:")), "z", mods: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
    }
    NSApp.mainMenu = main
}

// ---- synthetic input -----------------------------------------------------------------------------

let ansiKeys: [Character: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46," ":49,".":47,"/":44,"-":27,":":41,"\\":42,",":43]
let named: [String: (UInt16, String)] = [
    "return": (36, "\r"), "tab": (48, "\t"), "esc": (53, "\u{1b}"), "delete": (51, "\u{7f}"),
    "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
    "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)), "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
]
func flags(_ s: String) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    for m in s.split(separator: ",") {
        switch m { case "cmd": f.insert(.command); case "shift": f.insert(.shift); case "alt": f.insert(.option); case "ctrl": f.insert(.control); default: break }
    }
    return f
}
func sendKey(code: UInt16, chars: String, plain: String, mods: NSEvent.ModifierFlags, window: NSWindow) {
    for down in [true, false] {
        guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code) else { continue }
        NSApp.sendEvent(e)
    }
}
func sendChar(_ c: Character, mods: NSEvent.ModifierFlags, window: NSWindow) {
    let lower = Character(c.lowercased())
    let needsShift = c.isUppercase
    sendKey(code: ansiKeys[lower] ?? 0, chars: String(c), plain: String(lower), mods: needsShift ? mods.union(.shift) : mods, window: window)
}
func sendMouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, mods: NSEvent.ModifierFlags, window: NSWindow) {
    let h = window.contentView!.bounds.height
    let loc = NSPoint(x: x, y: h - y)  // y measured from the top of the content view, like the page
    guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
    if type == .mouseMoved, let v = window.contentView?.hitTest(loc) {
        v.mouseMoved(with: e)  // synthetic moved events skip AppKit's tracking-area routing, so deliver directly
        log("mouseMoved delivered to \(String(describing: Swift.type(of: v)))")
    } else {
        NSApp.sendEvent(e)
    }
}

final class FakeDrag: NSObject, NSDraggingInfo {
    let pb: NSPasteboard; let win: NSWindow
    init(pb: NSPasteboard, win: NSWindow) { self.pb = pb; self.win = win }
    var draggingDestinationWindow: NSWindow? { win }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 300, y: 300) }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

var savedClipboard: [[(NSPasteboard.PasteboardType, Data)]]?
func saveClipboard() {
    savedClipboard = NSPasteboard.general.pasteboardItems?.map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
}
func restoreClipboard() {
    guard let saved = savedClipboard else { return }
    let pb = NSPasteboard.general; pb.clearContents()
    let items = saved.map { entries -> NSPasteboardItem in let i = NSPasteboardItem(); for (t, d) in entries { i.setData(d, forType: t) }; return i }
    pb.writeObjects(items)
    savedClipboard = nil
}

// ---- command channel -----------------------------------------------------------------------------

let host = Host()
var previousApp: NSRunningApplication?

func run(_ line: String, done: @escaping (String) -> Void) {
    let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
    let cmd = parts.first ?? ""; let rest = parts.count > 1 ? parts[1] : ""
    let w = host.window!
    switch cmd {
    case "js":
        host.web.evaluateJavaScript(rest) { r, e in done(e != nil ? "ERR \(e!)" : "\(r ?? "nil")") }
    case "key": // key <name|char> [mods]  e.g. key return shift
        let a = rest.split(separator: " ").map(String.init)
        let mods = flags(a.count > 1 ? a[1] : "")
        if let n = named[a[0]] { sendKey(code: n.0, chars: n.1, plain: n.1, mods: mods, window: w) }
        else if let c = a[0].first { sendChar(c, mods: mods, window: w) }
        done("ok")
    case "type":
        for c in rest { sendChar(c, mods: [], window: w) }
        done("ok")
    case "mouse": // mouse down|up|drag|move x y [mods]
        let a = rest.split(separator: " ").map(String.init)
        guard a.count >= 3, Double(a[1]) != nil, Double(a[2]) != nil else { done("ERR mouse <down|up|drag|move> <x> <y> [mods]"); break }
        let t: NSEvent.EventType = ["down": .leftMouseDown, "up": .leftMouseUp, "drag": .leftMouseDragged, "move": .mouseMoved][a[0]] ?? .mouseMoved
        sendMouse(t, x: CGFloat(Double(a[1])!), y: CGFloat(Double(a[2])!), mods: flags(a.count > 3 ? a[3] : ""), window: w)
        done("ok")
    case "clip-save": saveClipboard(); done("ok")
    case "clip-restore": restoreClipboard(); done("ok")
    case "clip-image":
        let pb = NSPasteboard.general; pb.clearContents()
        if let img = NSImage(contentsOfFile: rest) { pb.writeObjects([img]); done("image on clipboard, types=\(pb.types?.map(\.rawValue) ?? [])") } else { done("bad image") }
    case "clip-text":
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(rest, forType: .string); done("ok")
    case "clip-get": done(NSPasteboard.general.string(forType: .string) ?? "<none>")
    case "drag": // drag <path...> [web]   (web = let WebKit handle it, to see what the page gets)
        var path = rest; var web = false
        if path.hasSuffix(" web") { web = true; path = String(path.dropLast(4)) }
        let pb = NSPasteboard(name: NSPasteboard.Name("c2.drag"))
        pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        let info = FakeDrag(pb: pb, win: w)
        if web {
            let e = host.web.webEntered(info); let u = host.web.webUpdated(info); let ok = host.web.webPerform(info)
            done("WebKit-handled: entered=\(e.rawValue) updated=\(u.rawValue) performed=\(ok)")
        } else {
            let op = host.web.draggingEntered(info); let ok = host.web.performDragOperation(info)
            done("native: op=\(op.rawValue) performed=\(ok)")
        }
    case "shot":
        host.web.takeSnapshot(with: nil) { img, e in
            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { done("ERR \(String(describing: e))"); return }
            try? png.write(to: URL(fileURLWithPath: rest)); done("saved \(rest)")
        }
    case "hide": w.orderOut(nil); done("hidden")
    case "show": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(host.web); done("shown")
    case "mini": w.miniaturize(nil); done("mini")
    case "resize":
        let a = rest.split(separator: " ").map { CGFloat(Double($0)!) }
        w.setContentSize(NSSize(width: a[0], height: a[1])); done("ok")
    case "load": host.web.load(URLRequest(url: URL(string: rest)!)); done("ok")
    case "status":
        host.web.evaluateJavaScript("document.hasFocus()+' active='+document.activeElement?.className") { r, _ in
            done("pid=\(getpid()) key=\(w.isKeyWindow) appActive=\(NSApp.isActive) visible=\(w.isVisible) firstResponder=\(String(describing: type(of: w.firstResponder!))) hasFocus=\(r ?? "?") windowNumber=\(w.windowNumber)")
        }
    case "activate":
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(host.web); done("activated, previous=\(previousApp?.localizedName ?? "none")")
    case "deactivate":
        if let p = previousApp, p.processIdentifier != getpid() { p.activate(options: []) }
        done("restored \(previousApp?.localizedName ?? "none")")
    case "makekey": w.makeKey(); done("isKey=\(w.isKeyWindow)")
    case "quit": done("bye"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    default: done("unknown command \(cmd)")
    }
}

func poll() {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: ctlDir).filter({ $0.hasSuffix(".cmd") }).sorted() else { return }
    for f in files {
        let path = ctlDir + "/" + f
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        try? fm.removeItem(atPath: path)
        let id = String(f.dropLast(4))
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        run(line) { out in try? out.write(toFile: ctlDir + "/" + id + ".out", atomically: true, encoding: .utf8) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(env["C2_ACCESSORY"] == "1" ? .accessory : .regular)
buildMenu(host: host)
host.start(url: URL(string: CommandLine.arguments.dropFirst().first ?? "about:blank")!)
if env["C2_ACTIVATE"] != "0" { app.activate(ignoringOtherApps: true) }
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in poll() }
log("started pid=\(getpid())")
app.run()
