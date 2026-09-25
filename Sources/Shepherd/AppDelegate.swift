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

    /// Pre-fetched at launch and every `reviewRefreshIntervalNanoseconds`,
    /// so opening the Review tab shows something instantly instead of
    /// waiting on a live `gh` round trip every time. Deliberately not
    /// ignore-filtered here - see `loadReviewPRs()`.
    private var cachedReviewPRs: [MatchedReviewPR] = []
    private var cachedReviewPRsError: String?
    private var isRefreshingReviewPRs = false
    private var reviewRefreshTask: Task<Void, Never>?
    private let reviewRefreshIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

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
            },
            onLoadReviewPRs: { [weak self] in
                guard let self else { return [] }
                return try await self.loadReviewPRs()
            },
            onStartReviewSession: { [weak self] match in
                guard let self else { return }
                try await self.startReviewSession(match)
            },
            onIgnoreReviewPR: { match in
                IgnoredPRStore().ignore(match.pr.id)
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

        statusItemController.currentAgentKind = { ShepherdConfig.load().agent.kind }
        statusItemController.onSelectAgentKind = { kind in
            var config = ShepherdConfig.load()
            config.agent.kind = kind
            try? config.save()
        }

        statusItemController.currentDefaultSessionDirectory = { ShepherdConfig.load().sessions.defaultDirectory }
        statusItemController.onChangeDefaultSessionDirectory = { directory in
            var config = ShepherdConfig.load()
            config.sessions.defaultDirectory = directory
            try? config.save()
        }

        Task { await store.start() }
        observeStoreChanges()
        registerHotkey()
        startReviewPRRefreshLoop()
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
                await spawnSession(workingDirectory: defaultSessionDirectory, initialPrompt: text, resumeSessionID: nil)
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
            await spawnSession(workingDirectory: defaultSessionDirectory, initialPrompt: nil, resumeSessionID: sessionID)
        }
    }

    /// `sessions.defaultDirectory` from config (default `~`) - a generic,
    /// always-valid default, but overridable (e.g. to `~/dev`) for
    /// better context/memory of prior work if that fits how you use shepherd.
    private var defaultSessionDirectory: URL {
        URL(fileURLWithPath: ShepherdConfig.load().resolvedDefaultSessionDirectory)
    }

    private func spawnSession(workingDirectory: URL, initialPrompt: String?, resumeSessionID: String?) async {
        let request = CreateSessionRequest(
            workingDirectory: workingDirectory,
            agent: ShepherdConfig.load().resolvedAgentKind,
            initialPrompt: initialPrompt,
            resumeSessionID: resumeSessionID
        )
        if let id = try? await store.createSession(request) {
            try? await store.focus(id)
        }
        panel.hide()
    }

    /// Runs immediately (so the cache is already warm by the time anyone
    /// opens the panel) and every `reviewRefreshIntervalNanoseconds`
    /// after that.
    private func startReviewPRRefreshLoop() {
        reviewRefreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshReviewPRCache()
                try? await Task.sleep(nanoseconds: self.reviewRefreshIntervalNanoseconds)
            }
        }
    }

    /// Fetches PRs you're a requested reviewer on, matches each to an
    /// already-scanned local clone (a repo with none found this way is
    /// excluded entirely - Phase 1 doesn't clone), and applies the bot/
    /// staleness filters (not the ignore filter - see `loadReviewPRs()`).
    /// `guard`ed against overlap: the periodic loop and an on-demand
    /// kick from `loadReviewPRs()` could otherwise both be mid-fetch at once.
    private func refreshReviewPRCache() async {
        guard !isRefreshingReviewPRs else { return }
        isRefreshingReviewPRs = true
        defer { isRefreshingReviewPRs = false }

        do {
            let prs = try await GitHubReviewFetcher.fetchReviewPRs()
            let config = ShepherdConfig.load()
            let projects = findGitProjects(in: config.resolvedDirectories).filter { !config.isExcluded($0.path) }
            let localRepos = LocalRepoScanner.scan(projects)
            let options = ReviewFilterOptions(includeBots: config.review.includeBots, hideOlderThanDays: config.review.hideOlderThanDays)
            let filtered = filterReviewPRs(prs, ignored: [], options: options)
            cachedReviewPRs = filtered.compactMap { pr in
                matchingLocalRepo(forSlug: pr.repoSlug, in: localRepos).map { MatchedReviewPR(pr: pr, localPath: $0.path) }
            }
            cachedReviewPRsError = nil
        } catch {
            cachedReviewPRsError = "\(error)"
        }
    }

    /// Returns the pre-fetched cache instantly rather than making the
    /// Review tab wait on a live `gh` round trip on every open, and kicks
    /// a background refresh for next time. The ignore filter is applied
    /// here (not baked into the cache), so ignoring a PR takes effect on
    /// the very next open instead of waiting for the next scheduled
    /// refresh. If the cache is still empty from a launch-time fetch that
    /// hasn't completed yet, this can briefly show nothing rather than a
    /// loading spinner - a one-time, launch-only trade-off for never
    /// blocking on ordinary tab switches.
    private func loadReviewPRs() async throws -> [MatchedReviewPR] {
        Task { await refreshReviewPRCache() }
        let ignored = IgnoredPRStore().load()
        let visible = cachedReviewPRs.filter { !ignored.contains($0.pr.id) }
        if visible.isEmpty, cachedReviewPRs.isEmpty, let cachedReviewPRsError {
            throw ReviewCacheError(message: cachedReviewPRsError)
        }
        return visible
    }

    /// Creates (or reuses) an isolated worktree for the PR's branch, then
    /// starts and focuses a session in it - the same
    /// `CreateSessionRequest`/`workspace.create` + `agent.start` path the
    /// project picker already uses, just pointed at the worktree instead.
    private func startReviewSession(_ match: MatchedReviewPR) async throws {
        let worktreePath = try PRWorktree.ensureWorktree(
            repoPath: match.localPath, repoSlug: match.pr.repoSlug, prNumber: match.pr.number
        )
        let request = CreateSessionRequest(
            workingDirectory: worktreePath,
            agent: ShepherdConfig.load().resolvedAgentKind,
            initialPrompt: reviewPrompt(for: match.pr),
            title: match.pr.title
        )
        let id = try await store.createSession(request)
        try await store.focus(id)
    }

    private func reviewPrompt(for pr: ReviewPR) -> String {
        """
        Please review this pull request: \(pr.title)
        \(pr.url)

        Give me a summary of the changes and flag anything that looks concerning or worth discussing.
        """
    }
}

private struct ReviewCacheError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
