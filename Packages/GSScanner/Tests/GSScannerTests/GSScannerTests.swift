#if os(iOS)
import Testing
@testable import GSScanner

@Suite("GSScanner")
struct GSScannerTests {
    @Test("All symbologies are present")
    func symbologyList() {
        let all = GSBarcodeSymbology.allCases
        #expect(all.contains(.ean13))
        #expect(all.contains(.ean8))
        #expect(all.contains(.qr))
    }
}
#else
// Stub on non-iOS hosts so `swift test` succeeds with zero tests.
import Testing

@Suite("GSScanner (skipped on macOS host)")
struct GSScannerHostTests {}
#endif
