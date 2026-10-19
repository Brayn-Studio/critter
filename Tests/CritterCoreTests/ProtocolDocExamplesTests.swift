import Foundation
import Testing
@testable import CritterCore

/// `docs/critter-bridge-protocol.md`, found from this file: Tests/CritterCoreTests/ -> repo root.
private let protocolDoc = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/critter-bridge-protocol.md")

/// One ```json block of the doc, and which way it travels (by the `## Phone -> Mac` /
/// `## Mac -> phone` section it is in).
private struct DocExample {
    var fromPhone: Bool
    var line: Int
    var text: String
    var object: [String: Any]
    var type: String? { object["type"] as? String }
}

private func docExamples() throws -> [DocExample] {
    let lines = try String(contentsOf: protocolDoc, encoding: .utf8).components(separatedBy: "\n")
    var examples: [DocExample] = []
    var fromPhone: Bool?
    var block: (start: Int, lines: [String])?
    for (index, line) in lines.enumerated() {
        if var open = block {
            if line.hasPrefix("```") {
                let text = open.lines.joined(separator: "\n")
                let object = try #require(
                    try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                    "line \(open.start): not a JSON object"
                )
                if let fromPhone {
                    examples.append(DocExample(fromPhone: fromPhone, line: open.start, text: text, object: object))
                } else {
                    Issue.record("docs line \(open.start): a JSON example outside the message sections")
                }
                block = nil
            } else {
                open.lines.append(line)
                block = open
            }
        } else if line == "```json" {
            block = (index + 2, [])
        } else if line.hasPrefix("## ") {
            let heading = line.lowercased()
            fromPhone = heading.hasPrefix("## phone -> mac") ? true : heading.hasPrefix("## mac -> phone") ? false : nil
        }
    }
    return examples
}

/// Every key, as a path from the top (`/sessions[]/context/usedPercent`); arrays merge their elements.
private func keyPaths(_ value: Any, _ prefix: String = "") -> Set<String> {
    switch value {
    case let object as [String: Any]:
        return object.reduce(into: []) { paths, entry in
            let path = prefix + "/" + entry.key
            paths.insert(path)
            paths.formUnion(keyPaths(entry.value, path))
        }
    case let array as [Any]:
        return array.reduce(into: []) { $0.formUnion(keyPaths($1, prefix + "[]")) }
    default:
        return []
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The doc has an example of every message, in each direction.
@Test func protocolDocHasAnExampleOfEveryMessage() throws {
    let examples = try docExamples()
    #expect(Set(examples.filter(\.fromPhone).compactMap(\.type)) == ["hello", "pair", "answer", "seen", "say", "skin"])
    #expect(Set(examples.filter { !$0.fromPhone }.compactMap(\.type)) == ["welcome", "paired", "denied", "snapshot", "skin", "result"])
}

/// Each example decodes with the Mac's decoder for its direction, and encoding what came out
/// gives the same keys back: nothing in the doc is dropped, nothing undocumented is added.
@Test func protocolDocExamplesDecodeAndEncodeBackToTheSameKeys() throws {
    for example in try docExamples() {
        let where_ = Comment(rawValue: "docs line \(example.line): \(example.text)")
        let encoded: Data
        if example.fromPhone {
            let message = try #require(ClientMessage.decode(Data(example.text.utf8)), where_)
            encoded = message.encode()
        } else {
            let message = try #require(ServerMessage.decode(Data(example.text.utf8)), where_)
            encoded = message.encode()
        }
        #expect(keyPaths(try object(encoded)) == keyPaths(example.object), where_)
    }
}
