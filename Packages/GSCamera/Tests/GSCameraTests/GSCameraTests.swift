import Testing
import Foundation
@testable import GSCamera

@Suite("GSCamera")
struct GSCameraTests {
    @Test("CapturedPhoto carries its payload + timestamp")
    func capturedPhotoInit() {
        let payload = Data([0xff, 0xd8, 0xff, 0xe0])   // JPEG SOI marker
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = CapturedPhoto(imageData: payload, capturedAt: timestamp)
        #expect(photo.imageData == payload)
        #expect(photo.capturedAt == timestamp)
    }

    @Test("CapturedPhoto defaults capturedAt to now")
    func capturedPhotoDefaultDate() {
        let before = Date()
        let photo = CapturedPhoto(imageData: Data())
        let after = Date()
        #expect(photo.capturedAt >= before)
        #expect(photo.capturedAt <= after)
    }
}
