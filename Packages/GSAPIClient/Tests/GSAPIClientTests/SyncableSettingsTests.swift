import Testing
import Foundation
@testable import GSAPIClient

/// Locks down the round-trip from a server-returned `settings_blob`
/// (JSON wire format) → `[String: Any]` exposed by the DTO → applied
/// values on `DevSettings`. The previous bug was that arrays of ints
/// came back as `[Any]` from `JSONValue.toAny()` and silently failed
/// the `as? [Int]` downcast inside `SyncableSettings.apply`.
@Suite("SyncableSettings apply")
@MainActor
struct SyncableSettingsApplyTests {

    @Test("Server blob int-array decodes + applies through SyncableSettings")
    func enabledStatusesRoundTrip() throws {
        let json = """
        {
          "main_account_id": 16,
          "active_account_id": 957,
          "current_version_id": "01HZRX2K8H",
          "current_version_hash": "abcd",
          "updated_at": "2026-05-30T10:00:00Z",
          "updated_by_user_uid": 8836,
          "updated_by_user_name": "Paul",
          "last_action": "push",
          "last_restored_from_version_id": null,
          "settings_blob": {
            "enabled_stock_item_statuses": [0, 2, 5, 9],
            "batch_types": ["A", "B", "C"],
            "ocr_enabled": true,
            "focal_presentation": 85
          }
        }
        """
        let pointer = try JSONDecoder().decode(
            SettingsSyncPointer.self,
            from: Data(json.utf8)
        )
        let blob = pointer.blobAsDictionary

        // Critical assertion: the array values must downcast cleanly
        // — the bug we're guarding against returned nil here, so
        // `apply` silently skipped these keys and the user's local
        // values were never replaced.
        let statuses = blob["enabled_stock_item_statuses"] as? [Int]
        #expect(statuses == [0, 2, 5, 9])
        let batchTypes = blob["batch_types"] as? [String]
        #expect(batchTypes == ["A", "B", "C"])
        #expect((blob["ocr_enabled"] as? Bool) == true)
        #expect((blob["focal_presentation"] as? Int) == 85)
    }
}
