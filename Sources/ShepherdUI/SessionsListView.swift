import AppKit
import SwiftUI
import ShepherdCore

/// The panel's content view. Selection/keyboard-nav mirrors mac-sesh's
/// SearchView: an AppKit local event monitor rather than SwiftUI's
/// `.onKeyPress`, since that's the pattern already proven to work inside a
/// borderless `NSPanel`. Rows use a plain `VStack`, not `LazyVStack` - mac-sesh
/// found `LazyVStack` serves stale rows, and at 6-20 sessions there's no
/// performance reason to virtualize.
public struct SessionsListView: View {
    let store: SessionsStore
    let onFocusSession: (SessionID) -> Void
    let onDismiss: () -> Void
    let onCreateSession: (CreateSessionRequest) -> Void
    let onPromptSession: (SessionID, String) -> Void
    let onRunInlinePrompt: (String, String?) async -> InlinePromptOutcome
    let onPromoteInlineConversation: (String) -> Void
    let onPeekSession: (SessionID) async throws -> String

    private enum Mode: Equatable {
        case sessions
        case createProject
        case prompt
    }

    private struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let prompt: String
        let response: String
    }

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @State private var mode: Mode = .sessions
    @State private var projects: [Project] = []
    @State private var promptingSessionID: SessionID?
    @State private var promptText = ""

    @State private var exchanges: [Exchange] = []
    @State private var promptConversationID: String?
    @State private var isRunningInlinePrompt = false
    @State private var inlinePromptError: String?

    @State private var peekingSessionID: SessionID?
    @State private var peekText: String?
    @State private var peekError: String?
    @State private var isLoadingPeek = false

    public init(
        store: SessionsStore,
        onFocusSession: @escaping (SessionID) -> Void,
        onDismiss: @escaping () -> Void,
        onCreateSession: @escaping (CreateSessionRequest) -> Void,
        onPromptSession: @escaping (SessionID, String) -> Void,
        onRunInlinePrompt: @escaping (String, String?) async -> InlinePromptOutcome,
        onPromoteInlineConversation: @escaping (String) -> Void,
        onPeekSession: @escaping (SessionID) async throws -> String
    ) {
        self.store = store
        self.onFocusSession = onFocusSession
        self.onDismiss = onDismiss
        self.onCreateSession = onCreateSession
        self.onPromptSession = onPromptSession
        self.onRunInlinePrompt = onRunInlinePrompt
        self.onPromoteInlineConversation = onPromoteInlineConversation
        self.onPeekSession = onPeekSession
    }

    /// All sessions, unfiltered, in the store's own urgency-then-group order.
    private var flatSessions: [Session] {
        store.sections.flatMap(\.sessions)
    }

    /// What's actually shown: fuzzy-filtered by `query` (identity order when
    /// empty), matching mac-sesh's quick-switcher behaviour.
    private var displayedSessions: [Session] {
        filterSessions(flatSessions, query: query)
    }

    /// Frecency-sorted by `loadProjects()`; further fuzzy-filtered/re-ranked
    /// by `query` the same way mac-sesh's project switcher works.
    private var displayedProjects: [Project] {
        filterProjects(projects, query: query)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            modeTabBar
            searchBar
            Divider()
            if store.isStale {
                staleBanner
            }
            content
        }
        .frame(width: 360, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: query) { selectedIndex = 0 }
        .onAppear {
            installKeyMonitor()
            // Delay is required: @FocusState set before the NSPanel becomes
            // key is silently ignored - same workaround as mac-sesh's SearchView.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                searchFocused = true
            }
        }
        .onDisappear {
            removeKeyMonitor()
            // The panel is pre-warmed and reused, not rebuilt per-present, so
            // this state would otherwise leak into the next open - reset it
            // so the switcher always starts fresh.
            query = ""
            selectedIndex = 0
            mode = .sessions
            resetInlinePromptState()
            closePeek()
        }
    }

    private func resetInlinePromptState() {
        exchanges = []
        promptConversationID = nil
        isRunningInlinePrompt = false
        inlinePromptError = nil
    }

    private var header: some View {
        HStack {
            Text("shepherd").font(.headline)
            Spacer()
            Button {
                advanceMode()
            } label: {
                Image(systemName: headerIconName)
            }
            .buttonStyle(.plain)
            .help(headerHelpText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var headerIconName: String {
        switch mode {
        case .sessions: "plus.circle"
        case .createProject: "bubble.left.and.text.bubble.right"
        case .prompt: "xmark.circle"
        }
    }

    private var headerHelpText: String {
        switch mode {
        case .sessions: "New session in a project (Tab)"
        case .createProject: "Ask Claude directly (Tab)"
        case .prompt: "Back to sessions (Tab/Esc)"
        }
    }

    /// Labeled, directly-clickable alternative to the header button's cycle -
    /// makes which of the three modes is active visually unambiguous, since
    /// the header icon alone only hints at where Tab goes *next*.
    private var modeTabBar: some View {
        HStack(spacing: 4) {
            modeTab("Switch", mode: .sessions)
            modeTab("Create", mode: .createProject)
            modeTab("Ask", mode: .prompt)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func modeTab(_ title: String, mode targetMode: Mode) -> some View {
        let isActive = mode == targetMode
        return Button {
            setMode(targetMode)
        } label: {
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    /// Tab and the header button both cycle sessions -> createProject ->
    /// prompt -> sessions; `modeTabBar` jumps straight to any of the three.
    /// Escape (`handleEscape`) is the shortcut back to `.sessions` from
    /// either sub-mode without completing the cycle.
    private func advanceMode() {
        switch mode {
        case .sessions: setMode(.createProject)
        case .createProject: setMode(.prompt)
        case .prompt: setMode(.sessions)
        }
    }

    private func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        query = ""
        selectedIndex = 0
        // Deliberately NOT resetting inline-prompt state here - switching
        // tabs to check something else and coming back to Ask should find
        // the conversation still there; `startNewInlinePrompt()` is the
        // explicit way to clear it.
        closePeek()
        mode = newMode
        if newMode == .createProject {
            loadProjects()
        }
        searchFocused = true
    }

    /// The explicit "wipe it and start over" action for the Ask tab -
    /// switching tabs and back no longer clears the conversation on its
    /// own, so this is how a genuinely new one gets started.
    private func startNewInlinePrompt() {
        resetInlinePromptState()
        query = ""
    }

    /// Project discovery + frecency scoring is a disk scan and a UserDefaults
    /// read - done once on entering create mode, not per keystroke. `query`
    /// only re-ranks the already-loaded list (see `displayedProjects`).
    private func loadProjects() {
        let config = ShepherdConfig.load()
        let found = findGitProjects(in: config.resolvedDirectories)
            .filter { !config.isExcluded($0.path) }
        projects = scored(found, visits: loadVisits())
    }

    private var searchBarPlaceholder: String {
        switch mode {
        case .sessions: "Switch to session..."
        case .createProject: "New session in project..."
        case .prompt: "Ask Claude anything..."
        }
    }

    private var searchBarIconName: String {
        mode == .prompt ? "bubble.left" : "magnifyingglass"
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: searchBarIconName)
                .foregroundStyle(.secondary)
            TextField(searchBarPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .disabled(mode == .prompt && isRunningInlinePrompt)
            if mode == .prompt && isRunningInlinePrompt {
                ProgressView().controlSize(.small)
            }
            if mode == .prompt && hasInlineConversation && !isRunningInlinePrompt {
                Button(action: startNewInlinePrompt) {
                    Image(systemName: "plus.bubble")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Start a new conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var hasInlineConversation: Bool {
        !exchanges.isEmpty || promptConversationID != nil || inlinePromptError != nil
    }

    private func promptForm(for sessionID: SessionID) -> some View {
        HStack {
            TextField("Send a prompt…", text: $promptText, onCommit: { submitPrompt(to: sessionID) })
                .textFieldStyle(.roundedBorder)
            Button("Send") { submitPrompt(to: sessionID) }
                .disabled(promptText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func submitPrompt(to sessionID: SessionID) {
        guard !promptText.isEmpty else { return }
        onPromptSession(sessionID, promptText)
        promptText = ""
        promptingSessionID = nil
    }

    private var staleBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(staleBannerText)
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var staleBannerText: String {
        if case .unavailable(let reason) = store.connection {
            return "Not connected: \(reason)"
        }
        return "Not connected"
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .sessions:
            if let peekingSessionID {
                peekView(for: peekingSessionID)
            } else {
                sessionList
            }
        case .createProject:
            projectList
        case .prompt:
            promptConversation
        }
    }

    /// A one-shot look at a session's current screen, without switching to
    /// it - `pane.read`'s raw "visible" text, trimmed of the padding blank
    /// lines a terminal fills its height with, but otherwise unparsed. See
    /// `SessionBackend.peek`'s doc comment for why this doesn't try to
    /// extract a structured "last message."
    @ViewBuilder
    private func peekView(for sessionID: SessionID) -> some View {
        let session = flatSessions.first(where: { $0.id == sessionID })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(session?.group?.label ?? session?.title ?? sessionID.rawValue)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("← back")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                Group {
                    if isLoadingPeek {
                        ProgressView().controlSize(.small)
                    } else if let peekError {
                        Text(peekError).foregroundStyle(.red)
                    } else if let peekText {
                        Text(peekText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var promptConversation: some View {
        if exchanges.isEmpty && !isRunningInlinePrompt && inlinePromptError == nil {
            emptyState("Ask a quick question, or describe work to hand off to a session")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(exchanges) { exchange in
                            ExchangeView(prompt: exchange.prompt, response: exchange.response)
                        }
                        if let inlinePromptError {
                            Text(inlinePromptError)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: exchanges) { withAnimation { proxy.scrollTo("bottom") } }
            }
            if promptConversationID != nil, !isRunningInlinePrompt {
                HStack {
                    Spacer()
                    Button("Continue in a session (⌘⏎)") {
                        promoteCurrentConversation()
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        let sessions = displayedSessions
        if sessions.isEmpty {
            emptyState(query.isEmpty ? "No sessions" : "No matches for \"\(query)\"")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRowView(
                                session: session,
                                isSelected: index == selectedIndex,
                                onPrompt: { promptingSessionID = session.id }
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onFocusSession(session.id) }

                            if promptingSessionID == session.id {
                                promptForm(for: session.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                // Arrow-key navigation moves `selectedIndex` but a plain
                // ScrollView never follows it on its own - without this the
                // selection can scroll out of view entirely.
                .onChange(of: selectedIndex) { proxy.scrollTo(selectedIndex) }
            }
        }
    }

    @ViewBuilder
    private var projectList: some View {
        let projects = displayedProjects
        if projects.isEmpty {
            emptyState(query.isEmpty ? "No projects found in ~/dev" : "No matches for \"\(query)\"")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                            ProjectRow(project: project, isSelected: index == selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { submitCreateProject(project) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedIndex) { proxy.scrollTo(selectedIndex) }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func submitCreateProject(_ project: Project) {
        recordVisit(to: project.path)
        onCreateSession(CreateSessionRequest(workingDirectory: URL(fileURLWithPath: project.path), agent: .claude))
        onDismiss()
    }

    private func promoteCurrentConversation() {
        guard let promptConversationID, !isRunningInlinePrompt else { return }
        onPromoteInlineConversation(promptConversationID)
        onDismiss()
    }

    private func startPeek(_ id: SessionID) {
        peekingSessionID = id
        peekText = nil
        peekError = nil
        isLoadingPeek = true
        Task {
            do {
                let text = try await onPeekSession(id)
                peekText = trimmedPeekText(text)
            } catch {
                peekError = "\(error)"
            }
            isLoadingPeek = false
        }
    }

    private func closePeek() {
        peekingSessionID = nil
        peekText = nil
        peekError = nil
        isLoadingPeek = false
    }

    // MARK: - Keyboard navigation

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 125: moveSelection(by: 1); return nil // down arrow
            case 126: moveSelection(by: -1); return nil // up arrow
            case 36, 76:
                if mode == .prompt, event.modifierFlags.contains(.command) {
                    promoteCurrentConversation() // cmd+return - "Continue in a session"
                } else {
                    activateSelected()
                }
                return nil
            case 53: handleEscape(); return nil // escape
            case 48: advanceMode(); return nil // tab - cycle sessions/new-project/prompt mode
            case 124: // right arrow - peek at the selected session's screen
                if mode == .sessions, peekingSessionID == nil, displayedSessions.indices.contains(selectedIndex) {
                    startPeek(displayedSessions[selectedIndex].id)
                    return nil
                }
                return event
            case 123: // left arrow - close the peek, back to the list
                if peekingSessionID != nil {
                    closePeek()
                    return nil
                }
                return event
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Escape backs out of a sub-mode straight to `.sessions` first, then
    /// dismisses the panel - mirrors how the header button's own cycle
    /// always has a path back.
    private func handleEscape() {
        if peekingSessionID != nil {
            closePeek()
        } else if mode != .sessions {
            mode = .sessions
            query = ""
            selectedIndex = 0
            resetInlinePromptState()
            searchFocused = true
        } else {
            onDismiss()
        }
    }

    private var displayedCount: Int {
        switch mode {
        case .sessions: displayedSessions.count
        case .createProject: displayedProjects.count
        case .prompt: 0
        }
    }

    private func moveSelection(by delta: Int) {
        guard displayedCount > 0 else { return }
        selectedIndex = max(0, min(displayedCount - 1, selectedIndex + delta))
    }

    private func activateSelected() {
        switch mode {
        case .sessions:
            let sessions = displayedSessions
            guard sessions.indices.contains(selectedIndex) else { return }
            onFocusSession(sessions[selectedIndex].id)
        case .createProject:
            let projects = displayedProjects
            guard projects.indices.contains(selectedIndex) else { return }
            submitCreateProject(projects[selectedIndex])
        case .prompt:
            submitInlinePrompt()
        }
    }

    private func submitInlinePrompt() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunningInlinePrompt else { return }
        query = ""
        isRunningInlinePrompt = true
        inlinePromptError = nil
        let resumeID = promptConversationID
        Task {
            let outcome = await onRunInlinePrompt(text, resumeID)
            isRunningInlinePrompt = false
            switch outcome {
            case .answered(let responseText, let sessionID):
                promptConversationID = sessionID
                exchanges.append(Exchange(prompt: text, response: responseText))
            case .escalated:
                break // AppDelegate already spawned/focused a session and hid the panel
            case .failed(let message):
                inlinePromptError = message
            }
            // The field is `.disabled` while running, which drops keyboard
            // focus - re-request it so typing the next prompt never needs a
            // mouse click first.
            searchFocused = true
        }
    }
}

private struct ExchangeView: View {
    let prompt: String
    let response: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(response)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectRow: View {
    let project: Project
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.body)
                .lineLimit(1)
            Text(project.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
