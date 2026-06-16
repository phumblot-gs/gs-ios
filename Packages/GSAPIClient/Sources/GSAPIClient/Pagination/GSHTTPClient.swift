import Foundation
import GSCore

/// Hand-rolled HTTP client for the Grand Shooting API. Used for endpoints
/// that the swift-openapi-generator path doesn't cover well — chiefly
/// paginated lists where we need to inject the `offset` *header* (not
/// query param, which is the GS convention) and read `X-Total-Count` /
/// `X-Offset` / `X-Count` back.
///
/// Auth resolution piggybacks on `GSAuthSession.shared`, so OAuth and the
/// personal-key fallback both work transparently.
public struct GSHTTPClient: Sendable {

    public enum HTTPError: Error, Sendable {
        case notAuthenticated
        case http(status: Int, body: String?)
        case decoding(any Error)
        case transport(any Error)
        case invalidURL
    }

    private let environment: GSEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(environment: GSEnvironment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
        let dec = JSONDecoder()
        // Most fields on our domain types declare explicit snake_case
        // `CodingKeys`, but lean on the convertFromSnakeCase strategy as a
        // safety net for the ones we missed.
        dec.keyDecodingStrategy = .useDefaultKeys
        self.decoder = dec
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .useDefaultKeys
        self.encoder = enc
    }

    // MARK: - Single-resource calls

