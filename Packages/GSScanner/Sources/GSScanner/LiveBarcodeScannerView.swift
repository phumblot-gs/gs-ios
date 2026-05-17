#if os(iOS)
import SwiftUI

/// SwiftUI host for `LiveBarcodeScannerController`. Hand it an `onScan`
/// closure; it gets called every time a centered barcode is detected,
/// throttled by the controller's cooldown.
public struct LiveBarcodeScannerView: UIViewControllerRepresentable {
    public typealias UIViewControllerType = LiveBarcodeScannerController

    private let cooldownSeconds: TimeInterval
    private let onScan: @MainActor (ScannedCode) -> Void

    public init(
        cooldownSeconds: TimeInterval = 2.0,
        onScan: @escaping @MainActor (ScannedCode) -> Void
    ) {
        self.cooldownSeconds = cooldownSeconds
        self.onScan = onScan
    }

    public func makeUIViewController(context: Context) -> LiveBarcodeScannerController {
        let controller = LiveBarcodeScannerController()
        controller.cooldownSeconds = cooldownSeconds
        controller.onScan = onScan
        return controller
    }

    public func updateUIViewController(_ uiViewController: LiveBarcodeScannerController, context: Context) {
        uiViewController.cooldownSeconds = cooldownSeconds
        uiViewController.onScan = onScan
    }
}
#endif
