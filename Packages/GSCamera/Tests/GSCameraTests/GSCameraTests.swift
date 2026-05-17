import Testing
import AVFoundation
@testable import GSCamera

@Suite("GSCamera")
struct GSCameraTests {
    @Test("Default config requests highest quality and no RAW")
    func defaultConfig() {
        let cfg = CameraConfig()
        #expect(cfg.preferRAW == false)
        #expect(cfg.maxPhotoQualityPrioritization == .quality)
    }

    @Test("Custom config retains values")
    func customConfig() {
        let cfg = CameraConfig(preferRAW: true, maxPhotoQualityPrioritization: .balanced)
        #expect(cfg.preferRAW == true)
        #expect(cfg.maxPhotoQualityPrioritization == .balanced)
    }
}
