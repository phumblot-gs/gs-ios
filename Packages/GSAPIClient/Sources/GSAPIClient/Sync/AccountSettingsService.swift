import Foundation
import GSCore

/// HTTP client for the centralised Settings-Sync feature, hosted on
/// the mobile backend at `${mobileBackendBaseURL}/account/settings/*`.
/// Cf. `BACKEND_SETTINGS_SYNC.v3.md` §4 + §5 + §8 for the contract.
///
/// All routes are scoped to the main account derived from the token by
/// the backend's identity middleware — clients never send the
/// `account_id` header here. Auth uses the standard GS-style
/// `Authorization: access_token <token>` (the same scheme as the GS
/// API itself).
public struct AccountSettingsService: Sendable {

    private let environment: GSEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(environment: GSEnvironment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - 7 endpoints

    /// `GET /account/settings` — list all (main, active) pairs with
    /// pointer metadata (no blob).
    public func listSummaries() async throws -> SettingsSyncListResponse {
        try await call("/account/settings", method: "GET")
    }

    /// `GET /account/settings/{active}` — settings currently applied,
    /// blob included. Throws `.notFound` if no entry exists yet.
    public func get(activeAccountID: Int) async throws -> SettingsSyncPointer {
        try await call(path(activeAccountID), method: "GET")
    }

    /// `POST /account/settings/{active}` — push a new version. The
    /// response is the pointer *after* the operation; compare its
    /// `current_version_hash` to what was sent to detect concurrent
    /// overwrites (LWW).
    ///
    /// `blobJSON` is the already-serialised JSON of the blob (an
    /// `Object` JSON). Pre-serialised so the call site can stay in
    /// `[String: Any]` land without leaking non-`Sendable` types
    /// through the async boundary.
    public func push(
        activeAccountID: Int,
        blobJSON: Data
    ) async throws -> SettingsSyncPointer {
        // Wrap as `{"settings_blob": <object>}` for the backend.
        var body = Data()
        body.append(Data("{\"settings_blob\":".utf8))
        body.append(blobJSON)
        body.append(Data("}".utf8))
        return try await call(path(activeAccountID), method: "POST", body: body)
    }

    /// `GET /account/settings/{active}/history` — metadata of all
    /// non-deleted versions, newest first.
    public func history(activeAccountID: Int) async throws -> SettingsSyncHistoryResponse {
        try await call("\(path(activeAccountID))/history", method: "GET")
    }

    /// `GET /account/settings/{active}/history/{ulid}` — historical
    /// version with its blob. Throws `.notFound` if soft-deleted.
    public func historyEntry(
        activeAccountID: Int,
        versionID: String
    ) async throws -> SettingsSyncHistoryEntryDetail {
        try await call(
            "\(path(activeAccountID))/history/\(versionID)",
            method: "GET"
        )
    }

    /// `POST /account/settings/{active}/history/{ulid}/restore` —
    /// move the pointer to that historical version. Throws
    /// `.conflict` if it's already current.
    public func restore(
        activeAccountID: Int,
        versionID: String
    ) async throws -> SettingsSyncPointer {
        try await call(
            "\(path(activeAccountID))/history/\(versionID)/restore",
            method: "POST",
            body: Data()
        )
    }

    /// `DELETE /account/settings/{active}/history/{ulid}` — soft-delete.
    /// Throws `.conflict` if it's the current pointer.
    public func deleteHistoryEntry(
        activeAccountID: Int,
        versionID: String
    ) async throws {
        let _: EmptyResponse = try await call(
            "\(path(activeAccountID))/history/\(versionID)",
            method: "DELETE"
        )
    }

    // MARK: - Plumbing

    private func path(_ active: Int) -> String {
        "/account/settings/\(active)"
    }

    private func call<T: Decodable>(
        _ path: String,
        method: String,
        body: Data? = nil
    ) async throws -> T {
        let url = environment.mobileBackendBaseURL
            .appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30

        guard let token = await GSAuthSession.shared.currentToken() else {
            throw SettingsSyncError.notAuthenticated
        }
        // GS-style auth: `access_token <token>` (matches §7 note of
        // the spec). The mobile backend tolerates `Bearer …` too,
        // but we keep one canonical form.
        request.setValue(token.authorizationHeaderValue, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SettingsSyncError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SettingsSyncError.http(status: -1, body: nil)
        }
        if (200..<300).contains(http.statusCode) {
            if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw SettingsSyncError.decoding(error)
            }
        }
        throw mapError(status: http.statusCode, headers: http.allHeaderFields, data: data)
    }

