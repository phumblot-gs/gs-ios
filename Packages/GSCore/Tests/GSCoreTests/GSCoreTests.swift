import Testing
import Foundation
@testable import GSCore

@Suite("GSCore domain models")
struct GSCoreTests {
    @Test("Sample initialises with defaults")
    func sampleInit() {
        let s = Sample(barcode: "1234567890123")
        #expect(s.barcode == "1234567890123")
        #expect(s.productID == nil)
    }

    @Test("Shipment direction round-trips through Codable")
    func shipmentCodable() throws {
        let original = Shipment(direction: .outbound, trackingNumber: "ABC")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Shipment.self, from: data)
        #expect(decoded.direction == .outbound)
        #expect(decoded.trackingNumber == "ABC")
    }

    @Test("Measurement holds millimetre values")
    func measurement() {
        let m = Measurement(widthMM: 100, heightMM: 200, depthMM: 50)
        #expect(m.widthMM == 100)
        #expect(m.heightMM == 200)
        #expect(m.depthMM == 50)
    }

    @Test("GSLogger can be constructed without crashing")
    func logger() {
        let log = GSLogger(category: "test")
        log.debug("hello")
        log.info("hello")
        log.warning("hello")
        log.error("hello")
    }

    @Test("Default environment uses /v3 base URL")
    func environmentPlaceholder() {
        let env = GSEnvironment.placeholder
        #expect(env.apiBaseURL.absoluteString.contains("/v3"))
    }
}
