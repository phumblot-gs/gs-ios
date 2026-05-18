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
        var components = URLComponents()
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url(relativeTo: environment.apiBaseURL)?.absoluteURL else {
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
        var components = URLComponents()
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url(relativeTo: environment.apiBaseURL)?.absoluteURL else {
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.http(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return (data, response)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // The empty-body case (e.g. DELETE 204) shows up here too — wrap
        // it sensibly when the caller expects `EmptyResponse`.
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }
}

/// Marker type for endpoints that return no body (e.g. PATCH /stock/:id).
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}
