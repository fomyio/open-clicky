import Testing
import Foundation
@testable import OpenClickyKit

/// Every tool call's arguments arrive through these accessors, so a bug here is a
/// bug in every tool at once — and a coordinate read as the wrong type would make
/// each click miss without anything looking broken.
@Suite("JSON argument decoding")
struct JSONValueTests {

    private let arguments = JSONValue.object([
        "text": .string("hello"),
        "count": .number(42),
        "ratio": .number(0.75),
        "flag": .bool(true),
        "nothing": .null,
        "nested": .object(["inner": .string("deep")]),
        "list": .array([.string("a"), .number(1)]),
    ])

    // MARK: - Throwing accessors

    @Test("Typed values are extracted")
    func extractsTypedValues() throws {
        #expect(try arguments.string("text") == "hello")
        #expect(try arguments.int("count") == 42)
        #expect(try arguments.double("ratio") == 0.75)
    }

    /// Coordinates arrive as JSON numbers, and the model may send either form.
    @Test("A whole number reads as both an integer and a double")
    func numbersAreInterchangeable() throws {
        #expect(try arguments.int("count") == 42)
        #expect(try arguments.double("count") == 42.0)
    }

    @Test("A missing field throws rather than defaulting")
    func missingFieldsThrow() {
        #expect(throws: JSONValue.MissingField.self) { try arguments.string("absent") }
        #expect(throws: JSONValue.MissingField.self) { try arguments.int("absent") }
        #expect(throws: JSONValue.MissingField.self) { try arguments.double("absent") }
    }

    /// Silently coercing a wrong-typed argument is how a tool ends up acting on
    /// something the model did not mean.
    @Test("A wrong-typed field throws rather than coercing")
    func wrongTypesThrow() {
        #expect(throws: JSONValue.MissingField.self) { try arguments.int("text") }
        #expect(throws: JSONValue.MissingField.self) { try arguments.string("count") }
        #expect(throws: JSONValue.MissingField.self) { try arguments.double("flag") }
    }

    @Test("null is treated as absent, not as a value")
    func nullIsAbsent() {
        #expect(throws: JSONValue.MissingField.self) { try arguments.string("nothing") }
        #expect(arguments["nothing"]?.stringValue == nil)
    }

    /// The message reaches the model as a tool error, so it has to say what was wrong.
    @Test("The error names the field and the expected type")
    func errorIsInformative() {
        do {
            _ = try arguments.int("text")
            Issue.record("expected a throw")
        } catch let error as JSONValue.MissingField {
            #expect(error.description.contains("text"))
            #expect(error.description.contains("integer"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    // MARK: - Defaulting accessors

    @Test("Defaults apply only when the field is missing or wrong-typed")
    func defaultsApplyCorrectly() {
        #expect(arguments.string("text", default: "fallback") == "hello")
        #expect(arguments.string("absent", default: "fallback") == "fallback")
        #expect(arguments.int("count", default: 0) == 42)
        #expect(arguments.int("text", default: 7) == 7, "a wrong type falls back rather than crashing")
        #expect(arguments.bool("flag", default: false) == true)
        #expect(arguments.bool("absent", default: true) == true)
    }

    // MARK: - Traversal

    @Test("Subscripting reaches nested values and returns nil off the path")
    func subscriptTraversal() {
        #expect(arguments["nested"]?["inner"]?.stringValue == "deep")
        #expect(arguments["nested"]?["missing"] == nil)
        #expect(arguments["text"]?["anything"] == nil, "a scalar has no members")
        #expect(JSONValue.string("scalar")["key"] == nil)
    }

    @Test("Accessors on a non-object return nil rather than trapping")
    func accessorsOnScalars() {
        let scalar = JSONValue.number(1)
        #expect(scalar.objectValue == nil)
        #expect(scalar.arrayValue == nil)
        #expect(scalar.stringValue == nil)
        #expect(scalar.intValue == 1)
    }

    // MARK: - Round-tripping

    @Test("Every representable value survives a round trip", arguments: [
        JSONValue.null,
        .bool(true),
        .number(42),
        .number(-0.5),
        .string("with \"quotes\" and \\ backslash"),
        .array([.number(1), .string("two"), .null]),
        .object(["a": .array([.object(["b": .bool(false)])])]),
    ])
    func roundTrips(value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    /// Coordinates and schema counts must not appear on the wire as `640.0`.
    @Test("Whole numbers encode without a decimal point")
    func wholeNumbersEncodeAsIntegers() throws {
        let encoded = String(decoding: try JSONEncoder().encode(
            JSONValue.object(["x": .number(640), "y": .number(0.5)])
        ), as: UTF8.self)
        #expect(encoded.contains("640"))
        #expect(!encoded.contains("640.0"))
        #expect(encoded.contains("0.5"))
    }

    @Test("Deeply nested structures survive")
    func deepNesting() throws {
        var value = JSONValue.string("bottom")
        for _ in 0..<40 { value = .object(["down": value]) }
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    // MARK: - Schema construction

    /// Strict tool use requires both of these, and the API rejects a tool without them.
    @Test("Schemas are closed and list their required fields")
    func schemasAreStrict() {
        let schema = JSONValue.schema([
            "path": .string(describing: "A path"),
            "count": .integer(describing: "How many"),
            "force": .boolean(describing: "Whether to force"),
        ], required: ["path"])

        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["additionalProperties"]?.boolValue == false)
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["path"])
        #expect(schema["properties"]?["count"]?["type"]?.stringValue == "integer")
        #expect(schema["properties"]?["force"]?["type"]?.stringValue == "boolean")
    }

    @Test("An enum constrains a string property")
    func enumeratedStrings() {
        let property = JSONValue.string(describing: "A button", enum: ["left", "right"])
        #expect(property["enum"]?.arrayValue?.compactMap(\.stringValue) == ["left", "right"])

        let plain = JSONValue.string(describing: "Free text")
        #expect(plain["enum"] == nil)
    }

    @Test("A schema with no properties is still well-formed")
    func emptySchema() {
        let schema = JSONValue.schema([:], required: [])
        #expect(schema["additionalProperties"]?.boolValue == false)
        #expect(schema["required"]?.arrayValue?.isEmpty == true)
    }
}
