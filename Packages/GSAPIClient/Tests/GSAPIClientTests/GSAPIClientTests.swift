import Testing
import Foundation
@testable import GSAPIClient
import GSCore

@Suite("GSAPIClient")
struct GSAPIClientTests {
    @Test("MockGSAPI returns the stubbed sample when set")
    func mockReturnsStub() async throws {
        let mock = MockGSAPI()
        await mock.setStubbedSample(Sample(barcode: "EAN13-stubbed"))
        let result = try await mock.fetchSample(barcode: "anything")
        #expect(result.barcode == "EAN13-stubbed")
    }

    @Test("MockGSAPI echoes the barcode when no stub is configured")
    func mockEchoesBarcode() async throws {
        let mock = MockGSAPI()
        let result = try await mock.fetchSample(barcode: "1234567890123")
        #expect(result.barcode == "1234567890123")
    }

    @Test("Live API exposes the configured environment")
    func liveEnvironment() async {
        let live = LiveGSAPI(environment: .placeholder)
        #expect(live.environment.apiBaseURL.absoluteString.contains("api-34"))
    }

    @Test("Generated client instantiates with a token provider")
    func generatedClientInstantiates() async {
        let client = GSGeneratedClient.make(
            environment: .placeholder,
            tokenProvider: { GSAccessToken(token: "fake-token") }
        )
        // The instance itself is enough — we don't hit the network here.
        // The compile-time test is that the generated `Client` type exists.
        _ = client
    }

    @Test("GSAccessToken renders both auth schemes correctly")
    func tokenAuthorizationHeader() {
        let bearer = GSAccessToken(token: "abc", scheme: .bearer)
        #expect(bearer.authorizationHeaderValue == "Bearer abc")
        let oauth = GSAccessToken(token: "abc", scheme: .accessToken)
        #expect(oauth.authorizationHeaderValue == "access_token abc")
    }

    @Test("MockAuthService rejects bad credentials")
    func mockAuthRejectsBadCredentials() async {
        let mock = MockAuthService()
        await #expect(throws: MockAuthService.SignInError.invalidCredentials) {
            _ = try await mock.signIn(username: "wrong", password: "wrong", bearerToken: "x")
        }
    }

    @Test("MockAuthService rejects an empty bearer token")
    func mockAuthRejectsEmptyToken() async {
        let mock = MockAuthService()
        await #expect(throws: MockAuthService.SignInError.missingBearerToken) {
            _ = try await mock.signIn(
                username: MockAuthService.acceptedUsername,
                password: MockAuthService.acceptedPassword,
                bearerToken: "   "
            )
        }
    }

    @Test("MockAuthService persists a bearer token on success")
    func mockAuthPersistsToken() async throws {
        let mock = MockAuthService()
        let token = try await mock.signIn(
            username: MockAuthService.acceptedUsername,
            password: MockAuthService.acceptedPassword,
            bearerToken: "test-bearer-xyz"
        )
        #expect(token.scheme == .bearer)
        #expect(token.authorizationHeaderValue == "Bearer test-bearer-xyz")
        let current = await GSAuthSession.shared.currentToken()
        #expect(current?.token == "test-bearer-xyz")
        // Cleanup so subsequent test runs don't see leftover state.
        await GSAuthSession.shared.setToken(nil)
    }
}

// Test-only helper. Actor isolation requires an async setter.
extension MockGSAPI {
    func setStubbedSample(_ sample: Sample) {
        self.stubbedSample = sample
    }
}
