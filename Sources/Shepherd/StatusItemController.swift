import AppKit
import ServiceManagement
import ShepherdCore
import ShepherdUI

/// Owns the `NSStatusItem` and keeps its icon in sync with `menuBarStatus`.
/// Images are cached per worst-kind (5 possible values) so redrawing only
/// happens once per kind ever, not once per event - the count is shown via
/// the button's title text, which costs nothing to update on every change.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var imageCache: [AttentionState.Kind: NSImage] = [:]
    var onToggle: (() -> Void)?
    /// Supplies the currently-configured binding to prefill the "Change
    /// Hotkey…" prompt - read fresh each time rather than cached, since it
    /// can also change via editing the config file directly.
    var currentHotkeyBinding: (() -> String)?
    /// Applies a newly-entered binding; returns false (and the prompt
    /// re-shows an error) if it doesn't parse.
    var onChangeHotkey: ((String) -> Bool)?

    var button: NSStatusBarButton? { statusItem.button }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        update(status: MenuBarStatus(worstKind: .unknown, count: 0))
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            onToggle?()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let installed = HookInstaller.isInstalled()
        menu.addItem(NSMenuItem(
            title: installed ? "Uninstall Hooks…" : "Install Hooks…",
            action: #selector(toggleHooks),
            keyEquivalent: ""
        ))
        menu.items.last?.target = self
        menu.addItem(.separator())
        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        let changeHotkeyItem = NSMenuItem(title: "Change Hotkey…", action: #selector(promptForHotkey), keyEquivalent: "")
        changeHotkeyItem.target = self
        menu.addItem(changeHotkeyItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Shepherd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleHooks() {
        do {
            if HookInstaller.isInstalled() {
                try HookInstaller.uninstall()
            } else {
                try HookInstaller.install()
            }
        } catch {
            NSLog("Shepherd hook install/uninstall failed: \(error)")
        }
    }

    /// Presents a text-entry alert prefilled with the current binding.
    /// Re-prompts (with the invalid text still in the field) if the
    /// entered string doesn't parse, rather than silently discarding it.
    @objc private func promptForHotkey() {
        let field = NSTextField(string: currentHotkeyBinding?() ?? "hyper+w")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)

        let alert = NSAlert()
        alert.messageText = "Change Quick-Switcher Hotkey"
        alert.informativeText = "Modifiers (cmd/shift/opt/ctrl, or hyper for all four) plus one key, joined with \"+\", e.g. \"cmd+shift+k\"."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
        if onChangeHotkey?(entered) != true {
            let error = NSAlert()
            error.messageText = "Couldn't parse \"\(entered)\""
            error.informativeText = "The hotkey wasn't changed."
            error.runModal()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Shepherd launch-at-login toggle failed: \(error)")
        }
    }

    func update(status: MenuBarStatus) {
        statusItem.button?.image = image(for: status.worstKind)
        statusItem.button?.title = status.count > 1 ? " \(status.count)" : ""
    }

    /// The real system menu bar (unlike an ordinary toolbar button) forces
    /// template images to its own monochrome tint and ignores
    /// `contentTintColor` entirely - that's what turned `done` black instead
    /// of green. The colour has to be baked into the image itself via a
    /// symbol configuration, with `isTemplate = false` so the system leaves
    /// it alone. Plain `paletteColors` recolors every layer solidly, which
    /// flattened the checkmark/circle into one solid blob - `.preferringMonochrome()`
    /// keeps the same single-colour rendering `SessionRowView` uses
    /// (`.symbolRenderingMode(.monochrome)`), preserving the glyph's cutout.
    private func image(for kind: AttentionState.Kind) -> NSImage {
        if let cached = imageCache[kind] { return cached }
        let display = attentionDisplay(for: kind)
        var image = NSImage(systemSymbolName: display.symbolName, accessibilityDescription: display.label)
            ?? NSImage()
        let configuration = NSImage.SymbolConfiguration(paletteColors: [tintColor(for: kind)])
            .applying(.preferringMonochrome())
        if let configured = image.withSymbolConfiguration(configuration) {
            image = configured
        }
        image.isTemplate = false
        imageCache[kind] = image
        return image
    }

    /// Mirrors `SessionRowView.badgeColor` exactly - keep the two in sync.
    private func tintColor(for kind: AttentionState.Kind) -> NSColor {
        switch kind {
        case .blocked: .systemRed
        case .done: .systemGreen
        case .working: .systemBlue
        case .idle: .secondaryLabelColor
        case .unknown: .systemGray
        }
    }
}
