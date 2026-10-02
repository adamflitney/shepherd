import AppKit
import CoreImage.CIFilterBuiltins
import ShepherdWebKit
import SwiftUI

struct MobileAccessView: View {
    @Bindable var model: MobileAccessModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.isEnabled {
                    checklist
                    if let problem = model.problem { problemBanner(problem) }
                    if model.status.nextStep == .ready { phoneSection }
                    settings
                } else if let problem = model.problem {
                    problemBanner(problem)
                }
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mobile Access").font(.title2.bold())
            Text("See which agents need you, answer them, and start new sessions from your phone.")
                .foregroundStyle(.secondary)
            Toggle("Enable mobile access", isOn: Binding(
                get: { model.isEnabled },
                set: { on in Task { await model.setEnabled(on) } }
            ))
            .toggleStyle(.switch)
            .disabled(model.isWorking)
            .padding(.top, 4)
        }
    }

    private var checklist: some View {
        let next = model.status.nextStep
        return VStack(alignment: .leading, spacing: 10) {
            row("Tailscale is installed", done: model.status.tailscaleInstalled, active: next == .installTailscale) {
                Button("Get Tailscale") { open("https://tailscale.com/download") }
            }
            row("Signed in to Tailscale", done: model.status.tailscaleConnected, active: next == .signInToTailscale) {
                Button("Open Tailscale") { openTailscaleApp() }
            }
            row("HTTPS certificates are turned on", done: model.status.httpsEnabled, active: next == .enableHTTPS) {
                Button("Open admin page") { open("https://login.tailscale.com/admin/dns") }
            }
            row("Shared on your Tailscale network", done: model.status.publishedURL != nil, active: next == .publish) {
                Button("Share now") { Task { await model.publish() } }.disabled(model.isWorking)
            }
            if next == .enableHTTPS {
                Text("On that page, scroll to HTTPS Certificates and choose Enable. This lets your phone connect securely.")
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 30)
            }
        }
    }

    private func row<Action: View>(_ title: String, done: Bool, active: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : (active ? Color.accentColor : Color.secondary))
                .font(.title3)
            Text(title).foregroundStyle(done || active ? .primary : .secondary)
            Spacer()
            if active { action() }
        }
    }

    private func problemBanner(_ problem: MobileAccessModel.Problem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.message)
                if let url = problem.url {
                    Button("Open in Tailscale") { NSWorkspace.shared.open(url) }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("Set up your phone").font(.headline)
            if let url = model.status.publishedURL {
                HStack(alignment: .top, spacing: 18) {
                    if let image = qrImage(for: url) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "Install Tailscale on your phone and sign in with the same account.")
                        step(2, "Scan this code with your camera and open the page in Safari.")
                        step(3, "Tap Share, then Add to Home Screen, and open Shepherd from your Home Screen.")
                        step(4, "Tap Enable alerts so you're told when an agent needs you.")
                    }
                }
                HStack {
                    Text(url).font(.callout.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
            }
            Divider()
            Text("Phones with alerts on").font(.subheadline.bold())
            if model.status.phones.isEmpty {
                Text("None yet - open Shepherd on your phone and tap Turn on alerts.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.status.phones) { phone in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            Text(phone.label)
                            Text("last seen \(lastSeenText(phone.lastSeen))").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { Task { await model.removePhone(id: phone.id) } }
                        }
                    }
                    Text("A phone that no longer opens Shepherd - a deleted Home Screen app, or an old phone - stays on this list until you remove it, or after 90 days unseen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("Send test notification") { Task { await model.sendTestNotification() } }
                    .disabled(model.status.phones.isEmpty)
                if let result = model.testResult {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lastSeenText(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.callout.bold()).frame(width: 18, height: 18)
                .background(Color.secondary.opacity(0.2), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("Keep this Mac awake while agents are working or waiting on you", isOn: Binding(
                get: { model.config.keepAwake },
                set: { on in Task { await model.setKeepAwake(on) } }
            ))
            Toggle("Only alert my phone when I'm away from this Mac (a couple of minutes without keyboard or mouse)", isOn: Binding(
                get: { model.config.alertsOnlyWhenAway },
                set: { on in Task { await model.setAlertsOnlyWhenAway(on) } }
            ))
            Toggle("Open Shepherd when I log in (your phone can only connect while it's running)", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
        }
    }

    private var footer: some View {
        Text("Only devices signed in to your own Tailscale account can connect. Nothing is exposed to the wider internet.")
            .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: Helpers

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private func openTailscaleApp() {
        let path = "/Applications/Tailscale.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            open("https://tailscale.com/download")
        }
    }

    /// Black-on-white, the form phone cameras read most reliably.
    private func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

@MainActor
final class MobileAccessWindowController {
    private var window: NSWindow?
    private let model: MobileAccessModel

    init(model: MobileAccessModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: MobileAccessView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Mobile Access"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
