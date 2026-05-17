import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import GSCore
#if canImport(HTTPTypes)
import HTTPTypes
#endif

/// A thin factory around the swift-openapi-generator output.
///
/// The build plugin generates `Client`, `Components.Schemas.*`, and
/// `Operations.*` from `openapi.yaml`. We re-export them through this file
/// so the rest of the app imports `GSAPIClient` and gets everything it needs.
public enum GSGeneratedClient {

    /// Build a configured `Client` ready to call any Grand Shooting endpoint.
    ///
    /// - Parameters:
    ///   - environment: per-account shard + base URL.
    ///   - tokenProvider: async closure returning the current access token. Pass
    ///     `nil` to issue unauthenticated calls (rare — most endpoints require auth).
    ///   - session: customizable URLSession (e.g. for tests).
    public static func make(
        environment: GSEnvironment,
        tokenProvider: @Sendable @escaping () async -> GSAccessToken? = { nil },
        session: URLSession = .shared
    ) -> Client {
        let transport = URLSessionTransport(
            configuration: .init(session: session)
        )
        return Client(
            serverURL: environment.apiBaseURL,
            transport: transport,
            middlewares: [
                AccessTokenMiddleware(tokenProvider: tokenProvider)
            ]
        )
    }
}

// MARK: - Middleware

/// Injects the Grand Shooting `Authorization: access_token <token>` header
/// on every request. Not Bearer — GS uses a custom scheme.
struct AccessTokenMiddleware: ClientMiddleware {
    let tokenProvider: @Sendable () async -> GSAccessToken?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = await tokenProvider() {
            request.headerFields[.authorization] = "access_token \(token.token)"
        }
        return try await next(request, body, baseURL)
    }
}
