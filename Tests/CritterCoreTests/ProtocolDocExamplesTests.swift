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
            // The push registration is a phone -> Mac frame; the rest of its section is not frames
            // (its JSON blocks are fenced "json push..." and read by `docBlocks`).
            fromPhone = heading.hasPrefix("## phone -> mac") || heading.hasPrefix("## ios push registration") ? true
                : heading.hasPrefix("## mac -> phone") ? false : nil
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
    #expect(Set(examples.filter(\.fromPhone).compactMap(\.type)) == ["hello", "pair", "answer", "seen", "say", "skin", "push"])
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

/// The ```json blocks fenced as "json <label>" in the doc, as written.
private func docBlocks(_ label: String) throws -> [String] {
    let lines = try String(contentsOf: protocolDoc, encoding: .utf8).components(separatedBy: "\n")
    var blocks: [String] = []
    var open: [String]?
    for line in lines {
        if let current = open {
            if line.hasPrefix("```") { blocks.append(current.joined(separator: "\n")); open = nil } else { open = current + [line] }
        } else if line == "```json " + label {
            open = []
        }
    }
    return blocks
}

/// The doc's push registration is the Mac's decoder's and the phone's encoder's exact text.
@Test func protocolDocPushExampleIsTheEncoderOutput() throws {
    let example = try #require(try docExamples().first { $0.type == "push" })
    let message = try #require(ClientMessage.decode(Data(example.text.utf8)))
    #expect(String(decoding: message.encode(), as: UTF8.self) == example.text)
    guard case .push(let id, let registration) = message else {
        Issue.record("not a push: \(message)")
        return
    }
    #expect(id == "p1")
    #expect(registration.hasValidKey && !registration.isEmpty)
    #expect(registration.activity?.enabled == true)
}

/// The doc's push payloads are exactly what `PushPayload` writes, and its sealed text and Live
/// Activity content are exactly what `PushCrypto` and `LiveActivityContent` make and read.
@Test func protocolDocPushPayloadExamplesAreWhatTheCodeWrites() throws {
    func text(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    let payloads = try docBlocks("push")
    #expect(payloads.count == 2)
    let alert = try #require(payloads.first)
    let alertObject = try object(Data(alert.utf8))
    let sealed = try #require(alertObject["c"] as? String)
    #expect(try text(PushPayload.alert(
        category: .permission, requestId: "r1", sessionId: "s1", sealed: sealed, timeSensitive: true
    )) == alert)
    #expect(PushPayload.parse(alertObject) == .alert(ParsedPush.Alert(category: .permission, requestId: "r1", sessionId: "s1", sealed: sealed)))
    let withdraw = try #require(payloads.last)
    #expect(try text(PushPayload.withdraw(ids: ["r1", "done:s1"])) == withdraw)
    #expect(PushPayload.parse(try object(Data(withdraw.utf8))) == .withdraw(ids: ["r1", "done:s1"]))

    // The sealed text opens with the registration example's key.
    let registration = try #require(try docExamples().first { $0.type == "push" }?.object["registration"] as? [String: Any])
    let key = try #require(registration["key"] as? String)
    let plain = try #require(try docBlocks("push-text").first)
    #expect(try PushCrypto.open(sealed, key: key) == JSONDecoder().decode(PushText.self, from: Data(plain.utf8)))

    let content = try #require(try docBlocks("push-content").first)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let decoded = try JSONDecoder().decode(LiveActivityContent.self, from: Data(content.utf8))
    #expect(String(decoding: try encoder.encode(decoded), as: UTF8.self) == content)
    #expect(decoded.counts.map(\.state) == [.waiting, .running] && decoded.total == 3)
}
