import Foundation

/// The anti-ping-pong merge rule from `BACKEND_SETTINGS_SYNC.v3.md` §7.
///
/// When the app pushes, it sends `(local known keys) ∪ (keys present in
/// the last-pulled blob that this app version doesn't know about)`. The
/// "unknown" bucket guarantees that a V1 of the app doesn't silently drop
/// the keys a V2 introduced — without this rule, V1 would overwrite the
/// central blob with a strict subset every time it pushes.
///
/// Local always wins on known keys (collision in favour of local).
public enum SettingsSyncMerge {

    /// Union of local + the keys of `pulled` that this app doesn't list
    /// in `knownKeys`. `pulled == nil` (no remote pull yet) → identity
    /// on local.
    public static func unionForPush(
        local: [String: Any],
        pulled: [String: Any]?,
        knownKeys: Set<String>
    ) -> [String: Any] {
        guard let pulled else { return local }
        var merged = local
        for (key, value) in pulled where !knownKeys.contains(key) && merged[key] == nil {
            merged[key] = value
        }
        return merged
    }
}
