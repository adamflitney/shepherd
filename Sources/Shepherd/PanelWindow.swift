import AppKit
import SwiftUI
import ShepherdCore
import ShepherdUI

/// Holds a mutable closure so `SessionsListView`'s `onDismiss` can be wired
/// to `self.hide()` after `super.init()`, since Swift won't let a subclass
/// capture `self` before phase-1 init completes.
private final class ClosureBox {
    var onDismiss: () -> Void = {}
}

/// The dashboard panel, built once at launch and shown/hidden rather than
/// rebuilt per presentation - see the plan's Performance section (#2):
/// rebuilding the SwiftUI tree on every open would cost tens of ms and
/// discard view state, and first open must not be the slow one.
@MainActor
final class PanelWindow: NSPanel {
    private let hostingController: NSHostingController<SessionsListView>
    private let dismissBox: ClosureBox

    init(
        store: SessionsStore,
        onFocusSession: @escaping (SessionID) -> Void,
        onCreateSession: @escaping (CreateSessionRequest) -> Void,
        onPromptSession: @escaping (SessionID, String) -> Void,
        onRunInlinePrompt: @escaping (String, String?) async -> InlinePromptOutcome,
        onPromoteInlineConversation: @escaping (String) -> Void,
        onPeekSession: @escaping (SessionID) async throws -> String,
        onLoadReviewPRs: @escaping () async throws -> [MatchedReviewPR],
        onStartReviewSession: @escaping (MatchedReviewPR) async throws -> Void,
        onIgnoreReviewPR: @escaping (MatchedReviewPR) -> Void
    ) {
        let box = ClosureBox()
        dismissBox = box

        let view = SessionsListView(
            store: store,
            onFocusSession: onFocusSession,
            onDismiss: { box.onDismiss() },
            onCreateSession: onCreateSession,
            onPromptSession: onPromptSession,
            onRunInlinePrompt: onRunInlinePrompt,
            onPromoteInlineConversation: onPromoteInlineConversation,
            onPeekSession: onPeekSession,
            onLoadReviewPRs: onLoadReviewPRs,
            onStartReviewSession: onStartReviewSession,
            onIgnoreReviewPR: onIgnoreReviewPR
        )
        hostingController = NSHostingController(rootView: view)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        contentViewController = hostingController

        dismissBox.onDismiss = { [weak self] in self?.hide() }

        // Force layout now, off-screen, so the first real presentation pays
        // no SwiftUI first-render cost.
        hostingController.view.layoutSubtreeIfNeeded()
    }

    // NSPanel with .borderless won't become key by default; override to allow
    // keyboard input in the hosted SwiftUI view.
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        hide()
    }

    func present(relativeTo button: NSStatusBarButton?) {
        if let button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let x = buttonFrame.midX - frame.width / 2
            let y = buttonFrame.minY - frame.height - 4
            setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            centerOnPrimaryScreen()
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// For the global-hotkey quick switcher, which isn't anchored to the menu
    /// bar button - same centered placement as mac-sesh's `SearchWindow`.
    func presentCentered() {
        centerOnPrimaryScreen()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func centerOnPrimaryScreen() {
        // screens.first is the display with the menu bar, not whichever
        // screen happens to have the currently-focused window.
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY + 60))
    }

    func hide() {
        orderOut(nil)
    }
}
