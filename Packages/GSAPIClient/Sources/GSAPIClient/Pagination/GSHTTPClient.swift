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
        guard let url = buildURL(path: path, query: query) else {
            throw HTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        guard let url = buildURL(path: path, query: query) else {
            throw HTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let offset {
            request.setValue(String(offset), forHTTPHeaderField: "offset")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Concatenate `path` onto `environment.apiBaseURL` *appending* to the
    /// base's existing path (e.g. `/v3`), rather than replacing it the way
    /// `URLComponents.url(relativeTo:)` does for absolute paths.
    private func buildURL(path: String, query: [String: String]) -> URL? {
        guard var components = URLComponents(url: environment.apiBaseURL, resolvingAgainstBaseURL: false) else {
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