    private func mapError(
        status: Int,
        headers: [AnyHashable: Any],
        data: Data
    ) -> SettingsSyncError {
        let bodyString = String(data: data, encoding: .utf8)
        let parsed = try? JSONDecoder().decode(BackendErrorBody.self, from: data)

        switch status {
        case 429:
            let retryAfter = parsed?.details?.retry_after_seconds
                ?? headers["Retry-After"].flatMap { ($0 as? String).flatMap(Int.init) }
                ?? 5
            return .rateLimited(retryAfterSeconds: retryAfter)
        case 413:
            let max = parsed?.details?.max_bytes ?? 16384
            return .blobTooLarge(maxBytes: max)
        case 403:
            if parsed?.code == "not_admin" {
                return .forbidden(.notAdmin)
            }
            return .forbidden(.notInAccounts)
        case 409:
            return .conflict(message: parsed?.error ?? "Conflict")
        case 404:
            return .notFound
        default:
            return .http(status: status, body: bodyString)
        }
    }

    private struct BackendErrorBody: Decodable {
        let error: String?
        let code: String?
        let details: Details?

        struct Details: Decodable {
            let retry_after_seconds: Int?
            let max_bytes: Int?
        }
    }
}

// MARK: - Errors

public enum SettingsSyncError: Error, Sendable {
    case notAuthenticated
    case rateLimited(retryAfterSeconds: Int)
    case blobTooLarge(maxBytes: Int)
    case forbidden(ForbiddenReason)
    case conflict(message: String)
    case notFound
    case http(status: Int, body: String?)
    case decoding(any Error)
    case transport(any Error)

    public enum ForbiddenReason: Sendable {
        case notAdmin
        case notInAccounts
    }
}

// MARK: - Response DTOs

/// Pointer metadata for one (main, active) couple.
public struct SettingsSyncSummary: Sendable, Codable, Hashable, Identifiable {
    public let main_account_id: Int
    public let active_account_id: Int
    public let active_account_name: String?
    public let current_version_id: String
    public let current_version_hash: String
    public let updated_at: String
    public let updated_by_user_uid: Int?
    public let updated_by_user_name: String?
    public let last_action: String?

    public var id: Int { active_account_id }
}

public struct SettingsSyncListResponse: Sendable, Codable {
    public let items: [SettingsSyncSummary]
    public let next_cursor: String?
}

/// Pointer + blob. Returned by `GET /account/settings/{active}` and
/// also as the response of `POST .../`{active}` and the restore endpoint.
public struct SettingsSyncPointer: Sendable, Codable, Hashable {
    public let main_account_id: Int
    public let active_account_id: Int
    public let current_version_id: String
    public let current_version_hash: String
    public let updated_at: String
    public let updated_by_user_uid: Int?
    public let updated_by_user_name: String?
    public let last_action: String?
    public let last_restored_from_version_id: String?
    /// The settings blob currently applied. Decoded as raw JSON to
    /// keep the contract opaque (the app interprets known keys only).
    public let settings_blob: JSONValue

    public var blobAsDictionary: [String: Any] {
        JSONValue.foundationDictionary(from: settings_blob)
    }
}

public struct SettingsSyncHistoryEntry: Sendable, Codable, Hashable, Identifiable {
    public let version_id: String
    public let is_current: Bool
    public let hash: String
    public let created_at: String
    public let created_by_user_uid: Int?
    public let created_by_user_name: String?

    public var id: String { version_id }
}

public struct SettingsSyncHistoryResponse: Sendable, Codable {
    public let items: [SettingsSyncHistoryEntry]
    public let next_cursor: String?
}

public struct SettingsSyncHistoryEntryDetail: Sendable, Codable, Hashable, Identifiable {
    public let version_id: String
    public let main_account_id: Int
    public let active_account_id: Int
    public let is_current: Bool
    public let hash: String
    public let created_at: String
    public let created_by_user_uid: Int?
    public let created_by_user_name: String?
    public let settings_blob: JSONValue

    public var id: String { version_id }

    public var blobAsDictionary: [String: Any] {
        JSONValue.foundationDictionary(from: settings_blob)
    }
}

// MARK: - Opaque JSON value

/// Codable bridge so a JSON blob of arbitrary shape can be carried
/// inside a `Codable` DTO without forcing it through a typed schema.
public enum JSONValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int64.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let array = try? container.decode([JSONValue].self) { self = .array(array); return }
        if let dict = try? container.decode([String: JSONValue].self) { self = .object(dict); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let array): try container.encode(array)
        case .object(let dict): try container.encode(dict)
        }
    }

    /// Lower the wrapper back to a Foundation-typed graph. The
    /// CanonicalHash + persistence layers work in `Any`.
    public func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return Int(i)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let array): return array.map { $0.toAny() }
        case .object(let dict): return dict.mapValues { $0.toAny() }
        }
    }

    /// Round-trip the JSON graph through `JSONSerialization` so the
    /// returned dictionary uses `NSArray`/`NSNumber`/`NSString` — the
    /// shapes Swift bridges cleanly to typed arrays via `as? [Int]`
    /// or `as? [String]`. The native `[Any]` from `toAny()` only
    /// bridges reliably for top-level dicts; nested arrays don't.
    /// This indirection avoids the silent "as? [Int] returns nil"
    /// failures inside `SyncableSettings.apply`.
    public static func foundationDictionary(from value: JSONValue) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict
    }
}
