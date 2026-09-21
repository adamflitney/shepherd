import Foundation
import ShepherdCore

/// Seed data for the fake backend so a manual `swift run Shepherd` has
/// something meaningful to look at before the real Herdr adapter exists.
enum DemoSessions {
    static let all: [Session] = [
        Session(
            id: SessionID(rawValue: "demo:1"),
            title: "yolo-club-api",
            agent: .claude,
            workingDirectory: URL(fileURLWithPath: "/Users/devuser/Dev/yolo-club-api"),
            attention: AttentionState(kind: .blocked, summary: "Edit Package.swift?"),
            group: SessionGroup(id: "w1", label: "yolo-club-api", ordinal: 1),
            capabilities: [.focus, .close, .prompt]
        ),
        Session(
            id: SessionID(rawValue: "demo:2"),
            title: "shepherd",
            agent: .claude,
            workingDirectory: URL(fileURLWithPath: "/Users/devuser/Dev/shepherd"),
            attention: AttentionState(kind: .working),
            isFocused: true,
            group: SessionGroup(id: "w2", label: "shepherd", ordinal: 2),
            capabilities: [.focus, .close, .prompt]
        ),
        Session(
            id: SessionID(rawValue: "demo:3"),
            title: "authz-config",
            agent: .claude,
            workingDirectory: URL(fileURLWithPath: "/Users/devuser/Dev/authz-config"),
            attention: .idle(),
            group: SessionGroup(id: "w3", label: "authz-config", ordinal: 3),
            capabilities: [.focus, .close, .prompt]
        ),
        Session(
            id: SessionID(rawValue: "demo:4"),
            title: "Widget Strategy RFC",
            agent: .claude,
            attention: AttentionState(kind: .done),
            capabilities: [.focus, .close, .prompt]
        ),
    ]
}
