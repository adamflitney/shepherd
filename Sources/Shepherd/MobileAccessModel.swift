import AppKit
import ServiceManagement
import ShepherdCore
import ShepherdWebKit

/// Drives the Mobile Access window and owns the embedded web server. The
/// server runs inside this app (not a second process) so there is one thing
/// to install and one login item; the checklist walks the user through the
/// parts that live outside the app (Tailscale).
@MainActor
@Observable
final class MobileAccessModel {
    struct Problem: Equatable {
        var message: String
        var url: URL?
    }

    private(set) var config: WebConfig
    private(set) var status = MobileAccessStatus()
    private(set) var isWorking = false
    private(set) var problem: Problem?
    private(set) var testResult: String?
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    private let backend: any SessionBackend
    private var server: MobileAccessServer?
    private var pollTask: Task<Void, Never>?
    /// Publishing is attempted automatically once, as soon as the
    /// prerequisites are met; after a failure it waits for the user to retry
    /// rather than looping on an error they need to fix.
    private var triedAutoPublish = false

    init(backend: any SessionBackend) {
        self.backend = backend
        self.config = ShepherdConfig.load().web
    }

    var isEnabled: Bool { config.enabled }

    /// Called at launch: bring the server back up if it was left on.
    func startIfEnabled() {
        guard config.enabled else { return }
        Task {
            await startServer()
            await refresh()
            await publishAutomaticallyIfReady()
        }
    }

    // MARK: Actions

    func setEnabled(_ on: Bool) async {
        guard on != config.enabled else { return }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        if on {
            update { $0.enabled = true }
            triedAutoPublish = false
            await startServer()
            await refresh()
            await publishAutomaticallyIfReady()
        } else {
            await server?.disableTailscaleServe()
            await server?.stop()
            server = nil
            update { $0.enabled = false }
            await refresh()
        }
    }

    func setKeepAwake(_ on: Bool) async {
        update { $0.keepAwake = on }
        guard config.enabled else { return }
        await server?.stop()
        server = nil
        await startServer()
        await refresh()
    }

    func setAlertsOnlyWhenAway(_ on: Bool) async {
        update { $0.alertsOnlyWhenAway = on }
        guard config.enabled else { return }
        await server?.stop()
        server = nil
        await startServer()
        await refresh()
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Shepherd launch-at-login toggle failed: \(error)")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func publish() async {
        guard let server else { return }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        do {
            try await server.enableTailscaleServe()
        } catch let error as MobileAccessSetupError {
            if case .needsAction(let message, let url) = error {
                problem = Problem(message: message, url: url.flatMap(URL.init(string:)))
            } else {
                problem = Problem(message: error.localizedDescription, url: nil)
            }
        } catch {
            problem = Problem(message: "\(error)", url: nil)
        }
        await refresh()
    }

    func removePhone(id: String) async {
        await server?.removePhone(id: id)
        await refresh()
    }

    func sendTestNotification() async {
        guard let server else { return }
        let delivered = await server.sendTestNotification()
        testResult = delivered == 0
            ? "No phone received it - open Shepherd on your phone and tap Enable alerts."
            : "Sent to \(delivered) phone\(delivered == 1 ? "" : "s")."
    }

    // MARK: Status

    func refresh() async {
        if let server {
            status = await server.status()
        } else {
            // Not running: still report Tailscale's state, so the checklist
            // is useful before the user has turned anything on.
            status = await MobileAccessServer(backend: backend).status()
        }
    }

    /// While the window is open, keep the checklist live - the user is off
    /// in Tailscale's admin console and should see each step turn green
    /// without coming back to press anything.
    func startPolling() {
        guard pollTask == nil else { return }
        testResult = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.publishAutomaticallyIfReady()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Internals

    private func startServer() async {
        guard server == nil else { return }
        let candidate = MobileAccessServer(
            backend: backend,
            options: .init(port: UInt16(clamping: config.port), keepAwake: config.keepAwake, onlyWhenAway: config.alertsOnlyWhenAway, terminalAppName: ShepherdConfig.load().terminal.appName)
        )
        do {
            try await candidate.start()
            server = candidate
        } catch {
            problem = Problem(
                message: "Couldn't start on port \(config.port) - is something else (such as the standalone ShepherdWeb service) already using it?",
                url: nil
            )
        }
    }

    private func publishAutomaticallyIfReady() async {
        guard config.enabled, server != nil, !isWorking, !triedAutoPublish,
              status.tailscaleConnected, status.httpsEnabled, status.publishedURL == nil else { return }
        triedAutoPublish = true
        await publish()
    }

    private func update(_ change: (inout WebConfig) -> Void) {
        change(&config)
        var all = ShepherdConfig.load()
        all.web = config
        try? all.save()
    }
}
