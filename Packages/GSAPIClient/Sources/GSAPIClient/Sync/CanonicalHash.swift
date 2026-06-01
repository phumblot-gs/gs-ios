import Foundation
import CryptoKit

/// RFC 8785 (JSON Canonicalization Scheme) + SHA-256 → hex (lowercase).
///
/// Used by Settings Sync so the same blob produces the same hash on
/// iOS, Android, and the backend — the trio cross-validates against
/// the shared `canonical-hash-fixtures.json`.
///
/// Implementation scope: covers JSON objects, arrays, strings, ints,
/// doubles, booleans and null. Our settings blob only ever uses
/// `[String: Any]` of those primitives so we stop short of the full
/// IEEE-754 → ECMA-262 conversion (we lean on Swift's `Double`
/// description, which matches for the values we actually push).
public enum CanonicalHash {

    public enum Error: Swift.Error {
        /// The value contains a type we don't know how to serialise
        /// (anything outside the JSON primitives + container types).
        case unsupportedType(Any.Type)
    }

    /// Canonical UTF-8 JSON string per RFC 8785. Same input always
    /// yields the same bytes, regardless of insertion order.
    public static func canonicalize(_ value: Any) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    /// SHA-256 of the canonical JSON, lowercase hex (64 chars).
    public static func sha256Hex(_ value: Any) throws -> String {
        let canonical = try canonicalize(value)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Recursive serializer

    private static func write(_ value: Any, into out: inout String) throws {
        if value is NSNull {
            out += "null"
            return
        }
        if let b = value as? Bool, isActuallyBool(value) {
            out += b ? "true" : "false"
            return
        }
        if let n = value as? NSNumber {
            // NSNumber covers Int*, Double, Float, Bool. Bool is
            // routed above; for the rest pick int vs float by the
            // underlying CF type so 42 stays "42", not "42.0".
            if isInteger(n) {
                out += n.stringValue
            } else {
                out += formatDouble(n.doubleValue)
            }
            return
        }
        if let i = value as? Int {
            out += String(i)
            return
        }
        if let d = value as? Double {
            out += formatDouble(d)
            return
        }
        if let s = value as? String {
            out += escape(s)
            return
        }
        if let array = value as? [Any] {
            out += "["
            for (i, element) in array.enumerated() {
                if i > 0 { out += "," }
                try write(element, into: &out)
            }
            out += "]"
            return
        }
        if let dict = value as? [String: Any] {
            // Lexicographic sort on the raw UTF-16 code units.
            // Swift `String` `<` already uses this comparison.
            let sortedKeys = dict.keys.sorted()
            out += "{"
            for (i, key) in sortedKeys.enumerated() {
                if i > 0 { out += "," }
                out += escape(key)
                out += ":"
                try write(dict[key] as Any, into: &out)
            }
            out += "}"
            return
        }
        throw Error.unsupportedType(type(of: value))
    }

    // MARK: - Primitive formatters

    /// `Bool` and `NSNumber(value: true/false)` both satisfy `is Bool`.
    /// We need to make sure we don't treat `NSNumber(value: 1)` as a
    /// bool — check the underlying ObjC type identity.
    private static func isActuallyBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return value is Bool
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// True when an NSNumber wraps an integer rather than a float.
    private static func isInteger(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        // ObjC type encodings: c=char, i=int, s=short, l=long, q=long long,
        // C=unsigned char, I=unsigned int, S=unsigned short, L=unsigned long,
        // Q=unsigned long long, f=float, d=double, B=bool.
        switch type {
        case "c", "i", "s", "l", "q", "C", "I", "S", "L", "Q":
            return true
        default:
            return false
        }
    }

    /// ECMA-262 `Number.prototype.toString()`-ish formatting. Strips
    /// the trailing `.0` Swift adds for integral doubles. Doesn't
    /// implement the full IEEE-754 shortest-roundtrip dance — the
    /// blobs we push don't carry doubles today, but the test
    /// fixtures cover ints exhaustively.
    private static func formatDouble(_ d: Double) -> String {
        if d.isNaN || d.isInfinite {
            // RFC 7159 forbids NaN/Infinity in JSON; the canonical
            // form has nothing to emit. We map to "null" to keep
            // the SHA stable rather than throw mid-walk.
            return "null"
        }
        if d == d.rounded() && abs(d) < 1e16 {
            return String(Int64(d))
        }
        return String(d)
    }

    /// JSON-standard string escaping: `\"`, `\\`, and the C0
    /// controls per RFC 8259 §7. Non-ASCII passes through as UTF-8
    /// (we serialise the whole document as UTF-8 bytes anyway).
    private static func escape(_ string: String) -> String {
        var out = "\""
        out.reserveCapacity(string.utf8.count + 2)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
