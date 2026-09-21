import Testing
@testable import ShepherdCore

@Test func trimmedPeekTextDropsLeadingAndTrailingBlankLines() {
    let raw = "\n\n  \nfirst line\nsecond line\n\n   \n\n"
    #expect(trimmedPeekText(raw) == "first line\nsecond line")
}

@Test func trimmedPeekTextKeepsBlankLinesInTheMiddle() {
    let raw = "first\n\nsecond"
    #expect(trimmedPeekText(raw) == "first\n\nsecond")
}

@Test func trimmedPeekTextOfAllBlankInputReturnsAPlaceholder() {
    #expect(trimmedPeekText("\n\n   \n") == "(no output)")
}

@Test func trimmedPeekTextOfEmptyStringReturnsAPlaceholder() {
    #expect(trimmedPeekText("") == "(no output)")
}
