import Foundation

/// A dynamically-typed JSON value.
///
/// Tool input schemas and the arguments Claude sends back are open-ended by
/// nature, so they cannot be modelled as concrete Swift types. This is the one
/// place untyped data is allowed; everything downstream extracts typed values
/// through the throwing accessors below, which fail fast with a useful message.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrepresentable JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v):
            // Encode whole numbers without a decimal point so schemas and
            // coordinates read naturally on the wire.
            if v == v.rounded(), abs(v) < 1e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }

    // MARK: - Optional accessors

    public var stringValue: String? { if case let .string(v) = self { return v }; return nil }
    public var boolValue: Bool? { if case let .bool(v) = self { return v }; return nil }
    public var doubleValue: Double? { if case let .number(v) = self { return v }; return nil }
    public var intValue: Int? { if case let .number(v) = self { return Int(v) }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(v) = self { return v }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    // MARK: - Throwing accessors

    public struct MissingField: Error, CustomStringConvertible {
        public let field: String
        public let expected: String
        public var description: String { "missing or invalid argument '\(field)' (expected \(expected))" }
    }

    public func string(_ key: String) throws -> String {
        guard let v = self[key]?.stringValue else { throw MissingField(field: key, expected: "string") }
        return v
    }

    public func int(_ key: String) throws -> Int {
        guard let v = self[key]?.intValue else { throw MissingField(field: key, expected: "integer") }
        return v
    }

    public func double(_ key: String) throws -> Double {
        guard let v = self[key]?.doubleValue else { throw MissingField(field: key, expected: "number") }
        return v
    }

    public func string(_ key: String, default fallback: String) -> String {
        self[key]?.stringValue ?? fallback
    }

    public func int(_ key: String, default fallback: Int) -> Int {
        self[key]?.intValue ?? fallback
    }

    public func bool(_ key: String, default fallback: Bool) -> Bool {
        self[key]?.boolValue ?? fallback
    }

}

// MARK: - Schema construction sugar

public extension JSONValue {
    /// Builds a strict JSON Schema object: `additionalProperties: false` plus an
    /// explicit `required` list, as strict tool use demands.
    static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(describing description: String, enum values: [String]? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(description),
        ]
        if let values { fields["enum"] = .array(values.map { .string($0) }) }
        return .object(fields)
    }

    static func integer(describing description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func boolean(describing description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

}
