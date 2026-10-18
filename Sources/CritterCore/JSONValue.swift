import Foundation

/// An arbitrary JSON value, used to hold hook payload fields (like `tool_input`) whose
/// shape depends on which tool fired, without committing to a concrete Swift type.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Converts a `JSONSerialization` product (`NSNumber`, `NSString`, `NSArray`, ...) into a
    /// `JSONValue`. An `NSNumber` that holds a boolean becomes `.bool`, not `.number`; anything
    /// that is not valid JSON becomes `.null`.
    public init(any value: Any?) {
        switch value {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// Subscripts into an `.object`; returns nil for any other case or missing key.
    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// The wrapped string, or nil if this is not a `.string`.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
