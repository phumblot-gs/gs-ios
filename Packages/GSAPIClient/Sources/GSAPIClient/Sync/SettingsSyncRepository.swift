import Foundation
import Observation
import GSCore

/// Drives the Settings-Sync state machine for one (main, active)
/// couple, holding the last-pulled snapshot locally to compute the
/// sync state and to drive the anti-ping-pong merge.
///
/// One repository serves the whole app — the active account swaps
/// underneath it. The repo exposes `@Observable` state so SwiftUI
/// views can render without holding bindings to `DevSettings`.
@Observable
@MainActor
public final class SettingsSyncRepository {

    /// Where the local blob and the remote blob diverge.
    public enum State: Sendable, Equatable {
        /// No central entry exists for this (main, active) couple.
        case noRemote
        /// Local matches the last-pulled and remote matches the last-pulled.
        case synced
        /// Local has changed since the last pull; remote hasn't.
        case localModified
        /// Remote has changed since the last pull; local hasn't.
        case remoteNewer
        /// Both sides changed since the last pull.
        case diverged
    }

    /// What the last completed action was — drives the success
    /// snackbar message.
    public enum LastAction: String, Sendable {
        case none
        case push
        case pull
        case restore
        case overwrittenByOtherDevice
    }

    // MARK: - Observable state

    public private(set) var state: State = .noRemote
    public private(set) var summary: SettingsSyncPointer?
    public private(set) var isLoading = false
    public private(set) var lastAction: LastAction = .none
    public private(set) var lastErrorMessage: String?

    /// 5-second debounce between two pushes — belt + braces vs the
    /// backend's `1/5s` rate limit on the (main, active) bucket.
    public static let pushDebounceSeconds: TimeInterval = 5

    // MARK: - Dependencies

    private var service: AccountSettingsService
    private let settings: DevSettings
    private let defaults: UserDefaults

    public init(
        service: AccountSettingsService,
        settings: DevSettings,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.settings = settings
        self.defaults = defaults
    }

    /// Replace the underlying HTTP service — useful when the backend
    /// environment changes (e.g. user flips staging ↔ production from
    /// the easter egg). State machine state is preserved.
    public func updateService(_ service: AccountSettingsService) {
        self.service = service
    }

    /// Hash of the central version this device has locally applied
    /// (= the `current_version_hash` returned at the moment of the
    /// last successful pull / push / restore). The history view uses
    /// it to render the "applied" badge — independently from the
    /// server-side `is_current` ("central") badge. Nil before any
    /// successful sync on this account.
    public func locallyAppliedHash() -> String? {
        guard let active = settings.activeAccountID else { return nil }
        let hash = defaults.string(forKey: Self.lastPulledHashKey(account: active))
        return (hash?.isEmpty == false) ? hash : nil
    }

    // MARK: - Cadence

    /// True if the auto-pull (1×/24h) is overdue for the active
    /// account. Used at sign-in time.
    public func shouldAutoPull() -> Bool {
        guard let active = settings.activeAccountID else { return false }
        let key = Self.lastAutoPullKey(account: active)
        let last = defaults.double(forKey: key)
        if last == 0 { return true }
        return Date().timeIntervalSince1970 - last > 24 * 60 * 60
    }

