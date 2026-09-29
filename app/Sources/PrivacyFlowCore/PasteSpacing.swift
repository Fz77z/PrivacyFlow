import Foundation

/// Joining a finished dictation onto whatever the cursor already sits after.
///
/// Dictating twice in a row used to produce `out.Needs space`, because the
/// text was pasted exactly as produced. The rule is Wispr Flow's leading-space
/// rule, reimplemented; see the Rust app's investigation
/// `2026-09-23-cursor-context-and-paste-spacing.md` for where it comes from and
/// what was deliberately left out.
public enum PasteSpacing {
    /// Characters that close a clause and want a space after them. Opening
    /// brackets are absent on purpose: `(` stays welded to what it opens.
    static let closing: Set<Character> = Set("!%),.:;>?]}")

    /// Characters that separate words when they stand alone but belong to a
    /// token when wedged against one: a list's `-` wants a space, the `/` in a
    /// path and the `+` in `2+2` do not.
    static let ambiguous: Set<Character> = Set(#"\/|-&*+=~"#)

    /// Place `text` after `previous`, the character the cursor sits after,
    /// adding a space when the join would run two words together.
    ///
    /// `previous` is nil when PrivacyFlow does not know what precedes the
    /// cursor, which is the common case. No information means no change.
    public static func join(previous: Character?, beforePrevious: Character?, text: String) -> String {
        guard let previous else { return text }
        return needsLeadingSpace(previous: previous, beforePrevious: beforePrevious) ? " " + text : text
    }

    static func needsLeadingSpace(previous: Character, beforePrevious: Character?) -> Bool {
        // Asked before the alphanumeric question, which Han and Hiragana would
        // otherwise answer yes to.
        if isSpacelessScript(previous) {
            return false
        }
        if previous.isLetter || previous.isNumber || closing.contains(previous) {
            return true
        }
        // An ambiguous character separates words only when it stands alone, so
        // what sits behind it decides. Nothing behind it means it opens the line.
        if ambiguous.contains(previous) {
            return beforePrevious == nil || beforePrevious == " "
        }
        return false
    }

    /// Whether a character belongs to a script written without spaces between
    /// words, where separating the join would be wrong.
    static func isSpacelessScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x3400...0x4DBF, // Han, extension A
             0x4E00...0x9FFF: // Han
            return true
        default:
            return false
        }
    }
}

/// What PrivacyFlow knows about the character in front of the cursor, which is
/// only ever what PrivacyFlow itself put there.
///
/// It knows the answer for free in the one case that matters, two dictations
/// in a row, and admits to knowing nothing the moment anything else could have
/// moved the cursor. There is deliberately no timer: pausing to think and then
/// continuing is the most valuable case.
public struct CursorMemory: Sendable {
    private struct Placed: Sendable {
        var pid: Int32
        var previous: Character
        var beforePrevious: Character?
    }

    private var placed: Placed?

    public init() {}

    /// Record what an insertion that reached the document left behind the cursor.
    public mutating func remember(pid: Int32, inserted: String) {
        var tail = inserted.reversed().makeIterator()
        guard let previous = tail.next() else {
            placed = nil
            return
        }
        placed = Placed(pid: pid, previous: previous, beforePrevious: tail.next())
    }

    /// Give up the memory, because something could have moved the cursor.
    public mutating func forget() {
        placed = nil
    }

    /// What sits behind the cursor in `pid`, as far as this knows. A different
    /// application is a cursor this never wrote to.
    public func recall(pid: Int32) -> (previous: Character?, beforePrevious: Character?) {
        guard let placed, placed.pid == pid else { return (nil, nil) }
        return (placed.previous, placed.beforePrevious)
    }
}
