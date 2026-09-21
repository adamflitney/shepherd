import Testing
@testable import ShepherdCore
@testable import ShepherdUI

@Test func attentionDisplayCoversEveryKindWithADistinctSymbol() {
    let displays = AttentionState.Kind.allCases.map(attentionDisplay(for:))
    #expect(displays.allSatisfy { !$0.symbolName.isEmpty && !$0.label.isEmpty })
    #expect(Set(displays.map(\.symbolName)).count == AttentionState.Kind.allCases.count)
}

@Test func attentionDisplayBlockedIsLabelledForUrgency() {
    #expect(attentionDisplay(for: .blocked).label == "Blocked")
}
