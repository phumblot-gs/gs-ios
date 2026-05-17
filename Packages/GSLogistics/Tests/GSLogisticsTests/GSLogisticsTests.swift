import Testing
import Foundation
import GSCore
import GSAPIClient
@testable import GSLogistics

@Suite("GSLogistics use-cases")
struct GSLogisticsTests {
    @Test("ReceiveSampleUseCase stamps receivedAt and calls the API")
    func receiveSample() async throws {
        let mock = MockGSAPI()
        let useCase = ReceiveSampleUseCase(api: mock)
        let result = try await useCase(barcode: "1234567890123")
        #expect(result.barcode == "1234567890123")
    }

    @Test("ShipSampleUseCase produces an outbound shipment")
    func shipSample() async throws {
        let mock = MockGSAPI()
        let useCase = ShipSampleUseCase(api: mock)
        let ids = [UUID(), UUID()]
        let shipment = try await useCase(sampleIDs: ids, trackingNumber: "TRACK-1")
        #expect(shipment.direction == .outbound)
        #expect(shipment.sampleIDs.count == 2)
        #expect(shipment.trackingNumber == "TRACK-1")
    }
}
