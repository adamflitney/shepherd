import AppKit
import Carbon.HIToolbox
import os
import ShepherdCore
import ShepherdUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let backend: any SessionBackend
    /// Applies a newly-picked terminal app to the live Herdr backend. `nil`
    /// under `--fake`, since there's no real terminal to activate.
    private let onTerminalAppNameChanged: ((String) -> Void)?
    private var store: SessionsStore!
    private var panel: PanelWindow!
    private var statusItemController: StatusItemController!
    private var notificationManager: NotificationManager!

    private let signposter = OSSignposter(subsystem: "com.adamflitney.shepherd", category: "panel")
    private let logger = Logger(subsystem: "com.adamflitney.shepherd", category: "hotkey")

    init(backend: any SessionBackend, onTerminalAppNameChanged: ((String) -> Void)? = nil) {
        self.backend = backend
        self.onTerminalAppNameChanged = onTerminalAppNameChanged
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionsStore(backend: backend)
        self.store = store

        panel = PanelWindow(
            store: store,
            onFocusSession: { [weak self] id in self?.focusSession(id) },
            onCreateSession: { [weak self] request in self?.createSession(request) },
            onPromptSession: { [weak self] id, text in self?.promptSession(id, text: text) },
            onRunInlinePrompt: { [weak self] text, resumeSessionID in
                guard let self else { return .failed("Shepherd is shutting down") }
                return await self.runInlinePrompt(text, resumeSessionID: resumeSessionID)
            },
            onPromoteInlineConversation: { [weak self] sessionID in self?.promoteInlineConversation(sessionID: sessionID) },
            onPeekSession: { [weak self] id in
                guard let self else { throw BackendError.unavailable("Shepherd is shutting down") }
                return try await self.store.peek(id)
            }
        )

        let statusItemController = StatusItemController()
        statusItemController.onToggle = { [weak self] in self?.togglePanel() }
        statusItemController.currentHotkeyBinding = { ShepherdConfig.load().hotkey.switchSession }
        statusItemController.onChangeHotkey = { [weak self] binding in self?.changeHotkey(to: binding) ?? false }
        self.statusItemController = statusItemController

        let notificationManager = NotificationManager()
        notificationManager.onNotificationClicked = { [weak self] id in self?.focusSession(id) }
        self.notificationManager = notificationManager

        statusItemController.notificationsEnabled = { [weak notificationManager] in notificationManager?.isEnabled ?? true }
        statusItemController.onToggleNotifications = { [weak notificationManager] in
            guard let notificationManager else { return }
            notificationManager.setEnabled(!notificationManager.isEnabled)
        }

        statusItemController.currentTerminalAppName = { ShepherdConfig.load().terminal.appName }
        statusItemController.onSelectTerminal = { [weak self] appName in self?.changeTerminal(to: appName) }

        Task { await store.start() }
        observeStoreChanges()
        registerHotkey()
    }

    /// Reads `hotkey.switchSession` from config (default Hyper+W, same
    /// binding mac-sesh used). Falls back to the hardcoded default if the
    /// configured string is malformed, rather than leaving the app with no
    /// hotkey registered at all.
    private func registerHotkey() {
        let configured = ShepherdConfig.load().hotkey.switchSession
        if let parsed = parseHotkey(configured) {
            registerGlobalHotkey(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                self?.toggleQuickSwitcher()
            }
        } else {
            logger.error("Invalid hotkey \"\(configured, privacy: .public)\" in config, falling back to hyper+w")
            registerGlobalHotkey(keyCode: 13, modifiers: Int(cmdKey | controlKey | optionKey | shiftKey)) { [weak self] in
                self?.toggleQuickSwitcher()
            }
        }
    }

    /// Applies a new hotkey binding live (from the menu bar's "Change
    /// Hotkey…" item) and persists it, so it survives the next launch too.
    /// Returns false without touching the current binding if the string
    /// doesn't parse.
    private func changeHotkey(to binding: String) -> Bool {
        guard let parsed = parseHotkey(binding) else { return false }
        unregisterAllHotkeys()
        registerGlobalHotkey(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
            self?.toggleQuickSwitcher()
        }
        var config = ShepherdConfig.load()
        config.hotkey.switchSession = binding
        try? config.save()
        return true
    }

    /// Persists the picked terminal and applies it live to the running
    /// Herdr backend (a no-op under `--fake`), mirroring `changeHotkey`.
    private func changeTerminal(to appName: String) {
        var config = ShepherdConfig.load()
        config.terminal.appName = appName
        try? config.save()
        onTerminalAppNameChanged?(appName)
    }

    /// Keeps the status item icon and notifications in sync outside of
    /// SwiftUI's own view tracking, since `Observation` has no ambient
    /// "did-change" callback - re-registers itself each time it fires.
    private func observeStoreChanges() {
        withObservationTracking {
            _ = store.sections
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let sessions = self.store.sections.flatMap(\.sessions)
                self.statusItemController.update(status: menuBarStatus(for: sessions))
                self.notificationManager.update(sessions: sessions)
                self.observeStoreChanges()
            }
        }
    }

    /// The whole open path: no `await`, no I/O - the store is already
    /// resident and the panel is already built. See the plan's < 50ms budget.
    private func togglePanel() {
        let state = signposter.beginInterval("togglePanel")
        defer { signposter.endInterval("togglePanel", state) }

        if panel.isVisible {
            panel.hide()
        } else {
            panel.present(relativeTo: statusItemController.button)
        }
    }

    /// Same toggle, but centered on screen rather than anchored to the menu
    /// bar button - for the global-hotkey quick switcher, reachable from any
    /// app without first locating the menu bar icon.
    private func toggleQuickSwitcher() {
        if panel.isVisible {
            panel.hide()
        } else {
            panel.presentCentered()
        }
    }

    private func focusSession(_ id: SessionID) {
        Task {
            try? await store.focus(id)
        }
        panel.hide()
    }

    private func createSession(_ request: CreateSessionRequest) {
        Task {
            if let id = try? await store.createSession(request) {
                try? await store.focus(id)
            }
        }
    }

    private func promptSession(_ id: SessionID, text: String) {
        Task {
            try? await store.prompt(id, text: text)
        }
    }

    /// The "home session, baked in" feature: runs one headless, read-only
    /// `claude -p` turn. If it succeeds within those constraints, the
    /// answer is shown inline and the conversation can continue there via
    /// `resumeSessionID`. If not (permission denied, or the model says so
    /// itself via `NEEDS_SESSION`), a real Herdr session is spawned and
    /// focused with the original prompt already sent in - same as picking
    /// an existing session, just arrived at automatically.
    private func runInlinePrompt(_ text: String, resumeSessionID: String?) async -> InlinePromptOutcome {
        do {
            let result = try await ClaudeCLIRunner.run(prompt: text, resumeSessionID: resumeSessionID)
            if shouldEscalateToSession(result) {
                await spawnSession(workingDirectory: homeDirectory, initialPrompt: text, resumeSessionID: nil)
                return .escalated
            }
            return .answered(text: displayText(for: result), sessionID: result.sessionID)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Promotes an inline conversation that answered fine on its own into a
    /// real session anyway - e.g. the user wants to keep going with full
    /// tool access. Continues the exact same `claude` conversation via
    /// `--resume`, so nothing already said is lost.
    private func promoteInlineConversation(sessionID: String) {
        Task {
            await spawnSession(workingDirectory: homeDirectory, initialPrompt: nil, resumeSessionID: sessionID)
        }
    }

    private var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func spawnSession(workingDirectory: URL, initialPrompt: String?, resumeSessionID: String?) async {
        let request = CreateSessionRequest(
            workingDirectory: workingDirectory,
            agent: .claude,
            initialPrompt: initialPrompt,
            resumeSessionID: resumeSessionID
        )
        if let id = try? await store.createSession(request) {
            try? await store.focus(id)
        }
        panel.hide()
    }
}
