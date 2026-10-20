import AppKit
import Carbon.HIToolbox
import os
import ShepherdCore
import ShepherdHolderBackend
import ShepherdTerminalBridge
import ShepherdTasks
import ShepherdUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let backend: any SessionBackend
    private let terminals: TerminalBridgeConfig?
    private var dashboard: DashboardWindowController?
    /// Applies a newly-picked terminal app to the live Herdr backend. `nil`
    /// under `--fake`, since there's no real terminal to activate.
    private let onTerminalAppNameChanged: ((String) -> Void)?
    /// Set when agents run in Ghostty: makes its front window the agents window, and returns where it
    /// ended up (or throws).
    private let useFrontGhosttyWindow: (() async throws -> Void)?
    private var store: SessionsStore!
    private var panel: PanelWindow!
    private var statusItemController: StatusItemController!
    private var notificationManager: NotificationManager!
    private var mobileAccess: MobileAccessModel!
    private var mobileAccessWindow: MobileAccessWindowController!

    private let signposter = OSSignposter(subsystem: "com.adamflitney.shepherd", category: "panel")
    private let logger = Logger(subsystem: "com.adamflitney.shepherd", category: "hotkey")

    /// Pre-fetched at launch and every `reviewRefreshIntervalNanoseconds`,
    /// so opening the Review tab shows something instantly instead of
    /// waiting on a live `gh` round trip every time. Deliberately not
    /// ignore-filtered here - see `loadReviewPRs()`.
    private var cachedReviewPRs: [MatchedReviewPR] = []
    private var cachedReviewPRsError: String?
    private var reviewRefreshInFlight: Task<Void, Never>?
    private var hasFetchedReviewPRs = false
    private var reviewRefreshTask: Task<Void, Never>?
    private let reviewRefreshIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    init(
        backend: any SessionBackend,
        onTerminalAppNameChanged: ((String) -> Void)? = nil,
        useFrontGhosttyWindow: (() async throws -> Void)? = nil,
        terminals: TerminalBridgeConfig? = nil
    ) {
        self.terminals = terminals
        self.backend = backend
        self.onTerminalAppNameChanged = onTerminalAppNameChanged
        self.useFrontGhosttyWindow = useFrontGhosttyWindow
        super.init()
    }

    private static var isFake: Bool { CommandLine.arguments.contains("--fake") }

    /// `--demo-panel=<sessions|create|ask|review>` with optional
    /// `--demo-query=<text>`: opens the panel on that tab at launch, for
    /// README screenshots. Pair with `--fake`.
    private static func demoStartFromArguments() -> PanelDemoStart? {
        func value(_ flag: String) -> String? {
            CommandLine.arguments.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
        }
        guard let tab = value("--demo-panel") else { return nil }
        return PanelDemoStart(tab: tab, query: value("--demo-query") ?? "")
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
            },
            onRestoreReviewPR: { match in
                IgnoredPRStore().unignore(match.pr.id)
            },
            onOpenReviewPRInBrowser: { match in
                if let url = URL(string: match.pr.url) { NSWorkspace.shared.open(url) }
            },
            onLoadTasks: { TaskStore().list().map(TaskSummary.init) },
            onStartTask: { [weak self] task in
                guard let self else { return }
                try await self.startTask(task)
            },
            onCreateTask: { [weak self] title in
                guard let self else { return }
                try await self.createTask(title: title)
            },
            onFinishTask: { task in
                _ = try? TaskStore().update(task.id) { $0.setStatus(.done) }
            },
            onOpenBoard: backend is HolderSessionBackend ? { [weak self] in self?.openBoard() } : nil,
            demoStart: Self.demoStartFromArguments()
        )

        let statusItemController = StatusItemController()
        statusItemController.onToggle = { [weak self] in self?.togglePanel() }

        let mobileAccess = MobileAccessModel(backend: backend, terminals: terminals)
        self.mobileAccess = mobileAccess
        mobileAccessWindow = MobileAccessWindowController(model: mobileAccess)
        statusItemController.onShowMobileAccess = { [weak self] in self?.mobileAccessWindow.show() }
        mobileAccess.startIfEnabled()
        if CommandLine.arguments.contains("--show-mobile-access") { mobileAccessWindow.show() }
        if Self.demoStartFromArguments() != nil {
            DispatchQueue.main.async { [weak self] in self?.panel.presentCentered() }
        }

        // With the holder backend the dashboard is the place sessions are shown: "go to a session" anywhere (the panel, a
        // notification, a task) lands there.
        if let holderBackend = backend as? HolderSessionBackend {
            let dashboard = DashboardWindowController(serverPort: { await mobileAccess.ensureServer() })
            self.dashboard = dashboard
            DashboardMenu.install()
            statusItemController.onShowDashboard = { Task { await dashboard.show() } }
            Task { await holderBackend.setShowSession { id in await dashboard.show(selecting: id.rawValue) } }
            if CommandLine.arguments.contains("--show-dashboard") { Task { await dashboard.show() } }
        }

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
        if let useFrontGhosttyWindow {
            statusItemController.onUseFrontGhosttyWindow = {
                Task { @MainActor in
                    let alert = NSAlert()
                    do {
                        try await useFrontGhosttyWindow()
                        alert.messageText = "Agent tabs will open in that window"
                        alert.informativeText = "New sessions start as tabs in Ghostty's front window. Put the window where you want it."
                    } catch {
                        alert.alertStyle = .warning
                        alert.messageText = "Couldn't use that window"
                        alert.informativeText = "\(error)"
                    }
                    alert.runModal()
                }
            }
        }

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
    /// hotkey registered at all. With the holder backend, `hotkey.dashboard`
    /// (default Hyper+D) opens the dashboard.
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
        if dashboard != nil, let parsed = parseHotkey(ShepherdConfig.load().hotkey.resolvedDashboard) {
            registerGlobalHotkey(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                guard let dashboard = self?.dashboard else { return }
                Task { await dashboard.toggle() }
            }
        }
    }

    /// Applies a new hotkey binding live (from the menu bar's "Change
    /// Hotkey…" item) and persists it, so it survives the next launch too.
    /// Returns false without touching the current binding if the string
    /// doesn't parse.
    private func changeHotkey(to binding: String) -> Bool {
        guard parseHotkey(binding) != nil else { return false }
        var config = ShepherdConfig.load()
        config.hotkey.switchSession = binding
        try? config.save()
        unregisterAllHotkeys()
        registerHotkey()
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

    /// The panel's "Board" button: the task board lives in the dashboard window.
    private func openBoard() {
        guard let dashboard else { return }
        Task { await dashboard.show(board: true) }
    }

    private func focusSession(_ id: SessionID) {
        Task {
            try? await store.focus(id)
        }
        panel.hide()
    }

    /// Goes to a task's live session if it has one; otherwise starts (or resumes) one in the task's
    /// project, and moves the task out of the inbox.
    private func startTask(_ task: TaskSummary) async throws {
        if let live = store.sections.flatMap(\.sessions).first(where: { $0.group?.id == task.groupID }) {
            try await store.focus(live.id)
            return
        }
        let config = ShepherdConfig.load()
        let directory = task.projectPath ?? config.resolvedDefaultSessionDirectory
        let id = try await store.createSession(CreateSessionRequest(
            workingDirectory: URL(fileURLWithPath: directory),
            agent: config.resolvedAgentKind,
            taskID: task.id
        ))
        if task.status == "inbox" || task.status == "ready" {
            _ = try? TaskStore().update(task.id) { $0.setStatus(.active) }
        }
        try? await store.focus(id)
    }

    /// A task captured from the panel lands in the inbox, in the focused session's project when there
    /// is one (otherwise the default directory), so it can be started later.
    private func createTask(title: String) async throws {
        let config = ShepherdConfig.load()
        let focused = store.sections.flatMap(\.sessions).first(where: { $0.isFocused })?.workingDirectory?.path
        try TaskStore().create(NewTask(title: title, projectPath: focused ?? config.resolvedDefaultSessionDirectory))
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
        if Self.isFake { return .answered(text: DemoReviewPRs.askAnswer, sessionID: "demo") }
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
    /// already-scanned local clone (none found means it's cloned on
    /// demand when you start the review), and applies the bot/
    /// staleness filters (not the ignore filter - see `loadReviewPRs()`).
    /// `guard`ed against overlap: the periodic loop and an on-demand
    /// kick from `loadReviewPRs()` could otherwise both be mid-fetch at once.
    private func refreshReviewPRCache() async {
        if let reviewRefreshInFlight {
            await reviewRefreshInFlight.value
            return
        }
        let task = Task { await fetchReviewPRCache() }
        reviewRefreshInFlight = task
        await task.value
        reviewRefreshInFlight = nil
    }

    private func fetchReviewPRCache() async {
        do {
            let prs = try await GitHubReviewFetcher.fetchReviewPRs()
            let config = ShepherdConfig.load()
            let projects = findGitProjects(in: config.resolvedDirectories).filter { !config.isExcluded($0.path) }
            let localRepos = LocalRepoScanner.scan(projects)
            let options = ReviewFilterOptions(includeBots: config.review.includeBots, hideOlderThanDays: config.review.hideOlderThanDays)
            let filtered = filterReviewPRs(prs, ignored: [], options: options)
            cachedReviewPRs = filtered.map { pr in
                MatchedReviewPR(pr: pr, localPath: matchingLocalRepo(forSlug: pr.repoSlug, in: localRepos)?.path)
            }
            cachedReviewPRsError = nil
            hasFetchedReviewPRs = true
        } catch {
            cachedReviewPRsError = "\(error)"
        }
    }

    /// Returns the pre-fetched cache instantly rather than making the
    /// Review tab wait on a live `gh` round trip on every open, and kicks
    /// a background refresh for next time. The ignore filter is applied
    /// here (not baked into the cache), so ignoring a PR takes effect on
    /// the very next open instead of waiting for the next scheduled
    /// refresh (ignored PRs are returned flagged, for the `%` view). Until the first fetch has succeeded this waits for it (the
    /// tab shows its spinner) instead of returning an empty list that
    /// would never update.
    private func loadReviewPRs() async throws -> [MatchedReviewPR] {
        if Self.isFake { return DemoReviewPRs.all }
        if hasFetchedReviewPRs {
            Task { await refreshReviewPRCache() }
        } else {
            await refreshReviewPRCache()
        }
        let ignored = IgnoredPRStore().load()
        let visible = cachedReviewPRs.map { match in
            var match = match
            match.isIgnored = ignored.contains(match.pr.id)
            return match
        }
        if !hasFetchedReviewPRs, let cachedReviewPRsError {
            throw ReviewCacheError(message: cachedReviewPRsError)
        }
        return visible
    }

    /// Creates (or reuses) an isolated worktree for the PR's branch, then
    /// starts and focuses a session in it - the same
    /// `CreateSessionRequest`/`workspace.create` + `agent.start` path the
    /// project picker already uses, just pointed at the worktree instead.
    private func startReviewSession(_ match: MatchedReviewPR) async throws {
        let repoPath = try await localClonePath(for: match)
        let worktreePath = try PRWorktree.ensureWorktree(
            repoPath: repoPath, repoSlug: match.pr.repoSlug, prNumber: match.pr.number
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

    private func localClonePath(for match: MatchedReviewPR) async throws -> String {
        if let localPath = match.localPath { return localPath }
        guard let directory = ShepherdConfig.load().resolvedDirectories.first else {
            throw ReviewCacheError(message: "No project directory is configured to clone into.")
        }
        let destination = cloneDestination(forSlug: match.pr.repoSlug, in: directory)
        if !FileManager.default.fileExists(atPath: destination) {
            try await GitHubReviewFetcher.cloneRepo(slug: match.pr.repoSlug, to: destination)
        }
        return destination
    }

    private func reviewPrompt(for pr: ReviewPR) -> String {
        if pr.isMine {
            return """
            This is my own pull request: \(pr.title)
            \(pr.url)

            Summarize where it stands: any review comments I still need to address, and any failing checks and why.
            """
        }
        return """
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

extension TaskSummary {
    init(_ task: TaskFile) {
        self.init(
            id: task.id, title: task.title, objective: task.objective, projectPath: task.projectPath,
            status: task.status.rawValue, progressDone: task.progress.done, progressTotal: task.progress.total,
            sessionIDs: task.sessions)
    }
}
