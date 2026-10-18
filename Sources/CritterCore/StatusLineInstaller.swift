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

    /// `'<hookPath>' statusline -- '<original>'`, or `'<hookPath>' statusline` without an original.
    public static func wrap(original: String?, hookPath: String) -> String {
        let prefix = wrapPrefix(hookPath)
        guard let original else { return prefix }
        return "\(prefix) -- \(shellQuote(original))"
    }

    public static func unwrap(_ command: String, hookPath: String) -> Unwrapped {
        let prefix = wrapPrefix(hookPath)
        if command == prefix { return .original(nil) }
        let head = prefix + " -- '"
        guard command.hasPrefix(head), command.hasSuffix("'"), command.count >= head.count + 1 else { return .notWrapped }
        let inner = command.dropFirst(head.count).dropLast()
        return .original(inner.replacingOccurrences(of: "'\\''", with: "'"))
    }

    private static func wrapPrefix(_ hookPath: String) -> String { "\(shellQuote(hookPath)) statusline" }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - install / uninstall / status

    public static func install(settings: String, hookPath: String) throws -> String {
        let doc = try Document(settings)
        guard let member = doc.statusLine else {
            return doc.insertingStatusLine(command: wrap(original: nil, hookPath: hookPath))
        }
        let command = try doc.commandMember(of: member)
        if unwrap(command.value, hookPath: hookPath) != .notWrapped { return settings }
        return doc.replacing(command.range, with: encode(wrap(original: command.value, hookPath: hookPath)))
    }

    public static func uninstall(settings: String, hookPath: String) throws -> String {
        let doc = try Document(settings)
        guard let member = doc.statusLine,
              let command = try? doc.commandMember(of: member),
              case .original(let original) = unwrap(command.value, hookPath: hookPath) else { return settings }
        if let original {
            return doc.replacing(command.range, with: encode(original))
        }
        return doc.removing(member)
    }

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
