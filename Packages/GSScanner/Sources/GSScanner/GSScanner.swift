#if os(iOS)
import SwiftUI
import VisionKit
import GSCore

/// The set of barcode symbologies Grand Shooting scans for.
public enum GSBarcodeSymbology: Sendable, Hashable, CaseIterable {
    case ean13
    case ean8
    case qr

    var visionKitType: DataScannerViewController.RecognizedDataType {
        switch self {
        case .ean13: return .barcode(symbologies: [.ean13])
        case .ean8:  return .barcode(symbologies: [.ean8])
        case .qr:    return .barcode(symbologies: [.qr])
        }
    }
}

/// SwiftUI view that wraps `VisionKit.DataScannerViewController` and calls
/// `onScan` with the recognised payload string. Hardware-gated; verify
/// `DataScannerViewController.isSupported` and `.isAvailable` from the caller.
public struct BarcodeScannerView: UIViewControllerRepresentable {
    private let symbologies: [GSBarcodeSymbology]
    private let onScan: @MainActor (String) -> Void

    public init(
        symbologies: [GSBarcodeSymbology] = [.ean13, .ean8, .qr],
        onScan: @escaping @MainActor (String) -> Void
    ) {
        self.symbologies = symbologies
        self.onScan = onScan
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    public func makeUIViewController(context: Context) -> DataScannerViewController {
        let types: Set<DataScannerViewController.RecognizedDataType> = [
            .barcode(symbologies: [.ean13, .ean8, .qr])
        ]
        let controller = DataScannerViewController(
            recognizedDataTypes: types,
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    public func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        // no-op
    }

    @MainActor
    public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: @MainActor (String) -> Void
        private let logger = GSLogger(category: "GSScanner")

        init(onScan: @escaping @MainActor (String) -> Void) {
            self.onScan = onScan
        }

        public func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            handle(item)
        }

        public func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            if let first = addedItems.first {
                handle(first)
            }
        }

        private func handle(_ item: RecognizedItem) {
            switch item {
            case .barcode(let barcode):
                if let payload = barcode.payloadStringValue {
                    logger.info("Scanned barcode: \(payload)")
                    onScan(payload)
                }
            default:
                break
            }
        }
    }
}
#else
// Non-iOS platforms (macOS host build for `swift test`): no UI surface.
// The iOS-only types above are unavailable; the xcodebuild step in CI
// validates the real iOS build separately.
public enum GSScannerUnavailableOnThisPlatform {}
#endif
