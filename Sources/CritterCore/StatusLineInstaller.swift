import Foundation

/// Wraps and restores `statusLine.command` in Claude Code's settings.json so Critter's
/// `critter-hook statusline` sits in front of the user's own status line command.
///
/// The settings text is edited in place: a small scanner locates the byte range of the one
/// string literal that changes, so formatting, key order and every
/// other byte of the user's file survive untouched.
public enum StatusLineInstaller {
    public enum Failure: Error, Equatable { case unparsable, notCommandType }
    public enum Unwrapped: Equatable { case notWrapped, original(String?) }
    public enum Status: Equatable { case installed, notInstalled, otherType }

    // MARK: - wrap / unwrap

    /// The status line command with Critter in front of `original`. It guards itself: when the
    /// hook binary is gone (Critter uninstalled, ~/.critter deleted) the shell runs `original`
    /// directly -- through `/bin/sh -c`, just as the hook would -- so the status line survives.
    ///
    ///     [ -x '<hook>' ] && exec '<hook>' statusline -- '<original>' || exec /bin/sh -c '<original>'
    ///     [ -x '<hook>' ] && exec '<hook>' statusline || exit 0        (no original: prints nothing)
    public static func wrap(original: String?, hookPath: String) -> String {
        let run = "[ -x \(shellQuote(hookPath)) ] && exec \(legacyPrefix(hookPath))"
        guard let original else { return "\(run) || exit 0" }
        let quoted = shellQuote(original)
        return "\(run) -- \(quoted)\(fallbackJoin)\(quoted)"
    }

    /// The original command inside a Critter wrapper made for any hook path -- a quoted path
    /// ending in `/critter-hook`, then ` statusline` -- or `notWrapped`. So a wrapper made by an
    /// install whose hook lived elsewhere (another home folder) is still recognised: install
    /// rewraps it instead of nesting it, and uninstall restores it.
    public static func unwrap(_ command: String) -> Unwrapped {
        guard let hookPath = wrappedHookPath(command) else { return .notWrapped }
        return unwrap(command, hookPath: hookPath)
    }

    /// The hook path a wrapper starts with (after `[ -x ` in today's form), if it is a
    /// `critter-hook`. Only a candidate: `unwrap(_:hookPath:)` then checks the whole command.
    private static func wrappedHookPath(_ command: String) -> String? {
        let bytes = Array(command.utf8)
        let guardPrefix = Array("[ -x ".utf8)
        let quote = UInt8(ascii: "'")
        let escapedQuote = Array(#"\''"#.utf8) // after a closing quote: `'\''` stands for one '
        let start = bytes.starts(with: guardPrefix) ? guardPrefix.count : 0
        guard start < bytes.count, bytes[start] == quote else { return nil }
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == quote {
                if bytes[(i + 1)...].starts(with: escapedQuote) {
                    i += 1 + escapedQuote.count
                    continue
                }
                guard let path = shellUnquote(String(decoding: bytes[start...i], as: UTF8.self)),
                      path.hasSuffix("/critter-hook") else { return nil }
                return path
            }
            i += 1
        }
        return nil
    }

    /// The original command inside a wrapper for `hookPath` -- today's form or the one before it
    /// (`'<hook>' statusline [-- '<original>']`, which had no fallback) -- or `notWrapped`.
    /// Only exact `wrap` output counts, so a hand-edited command is never mistaken for one.
    static func unwrap(_ command: String, hookPath: String) -> Unwrapped {
        if command == wrap(original: nil, hookPath: hookPath) || command == legacyPrefix(hookPath) { return .original(nil) }
        let guarded = "[ -x \(shellQuote(hookPath)) ] && exec \(legacyPrefix(hookPath)) -- "
        if command.hasPrefix(guarded) {
            // `'<original>' || exec /bin/sh -c '<original>'`: the same quoted text twice.
            let rest = Array(command.utf8.dropFirst(guarded.utf8.count))
            let join = Array(fallbackJoin.utf8)
            guard rest.count > join.count, (rest.count - join.count) % 2 == 0 else { return .notWrapped }
            let half = (rest.count - join.count) / 2
            let first = rest[..<half], second = rest[(half + join.count)...]
            guard first.elementsEqual(second), rest[half..<(half + join.count)].elementsEqual(join),
                  let original = shellUnquote(String(decoding: first, as: UTF8.self)) else { return .notWrapped }
            return .original(original)
        }
        let legacy = legacyPrefix(hookPath) + " -- "
        guard command.hasPrefix(legacy), let original = shellUnquote(String(command.dropFirst(legacy.count))) else { return .notWrapped }
        return .original(original)
    }

