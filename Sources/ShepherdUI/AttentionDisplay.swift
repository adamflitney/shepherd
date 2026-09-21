import ShepherdCore

/// SF Symbol name + human label for a given attention kind. Colour is a
/// SwiftUI concern applied at the view layer, not tested here.
public struct AttentionDisplay: Equatable {
    public let symbolName: String
    public let label: String
}

public func attentionDisplay(for kind: AttentionState.Kind) -> AttentionDisplay {
    switch kind {
    case .blocked:
        AttentionDisplay(symbolName: "exclamationmark.circle.fill", label: "Blocked")
    case .done:
        AttentionDisplay(symbolName: "checkmark.circle.fill", label: "Done")
    case .working:
        AttentionDisplay(symbolName: "bolt.circle.fill", label: "Working")
    case .idle:
        AttentionDisplay(symbolName: "moon.circle.fill", label: "Idle")
    case .unknown:
        AttentionDisplay(symbolName: "questionmark.circle.fill", label: "Unknown")
    }
}
