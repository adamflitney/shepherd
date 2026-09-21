import Testing
@testable import ShepherdCore

@Test func fuzzyScoreMatchesExactString() {
    #expect(fuzzyScore("club", in: "club") != nil)
}

@Test func fuzzyScoreMatchesSubstring() {
    #expect(fuzzyScore("club", in: "yolo-club-api") != nil)
}

@Test func fuzzyScoreMatchesFuzzyChars() {
    #expect(fuzzyScore("yca", in: "yolo-club-api") != nil)
}

@Test func fuzzyScoreReturnsNilWhenCharsOutOfOrder() {
    #expect(fuzzyScore("bca", in: "abc") == nil)
}

@Test func fuzzyScoreReturnsNilForNoMatch() {
    #expect(fuzzyScore("xyz", in: "yolo-club-api") == nil)
}

@Test func fuzzyScoreExactMatchOutranksSubstringMatch() {
    let exact   = fuzzyScore("club", in: "club")!
    let partial = fuzzyScore("club", in: "yolo-club-api")!
    #expect(exact > partial)
}

@Test func fuzzyScoreShorterCandidateOutranksLonger() {
    let shorter = fuzzyScore("club", in: "yolo-club-api")!
    let longer  = fuzzyScore("club", in: "yolo-club-notifications")!
    #expect(shorter > longer)
}

@Test func fuzzyScoreConsecutiveRunOutranksScatteredChars() {
    let consecutive = fuzzyScore("api", in: "yolo-club-api")!
    let scattered   = fuzzyScore("api", in: "a-project-inc")!
    #expect(consecutive > scattered)
}

@Test func fuzzyScoreEmptyQueryAlwaysMatches() {
    #expect(fuzzyScore("", in: "anything") != nil)
}