    public func get<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", query: query, offset: nil, body: nil)
        let (data, _) = try await perform(request)
        return try decode(T.self, from: data)
    }

    public func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: T.Type = T.self
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "POST", query: [:], offset: nil, body: body)
        let (data, _) = try await perform(request)
        return try decode(T.self, from: data)
    }

    public func patch<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: T.Type = T.self
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "PATCH", query: [:], offset: nil, body: body)
        let (data, _) = try await perform(request)
        return try decode(T.self, from: data)
    }

    public func put<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: T.Type = T.self
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "PUT", query: [:], offset: nil, body: body)
        let (data, _) = try await perform(request)
        return try decode(T.self, from: data)
    }

    // MARK: - Multipart upload

    public struct MultipartPart: Sendable {
        public let name: String
        public let filename: String?
        public let contentType: String?
        public let data: Data

        public init(
            name: String,
            filename: String? = nil,
            contentType: String? = nil,
            data: Data
        ) {
            self.name = name
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }
    }

    /// POST a `multipart/form-data` body. Used for photo uploads where
    /// the file goes in a `file` part next to a few text parts. Shares
    /// `perform()` (auth header injection + error mapping) with the
    /// JSON path above.
    public func postMultipart<T: Decodable & Sendable>(
        _ path: String,
        parts: [MultipartPart],
        as type: T.Type = T.self
    ) async throws -> T {
        guard let url = buildURL(path: path, query: [:]) else {
            throw HTTPError.invalidURL
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n".data(using: .utf8)!
        for part in parts {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename {
                disposition += "; filename=\"\(filename)\""
            }
            disposition += "\r\n"
            body.append(disposition.data(using: .utf8)!)
            if let contentType = part.contentType {
                body.append("Content-Type: \(contentType)\r\n".data(using: .utf8)!)
            }
            body.append(crlf)
            body.append(part.data)
            body.append(crlf)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAccountHeader(to: &request, path: path)
        request.httpBody = body

        let (data, _) = try await perform(request)
        return try decode(T.self, from: data)
    }

    // MARK: - Paginated calls

    /// GET that returns a page of items plus the parsed `PaginationInfo`.
    /// The page size is fixed by the server; `offset` is passed in the
    /// `offset` request header per GS convention.
    public func getPage<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        offset: Int = 0,
        as type: T.Type = T.self
    ) async throws -> (items: [T], pagination: PaginationInfo) {
        let request = try makeRequest(path: path, method: "GET", query: query, offset: offset, body: nil)
        let (data, response) = try await perform(request)
        let items: [T] = try decode([T].self, from: data)
        let headers = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        return (items, PaginationInfo(from: headers))
    }

    // MARK: - Request building

    private func makeRequest<Body: Encodable>(
        path: String,
        method: String,
        query: [String: String],
        offset: Int?,
        body: Body?
    ) throws -> URLRequest {
        let effective = effectiveQuery(path: path, method: method, query: query)
        guard let url = buildURL(path: path, query: effective) else {
            throw HTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAccountHeader(to: &request, path: path)
        if let offset {
            request.setValue(String(offset), forHTTPHeaderField: "offset")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [String: String],
        offset: Int?,
        body: Data?
    ) throws -> URLRequest {
        // Overload that skips the encoder when there's no typed body.
        let effective = effectiveQuery(path: path, method: method, query: query)
        guard let url = buildURL(path: path, query: effective) else {
            throw HTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAccountHeader(to: &request, path: path)
        if let offset {
            request.setValue(String(offset), forHTTPHeaderField: "offset")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// `/stock*` and `/account*` always run on the user's **principal
    /// (home) shard**, regardless of the selector. The `account_id`
    /// header they carry depends on the path: bare `/stock` (+
    /// `/stock/{id}`) sends the **principal** account — the account the
    /// authenticated user belongs to — while the **active** account
    /// travels in the query (GET) or payload (POST/PATCH); `/stock/batch*`,
    /// `/stock/zone*` and `/account*` carry no header. Every other path
    /// targets the selected account's shard and carries the active
    /// account in the header so GS scopes the response to that account.
    private func routesToPrincipalShard(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return normalized.hasPrefix("/stock") || normalized.hasPrefix("/account")
    }

    private func isStockPath(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return normalized.hasPrefix("/stock")
    }

    private func isStockBatchOrZonePath(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return normalized.hasPrefix("/stock/batch") || normalized.hasPrefix("/stock/zone")
    }

    /// Bare `/stock` (search, list, create) and `/stock/{id}` (update) —
    /// everything under `/stock` except the `/stock/batch*` and
    /// `/stock/zone*` sub-resources, which keep their own delegation scheme.
    private func isBareStockPath(_ path: String) -> Bool {
        isStockPath(path) && !isStockBatchOrZonePath(path)
    }

    private func applyAccountHeader(to request: inout URLRequest, path: String) {
        if isBareStockPath(path) {
            // Bare /stock (+ /stock/{id}) carries the *principal* account in
            // the header — the account the authenticated user belongs to.
            // The active account travels in the query (GET) or payload
            // (POST/PATCH) instead.
            guard let principal = environment.principalAccountID ?? environment.accountIDHeader else { return }
            request.setValue(String(principal), forHTTPHeaderField: "account_id")
            return
        }
        guard !routesToPrincipalShard(path), let accountID = environment.accountIDHeader else { return }
        request.setValue(String(accountID), forHTTPHeaderField: "account_id")
    }

    /// Merges the caller's query with the stock-delegation params GS
    /// requires when active != principal. The exact pair depends on
    /// the endpoint:
    ///
    /// - `GET /stock`, `GET /stock?batch_id=…` (search + batch contents):
    ///   the active account is sent as `account_id` in the query; the
    ///   principal account is carried in the header.
    /// - `GET /stock/batch*`, `GET /stock/zone*`: standard delegation,
    ///   `account_id = active`, `target_account_id = principal`.
    /// - `POST /stock`, `PATCH /stock/{id}`: the active `account_id` goes
    ///   in the *payload* (see `StockService`), not the query.
    /// - `POST /stock/batch*`: no delegation query (the batch is
    ///   created on the principal via shard routing + token).
    ///
    /// Caller-provided query keys win on collision (defensive — should
    /// not normally happen since services don't inject these names).
    private func effectiveQuery(path: String, method: String, query: [String: String]) -> [String: String] {
        guard isStockPath(path),
              let active = environment.accountIDHeader,
              let principal = environment.principalAccountID
        else { return query }

        var injected: [String: String] = [:]
        switch method.uppercased() {
        case "GET":
            if isStockBatchOrZonePath(path) {
                injected["account_id"] = String(active)
                injected["target_account_id"] = String(principal)
            } else {
                // Bare GET /stock: active account in the query; the
                // principal account is carried in the header.
                injected["account_id"] = String(active)
            }
        case "POST", "PATCH":
            // Bare POST /stock + PATCH /stock/{id} carry account_id in the
            // payload (see StockService); batch/zone writes need no query.
            break
        default:
            break
        }
        return injected.merging(query) { _, callerValue in callerValue }
    }

    /// Concatenate `path` onto the relevant base URL *appending* to the
    /// base's existing path (e.g. `/v3`), rather than replacing it the way
    /// `URLComponents.url(relativeTo:)` does for absolute paths.
    /// `/stock*` and `/account*` route to `principalAPIBaseURL` (the
    /// user's home shard); everything else routes to `apiBaseURL`
    /// (the selected account's shard).
    private func buildURL(path: String, query: [String: String]) -> URL? {
        let base = routesToPrincipalShard(path)
            ? (environment.principalAPIBaseURL ?? environment.apiBaseURL)
            : environment.apiBaseURL
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path
        let suffix = path.hasPrefix("/") ? path : "/" + path
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.path = trimmedBase + suffix
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    // MARK: - Execution

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        // Inject auth header at the last moment so token rotation between
        // request creation and execution is picked up.
        if let token = await GSAuthSession.shared.currentToken() {
            request.setValue(token.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        } else {
            throw HTTPError.notAuthenticated
        }

        Self.log("→ \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            Self.log("  body: \(bodyString)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.log("✗ transport error: \(error.localizedDescription)")
            throw HTTPError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            Self.log("✗ no HTTPURLResponse")
            throw HTTPError.http(status: -1, body: nil)
        }
        let bodyPreview = String(data: data, encoding: .utf8).map { $0.prefix(500) } ?? "<\(data.count) bytes binary>"
        Self.log("← \(http.statusCode) \(request.url?.lastPathComponent ?? "")  body: \(bodyPreview)")
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return (data, response)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.log("✗ decoding \(T.self) failed: \(error)")
            throw HTTPError.decoding(error)
        }
    }

    // MARK: - Logging

    private static let logger = GSLogger(category: "GSHTTPClient")

    /// All HTTP traffic is logged through `GSLogger` (visible in Xcode's
    /// debug console + Console.app). Cheap; safe to leave on in DEBUG
    /// builds and turn off later if it gets noisy.
    private static func log(_ message: String) {
        logger.debug(message)
    }
}

/// Marker type for endpoints that return no body (e.g. PATCH /stock/:id).
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}
