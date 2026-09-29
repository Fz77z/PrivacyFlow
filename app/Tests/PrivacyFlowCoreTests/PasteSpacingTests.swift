import Testing
@testable import PrivacyFlowCore

/// The leading-space rule and the memory that feeds it.
struct PasteSpacingTests {
    @Test func theReportedBugASecondDictationAfterAFullStopGainsASpace() {
        #expect(PasteSpacing.join(previous: ".", beforePrevious: "t", text: "Needs space.") == " Needs space.")
    }

    @Test func nothingKnownAboutTheCursorLeavesTheTextUntouched() {
        #expect(PasteSpacing.join(previous: nil, beforePrevious: nil, text: "Needs space.") == "Needs space.")
    }

    @Test(arguments: [
        (Character("t"), Character?("u"), " and then"),
        ("7", "1", " and then"),
        (")", "e", " and then"),
        (" ", ".", "and then"),
        ("(", " ", "and then"),
        ("/", "c", "and then"),
        ("-", " ", " and then"),
        ("-", nil, " and then"),
    ])
    func theRuleTable(previous: Character, beforePrevious: Character?, expected: String) {
        #expect(PasteSpacing.join(previous: previous, beforePrevious: beforePrevious, text: "and then") == expected)
    }

    /// CJK writes without spaces between words, even though its characters are letters.
    @Test func japaneseDoesNotGainASpace() {
        #expect(PasteSpacing.join(previous: "す", beforePrevious: "で", text: "それから") == "それから")
    }

    @Test func theTailOfAnInsertionIsWhatTheNextOneJoinsOnto() {
        var memory = CursorMemory()
        memory.remember(pid: 42, inserted: "Needs space.")
        #expect(memory.recall(pid: 42) == (".", "e"))
    }

    @Test func aDifferentApplicationIsACursorThisNeverWroteTo() {
        var memory = CursorMemory()
        memory.remember(pid: 42, inserted: "Needs space.")
        #expect(memory.recall(pid: 99) == (nil, nil))
    }

    @Test func forgettingGivesUpTheMemory() {
        var memory = CursorMemory()
        memory.remember(pid: 42, inserted: "Needs space.")
        memory.forget()
        #expect(memory.recall(pid: 42) == (nil, nil))
    }
}
