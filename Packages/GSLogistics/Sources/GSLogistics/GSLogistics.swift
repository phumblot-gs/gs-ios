import Foundation
import GSCore
import GSAPIClient

// MARK: - Receive Sample

/// Use-case: a sample arrives at the studio. Workflow is "scan barcode → mark
/// as received in the backend".
public struct ReceiveSampleUseCase: Sendable {
    private let api: GSAPIProtocol
    private let logger = GSLogger(category: "GSLogistics.Receive")

    public init(api: GSAPIProtocol) {
        self.api = api
    }

    /// Resolve the sample by barcode and mark it as received now.
    @discardableResult
    public func callAsFunction(barcode: String) async throws -> Sample {
        let existing = try await api.fetchSample(barcode: barcode)
        let received = Sample(
            id: existing.id,
            barcode: existing.barcode,
            productID: existing.productID,
            receivedAt: Date(),
            shippedAt: existing.shippedAt
        )
        logger.info("Receiving sample \(barcode)")
        return try await api.receiveSample(received)
    }
}

// MARK: - Ship Sample

/// Use-case: a sample leaves the studio. Builds an outbound shipment and
/// hands it to the backend.
public struct ShipSampleUseCase: Sendable {
    private let api: GSAPIProtocol
    private let logger = GSLogger(category: "GSLogistics.Ship")

    public init(api: GSAPIProtocol) {
        self.api = api
    }

    @discardableResult
    public func callAsFunction(
        sampleIDs: [UUID],
        trackingNumber: String?
    ) async throws -> Shipment {
        let shipment = Shipment(
            direction: .outbound,
            trackingNumber: trackingNumber,
            sampleIDs: sampleIDs
        )
        logger.info("Creating outbound shipment with \(sampleIDs.count) sample(s)")
        return try await api.createShipment(shipment)
    }
}
