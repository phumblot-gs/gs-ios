import Testing
import Foundation
@testable import GSPackshot

@Suite("GSPackshot")
struct GSPackshotTests {
    @Test("MockPackshotService returns the stubbed response")
    func mockReturnsStub() async throws {
        let mock = MockPackshotService(
            stubbedResponse: PackshotResponse(jobID: "abc", resultURL: nil, status: "queued")
        )
        let resp = try await mock.generate(PackshotRequest(imageData: Data()))
        #expect(resp.jobID == "abc")
        #expect(resp.status == "queued")
    }
}
