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
}

// Test-only helper. Actor isolation requires an async setter.
extension MockGSAPI {
    func setStubbedSample(_ sample: Sample) {
        self.stubbedSample = sample
    }
}
