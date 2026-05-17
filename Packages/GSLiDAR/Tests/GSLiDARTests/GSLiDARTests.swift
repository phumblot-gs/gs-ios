import Testing
import Foundation
import GSCore
@testable import GSLiDAR

@Suite("GSLiDAR")
struct GSLiDARTests {
    @Test("LiDARScanResult retains its measurement")
    func resultHoldsMeasurement() {
        let measurement = Measurement(widthMM: 10, heightMM: 20, depthMM: 30)
        let result = LiDARScanResult(measurement: measurement, meshAnchors: 5)
        #expect(result.measurement.widthMM == 10)
        #expect(result.meshAnchors == 5)
    }

    @Test("Photogrammetry stub does not throw")
    func photogrammetryStub() async throws {
        let session = ObjectCapturePhotogrammetry()
        let tmp = FileManager.default.temporaryDirectory
        try await session.process(inputFolder: tmp, outputURL: tmp.appendingPathComponent("out.usdz"))
    }
}
