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
        // GSEnvironment.placeholder == .staging, which targets api-19 (the
        // user's tenant shard) and api-staging.mobile.grand-shooting.com.
        #expect(live.environment.apiBaseURL.absoluteString.contains("api-19"))
        #expect(live.environment.mobileBackendBaseURL.absoluteString.contains("api-staging.mobile"))
    }

    @Test("Generated client instantiates with a token provider")
    func generatedClientInstantiates() async {
        let client = GSGeneratedClient.make(
            environment: .placeholder,
            tokenProvider: { GSAccessToken(token: "fake-token") }
        )
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
    func mockAuthRejectsBadCredentials() {
        let mock = MockAuthService()
        #expect(throws: MockAuthService.SignInError.invalidCredentials) {
            try mock.signIn(username: "wrong", password: "wrong")
        }
    }

    @Test("MockAuthService accepts the canonical dev credentials")
    func mockAuthAcceptsValid() throws {
        let mock = MockAuthService()
        try mock.signIn(
            username: MockAuthService.acceptedUsername,
            password: MockAuthService.acceptedPassword
        )
    }
}

// Test-only helper. Actor isolation requires an async setter.
extension MockGSAPI {
    func setStubbedSample(_ sample: Sample) {
        self.stubbedSample = sample
    }
}