    public func markAutoPulled() {
        guard let active = settings.activeAccountID else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastAutoPullKey(account: active))
    }

    // MARK: - Operations

    /// Reconciles state against the backend. Doesn't mutate local
    /// settings — that only happens on an explicit `pull(applying:)`.
    public func checkForRemoteUpdate() async {
        guard let active = settings.activeAccountID else { return }
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        do {
            let pointer = try await service.get(activeAccountID: active)
            summary = pointer
            recomputeState(for: active, remoteHash: pointer.current_version_hash)
        } catch SettingsSyncError.notFound {
            summary = nil
            state = .noRemote
        } catch {
            lastErrorMessage = errorMessage(error)
        }
    }

    /// Pull the current version and apply it to `DevSettings`.
    @discardableResult
    public func pull() async -> Bool {
        guard let active = settings.activeAccountID else { return false }
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        do {
            let pointer = try await service.get(activeAccountID: active)
            summary = pointer
            let blob = pointer.blobAsDictionary
            SyncableSettings.apply(blob, to: settings)
            // Snapshot the local state AFTER apply so the "local
            // unchanged" baseline accounts for any `didSet`
            // side-effects (e.g. `defaultStockItemStatusOnRegister`
            // re-inserting itself into `enabledStockItemStatuses`).
            // Without this, pull → recomputeState immediately falls
            // back to `.localModified`.
            let postApplyHash = (try? CanonicalHash.sha256Hex(
                SyncableSettings.snapshot(from: settings)
            )) ?? pointer.current_version_hash
            persistLastSync(
                account: active,
                remoteHash: pointer.current_version_hash,
                localHash: postApplyHash,
                serverBlob: blob,
                atMs: nowMs()
            )
            recomputeState(for: active, remoteHash: pointer.current_version_hash)
            lastAction = .pull
            return true
        } catch SettingsSyncError.notFound {
            summary = nil
            state = .noRemote
            lastAction = .none
            return false
        } catch {
            lastErrorMessage = errorMessage(error)
            return false
        }
    }

    /// Push the current local blob (after applying the anti-ping-pong
    /// merge against the last-pulled blob). Throws on the rate-limit
    /// guard so the UI can show a precise retry message; other errors
    /// surface through `lastErrorMessage`.
    @discardableResult
    public func push() async throws -> Bool {
        guard let active = settings.activeAccountID else { return false }

        // Local debounce — bail before the network round-trip.
        let key = Self.lastPushedAtMsKey(account: active)
        let lastPushedMs = Int64(defaults.double(forKey: key))
        let now = nowMs()
        let delta = now - lastPushedMs
        if lastPushedMs > 0, delta < Int64(Self.pushDebounceSeconds * 1000) {
            let retry = Int(((Int64(Self.pushDebounceSeconds * 1000) - delta) + 999) / 1000)
            throw SettingsSyncError.rateLimited(retryAfterSeconds: max(retry, 1))
        }

        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        let local = SyncableSettings.snapshot(from: settings)
        if SyncableSettings.isAllDefault(local) {
            // Spec §7: don't pollute central history with all-defaults.
            lastErrorMessage = String(localized: "Nothing custom to save yet.")
            return false
        }
        let pulled = loadLastPulledBlob(account: active)
        let merged = SettingsSyncMerge.unionForPush(
            local: local,
            pulled: pulled,
            knownKeys: SyncableSettings.knownKeys
        )
        let pushedHash = (try? CanonicalHash.sha256Hex(merged)) ?? ""
        let blobJSON: Data
        do {
            blobJSON = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.sortedKeys]
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }

        do {
            let pointer = try await service.push(activeAccountID: active, blobJSON: blobJSON)
            summary = pointer
            defaults.set(Double(now), forKey: key)
            // The server may overwrite our blob (LWW). Snapshot the
            // post-apply local state from the pointer's blob so the
            // baseline matches what's actually stored locally.
            let serverBlob = pointer.blobAsDictionary
            if pointer.current_version_hash != pushedHash {
                // The remote ended up different from what we pushed
                // — another device wrote in parallel. Apply the
                // remote so local matches central.
                SyncableSettings.apply(serverBlob, to: settings)
            }
            let postApplyHash = (try? CanonicalHash.sha256Hex(
                SyncableSettings.snapshot(from: settings)
            )) ?? pointer.current_version_hash
            persistLastSync(
                account: active,
                remoteHash: pointer.current_version_hash,
                localHash: postApplyHash,
                serverBlob: serverBlob,
                atMs: now
            )
            recomputeState(for: active, remoteHash: pointer.current_version_hash)
            if pointer.current_version_hash != pushedHash {
                // Spec §7 LWW: another device pushed between our two
                // writes — surface that to the user as a soft warning.
                lastAction = .overwrittenByOtherDevice
            } else {
                lastAction = .push
            }
            return true
        } catch let error as SettingsSyncError {
            lastErrorMessage = errorMessage(error)
            throw error
        } catch {
            lastErrorMessage = errorMessage(error)
            throw error
        }
    }

    /// Move the central pointer to an older version + re-apply it
    /// locally.
    @discardableResult
    public func restore(versionID: String) async -> Bool {
        guard let active = settings.activeAccountID else { return false }
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        do {
            let pointer = try await service.restore(
                activeAccountID: active,
                versionID: versionID
            )
            summary = pointer
            let blob = pointer.blobAsDictionary
            SyncableSettings.apply(blob, to: settings)
            let postApplyHash = (try? CanonicalHash.sha256Hex(
                SyncableSettings.snapshot(from: settings)
            )) ?? pointer.current_version_hash
            persistLastSync(
                account: active,
                remoteHash: pointer.current_version_hash,
                localHash: postApplyHash,
                serverBlob: blob,
                atMs: nowMs()
            )
            recomputeState(for: active, remoteHash: pointer.current_version_hash)
            lastAction = .restore
            return true
        } catch {
            lastErrorMessage = errorMessage(error)
            return false
        }
    }

    /// Fetch the history page. The caller renders the list itself.
    public func loadHistory() async -> [SettingsSyncHistoryEntry] {
        guard let active = settings.activeAccountID else { return [] }
        do {
            return try await service.history(activeAccountID: active).items
        } catch {
            lastErrorMessage = errorMessage(error)
            return []
        }
    }

    /// Fetch one historical version (used by the "Voir le contenu" sheet).
    public func loadHistoryEntry(versionID: String) async -> SettingsSyncHistoryEntryDetail? {
        guard let active = settings.activeAccountID else { return nil }
        do {
            return try await service.historyEntry(
                activeAccountID: active,
                versionID: versionID
            )
        } catch {
            lastErrorMessage = errorMessage(error)
            return nil
        }
    }

    @discardableResult
    public func deleteHistoryEntry(versionID: String) async -> Bool {
        guard let active = settings.activeAccountID else { return false }
        do {
            try await service.deleteHistoryEntry(
                activeAccountID: active,
                versionID: versionID
            )
            return true
        } catch {
            lastErrorMessage = errorMessage(error)
            return false
        }
    }

    // MARK: - State recomputation

    /// Recompute `state` from two independent baselines:
    /// `lastAppliedLocalHash` (snapshot taken right after the last
    /// apply — local-side baseline) and `lastPulledHash` (server
    /// pointer hash at that moment — remote-side baseline). Keeping
    /// them separate avoids the false positive `.localModified` that
    /// happens when applying a remote blob triggers `didSet`
    /// side-effects on `DevSettings` (e.g. the default-status
    /// re-insertion into `enabledStockItemStatuses`).
    private func recomputeState(for account: Int, remoteHash: String?) {
        let localHash = (try? CanonicalHash.sha256Hex(
            SyncableSettings.snapshot(from: settings)
        )) ?? ""
        let lastLocalHash = defaults.string(forKey: Self.lastAppliedLocalHashKey(account: account))
        let lastPulledHash = defaults.string(forKey: Self.lastPulledHashKey(account: account))

        guard let lastPulledHash, !lastPulledHash.isEmpty, let remoteHash else {
            state = remoteHash == nil ? .noRemote : .remoteNewer
            return
        }
        let localBaseline = (lastLocalHash?.isEmpty == false) ? lastLocalHash! : lastPulledHash
        let localChanged = localHash != localBaseline
        let remoteChanged = remoteHash != lastPulledHash
        switch (localChanged, remoteChanged) {
        case (false, false): state = .synced
        case (true, false): state = .localModified
        case (false, true): state = .remoteNewer
        case (true, true): state = .diverged
        }
    }

    // MARK: - Persistence

    /// Records the post-sync baselines: `remoteHash` is the server
    /// pointer hash, `localHash` is the canonical hash of the local
    /// snapshot taken right after `SyncableSettings.apply`.
    /// `serverBlob` is the raw server payload, kept verbatim for the
    /// anti-ping-pong merge on the next push.
    private func persistLastSync(
        account: Int,
        remoteHash: String,
        localHash: String,
        serverBlob: [String: Any],
        atMs: Int64
    ) {
        defaults.set(remoteHash, forKey: Self.lastPulledHashKey(account: account))
        defaults.set(localHash, forKey: Self.lastAppliedLocalHashKey(account: account))
        defaults.set(Double(atMs), forKey: Self.lastPulledAtMsKey(account: account))
        if let data = try? JSONSerialization.data(withJSONObject: serverBlob, options: []),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.lastPulledBlobKey(account: account))
        }
    }

    private func loadLastPulledBlob(account: Int) -> [String: Any]? {
        guard let json = defaults.string(forKey: Self.lastPulledBlobKey(account: account)),
              let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = any as? [String: Any]
        else { return nil }
        return dict
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func errorMessage(_ error: any Error) -> String {
        switch error {
        case SettingsSyncError.notAuthenticated:
            return String(localized: "Not authenticated — sign in again.")
        case SettingsSyncError.rateLimited(let s):
            return String(localized: "Try again in \(s) s.")
        case SettingsSyncError.blobTooLarge(let max):
            return String(localized: "Settings too large (>\(max / 1024) KB).")
        case SettingsSyncError.forbidden(.notAdmin):
            return String(localized: "Settings sync requires admin role.")
        case SettingsSyncError.forbidden(.notInAccounts):
            return String(localized: "This account is not accessible to you.")
        case SettingsSyncError.conflict(let message):
            return message
        case SettingsSyncError.notFound:
            return String(localized: "No central settings entry yet.")
        case SettingsSyncError.http(let status, let body):
            let trimmed = (body ?? "").prefix(200)
            return "HTTP \(status) · \(trimmed)"
        case SettingsSyncError.decoding(let err):
            return "Decoding failed: \(err)"
        case SettingsSyncError.transport(let err):
            return err.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    // MARK: - UserDefaults keys

    private static func lastPulledHashKey(account: Int) -> String {
        "sync.lastPulledHash.\(account)"
    }
    private static func lastAppliedLocalHashKey(account: Int) -> String {
        "sync.lastAppliedLocalHash.\(account)"
    }
    private static func lastPulledAtMsKey(account: Int) -> String {
        "sync.lastPulledAtMs.\(account)"
    }
    private static func lastPulledBlobKey(account: Int) -> String {
        "sync.lastPulledBlob.\(account)"
    }
    private static func lastPushedAtMsKey(account: Int) -> String {
        "sync.lastPushedAtMs.\(account)"
    }
    private static func lastAutoPullKey(account: Int) -> String {
        "sync.lastAutoPullAt.\(account)"
    }
}

// MARK: - SettingsSyncPointer helpers

public extension SettingsSyncPointer {
    /// Parses `updated_at` (ISO-8601 UTC) into a `Date`. Returns nil
    /// if malformed.
    var updatedAtDate: Date? {
        ISO8601DateFormatter().date(from: updated_at)
    }
}