    private static let fallbackJoin = " || exec /bin/sh -c "

    /// `'<hookPath>' statusline`: the hook invocation, and on its own the first form's wrapper.
    private static func legacyPrefix(_ hookPath: String) -> String { "\(shellQuote(hookPath)) statusline" }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The string `quoted` stands for, if it is exactly what `shellQuote` makes of it.
    private static func shellUnquote(_ quoted: String) -> String? {
        guard quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return nil }
        let original = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        return shellQuote(original) == quoted ? original : nil
    }

    // MARK: - install / uninstall / status

    public static func install(settings: String, hookPath: String) throws -> String {
        let doc = try Document(settings)
        guard let member = doc.statusLine else {
            return doc.insertingStatusLine(command: wrap(original: nil, hookPath: hookPath))
        }
        let command = try doc.commandMember(of: member)
        switch unwrap(command.value) {
        case .notWrapped:
            return doc.replacing(command.range, with: encode(wrap(original: command.value, hookPath: hookPath)))
        case .original(let original):
            // Already wrapped. One of the older form, or for another hook path, is rewrapped
            // around the same original -- never wrapped a second time.
            let current = wrap(original: original, hookPath: hookPath)
            if command.value == current { return settings }
            return doc.replacing(command.range, with: encode(current))
        }
    }

    /// Restores the original command of a Critter wrapper for any hook path (see `unwrap(_:)`).
    public static func uninstall(settings: String, hookPath: String) throws -> String {
        let doc = try Document(settings)
        guard let member = doc.statusLine,
              let command = try? doc.commandMember(of: member),
              case .original(let original) = unwrap(command.value) else { return settings }
        if let original {
            return doc.replacing(command.range, with: encode(original))
        }
        return doc.removing(member)
    }

    /// `installed` only for a wrapper around this `hookPath`: one for another path doesn't feed
    /// this Critter (installing again fixes it).
    public static func status(settings: String, hookPath: String) -> Status {
        guard let doc = try? Document(settings), let member = doc.statusLine else { return .notInstalled }
        switch try? doc.commandMember(of: member) {
        case .some(let command):
            return unwrap(command.value, hookPath: hookPath) == .notWrapped ? .notInstalled : .installed
        case .none:
            return .otherType
        }
    }

    /// A JSON string literal; slashes stay unescaped so paths read naturally in the file.
    private static func encode(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: - JSON scanning

    private struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    private struct Command {
        var value: String
        var range: Range<Int>
    }

    /// The settings text plus the byte layout of its top-level members.
    private struct Document {
        let bytes: [UInt8]
        let members: [Member]
        let openBrace: Int

        init(_ text: String) throws {
            bytes = Array(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: Data(bytes))) is [String: Any] else { throw Failure.unparsable }
            var scanner = Scanner(bytes)
            do {
                scanner.skipSpace()
                openBrace = scanner.pos
                members = try scanner.members()
            } catch {
                throw Failure.unparsable
            }
        }

        var statusLine: Member? { members.first { $0.key == "statusLine" } }

        /// The `command` string of a `statusLine` member, or `notCommandType` unless it is an
        /// object whose `type` is "command" and whose `command` is a string.
        func commandMember(of member: Member) throws -> Command {
            guard bytes[member.valueStart] == UInt8(ascii: "{") else { throw Failure.notCommandType }
            var scanner = Scanner(bytes)
            scanner.pos = member.valueStart
            guard let inner = try? scanner.members() else { throw Failure.unparsable }
            guard let type = inner.first(where: { $0.key == "type" }),
                  decodeString(type.valueStart..<type.valueEnd) == "command",
                  let command = inner.first(where: { $0.key == "command" }),
                  let value = decodeString(command.valueStart..<command.valueEnd) else { throw Failure.notCommandType }
            return Command(value: value, range: command.valueStart..<command.valueEnd)
        }

        private func decodeString(_ range: Range<Int>) -> String? {
            try? JSONDecoder().decode(String.self, from: Data(bytes[range]))
        }

        func replacing(_ range: Range<Int>, with literal: String) -> String {
            splice(range, literal)
        }

        func insertingStatusLine(command: String) -> String {
            let body = "\"statusLine\": {\"type\": \"command\", \"command\": \(encode(command))}"
            guard let last = members.last else {
                return splice((openBrace + 1)..<(openBrace + 1), "\n  \(body)\n")
            }
            return splice(last.valueEnd..<last.valueEnd, ",\n\(indent())\(body)")
        }

        /// Deletes `member` together with the comma and whitespace that tie it to a neighbour.
        func removing(_ member: Member) -> String {
            guard let index = members.firstIndex(where: { $0.keyStart == member.keyStart }) else { return splice(0..<0, "") }
            if index > 0 {
                return splice(members[index - 1].valueEnd..<member.valueEnd, "")
            }
            if members.count > 1 {
                return splice(member.keyStart..<members[1].keyStart, "")
            }
            return splice((openBrace + 1)..<member.valueEnd, "")
        }

        /// Whitespace in front of the first member's line; two spaces if it shares a line with `{`.
        private func indent() -> String {
            guard let first = members.first else { return "  " }
            var i = first.keyStart
            while i > 0, bytes[i - 1] == UInt8(ascii: " ") || bytes[i - 1] == UInt8(ascii: "\t") { i -= 1 }
            guard i > 0, bytes[i - 1] == UInt8(ascii: "\n") else { return "  " }
            return String(decoding: bytes[i..<first.keyStart], as: UTF8.self)
        }

        private func splice(_ range: Range<Int>, _ replacement: String) -> String {
            var out = Array(bytes[..<range.lowerBound])
            out += Array(replacement.utf8)
            out += bytes[range.upperBound...]
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// A byte-level JSON reader: knows only enough syntax to find where values begin and end.
    private struct Scanner {
        struct Malformed: Error {}
        let bytes: [UInt8]
        var pos = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
        }

        /// Reads an object starting at `pos` (which must be `{`), leaving `pos` after its `}`.
        mutating func members() throws -> [Member] {
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "{") else { throw Malformed() }
            pos += 1
            var result: [Member] = []
            skipSpace()
            if peek() == UInt8(ascii: "}") { pos += 1; return result }
            while true {
                skipSpace()
                let keyStart = pos
                let keyEnd = try skipString()
                guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<keyEnd])) else { throw Malformed() }
                skipSpace()
                guard peek() == UInt8(ascii: ":") else { throw Malformed() }
                pos += 1
                skipSpace()
                let valueStart = pos
                try skipValue()
                result.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: pos))
                skipSpace()
                switch peek() {
                case UInt8(ascii: ","): pos += 1
                case UInt8(ascii: "}"): pos += 1; return result
                default: throw Malformed()
                }
            }
        }

        private func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }

        private mutating func skipValue() throws {
            switch peek() {
            case UInt8(ascii: "{"): _ = try members()
            case UInt8(ascii: "["):
                pos += 1
                skipSpace()
                if peek() == UInt8(ascii: "]") { pos += 1; return }
                while true {
                    skipSpace()
                    try skipValue()
                    skipSpace()
                    switch peek() {
                    case UInt8(ascii: ","): pos += 1
                    case UInt8(ascii: "]"): pos += 1; return
                    default: throw Malformed()
                    }
                }
            case UInt8(ascii: "\""): _ = try skipString()
            case .some:
                // number, true, false, null: runs to the next structural byte
                let start = pos
                while let b = peek(), ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b) { pos += 1 }
                if pos == start { throw Malformed() }
            case .none: throw Malformed()
            }
        }

        /// Skips a string literal, returning the index just past its closing quote.
        private mutating func skipString() throws -> Int {
            guard peek() == UInt8(ascii: "\"") else { throw Malformed() }
            pos += 1
            while let b = peek() {
                pos += 1
                if b == UInt8(ascii: "\\") { pos += 1 }
                else if b == UInt8(ascii: "\"") { return pos }
            }
            throw Malformed()
        }
    }
}
