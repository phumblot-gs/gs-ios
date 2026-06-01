import Testing
import Foundation
@testable import GSAPIClient

/// Cross-platform contract test. The same `canonical-hash-fixtures.json`
/// is vendored into backend, gs-android, and here — every implementation
/// must produce the documented canonical string and SHA-256 hex, or the
/// sync feature drifts silently.
@Suite("CanonicalHash")
struct CanonicalHashTests {

    @Test("Backend fixtures: canonical + sha256 round-trip")
    func backendFixtures() throws {
        let fixtures = try loadFixtures()
        for fixture in fixtures.cases {
            // The migration-ping-pong case is exercised in its own
            // test (it carries different keys + a merge step).
            guard let input = fixture.input,
                  let canonical = fixture.canonical,
                  let expectedHash = fixture.sha256_hex
            else { continue }
            let actualCanonical = try CanonicalHash.canonicalize(input.value)
            #expect(
                actualCanonical == canonical,
                "case \(fixture.name): canonical mismatch — got \(actualCanonical) want \(canonical)"
            )
            let actualHash = try CanonicalHash.sha256Hex(input.value)
            #expect(
                actualHash == expectedHash,
                "case \(fixture.name): sha256 mismatch — got \(actualHash) want \(expectedHash)"
            )
        }
    }

    @Test("Migration ping-pong: V1 push union preserves V2-unknown keys")
    func migrationPingPongMerge() throws {
        let fixtures = try loadFixtures()
        guard let migration = fixtures.cases.first(where: { $0.name == "migration-ping-pong-guard" }),
              let pulled = migration.v2_blob_pulled?.value as? [String: Any],
              let localAfterEdit = migration.v1_local_after_modif?.value as? [String: Any],
              let expectedBlob = migration.v1_expected_push_blob?.value as? [String: Any],
              let expectedCanonical = migration.v1_expected_push_canonical,
              let expectedHash = migration.v1_expected_push_hash
        else {
            Issue.record("migration-ping-pong-guard fixture missing or malformed")
            return
        }

        // V1 only knows `lang` (mimics an older app version unaware of
        // V2's additions). The merge must preserve every other key.
        let knownKeys: Set<String> = ["lang"]
        let merged = SettingsSyncMerge.unionForPush(
            local: localAfterEdit,
            pulled: pulled,
            knownKeys: knownKeys
        )
        let mergedCanonical = try CanonicalHash.canonicalize(merged)
        let expectedCanonicalFromBlob = try CanonicalHash.canonicalize(expectedBlob)
        #expect(mergedCanonical == expectedCanonicalFromBlob)
        #expect(mergedCanonical == expectedCanonical)

        let mergedHash = try CanonicalHash.sha256Hex(merged)
        #expect(mergedHash == expectedHash)
    }

    @Test("unionForPush: local wins on collisions of known keys")
    func unionForPushLocalWins() {
        let local: [String: Any] = ["lang": "fr", "photoQuality": "high"]
        let pulled: [String: Any] = ["lang": "en", "photoQuality": "low", "extra": "X"]
        let merged = SettingsSyncMerge.unionForPush(
            local: local,
            pulled: pulled,
            knownKeys: ["lang", "photoQuality"]
        )
        #expect((merged["lang"] as? String) == "fr")
        #expect((merged["photoQuality"] as? String) == "high")
        #expect((merged["extra"] as? String) == "X")
    }

    @Test("unionForPush: nil pulled is identity")
    func unionForPushNilPulled() {
        let local: [String: Any] = ["a": 1]
        let merged = SettingsSyncMerge.unionForPush(local: local, pulled: nil, knownKeys: ["a"])
        #expect((merged["a"] as? Int) == 1)
        #expect(merged.count == 1)
    }

    // MARK: - Fixture model

    private struct Fixtures: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let input: AnyJSON?
        let canonical: String?
        let sha256_hex: String?
        let v2_blob_pulled: AnyJSON?
        let v1_local_after_modif: AnyJSON?
        let v1_expected_push_blob: AnyJSON?
        let v1_expected_push_canonical: String?
        let v1_expected_push_hash: String?
    }

    /// Wrapper that decodes arbitrary JSON into an `Any` graph using
    /// `JSONSerialization` (the standard Decodable conformance has no
    /// "any" target).
    private struct AnyJSON: Decodable {
        let value: Any
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Re-encode the underlying token via JSONSerialization to
            // get a Foundation-typed graph (`[String: Any]`, etc.).
            if let dict = try? container.decode([String: AnyJSON].self) {
                value = dict.mapValues { $0.value }
            } else if let array = try? container.decode([AnyJSON].self) {
                value = array.map(\.value)
            } else if let b = try? container.decode(Bool.self) {
                value = b
            } else if let i = try? container.decode(Int64.self) {
                value = i
            } else if let d = try? container.decode(Double.self) {
                value = d
            } else if let s = try? container.decode(String.self) {
                value = s
            } else if container.decodeNil() {
                value = NSNull()
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value"
                )
            }
        }
    }

    private func loadFixtures() throws -> Fixtures {
        guard let url = Bundle.module.url(
            forResource: "canonical-hash-fixtures",
            withExtension: "json"
        ) else {
            Issue.record("canonical-hash-fixtures.json not found in test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }
}
