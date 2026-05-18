#if os(iOS)
import SwiftUI

/// SwiftUI host for `LiveBarcodeScannerController`. Hand it an `onScan`
/// closure; it gets called the first time a centered barcode is detected,
/// and only re-fires when the centered payload changes (i.e. the camera
/// moves to a different code, or returns to a code after losing sight of
/// every code for `resetDelaySeconds`).
public struct LiveBarcodeScannerView: UIViewControllerRepresentable {
    public typealias UIViewControllerType = LiveBarcodeScannerController

    private let resetDelaySeconds: TimeInterval
    private let onScan: @MainActor (ScannedCode) -> Void

    public init(
        resetDelaySeconds: TimeInterval = 0.5,
        onScan: @escaping @MainActor (ScannedCode) -> Void
    ) {
        self.resetDelaySeconds = resetDelaySeconds
        self.onScan = onScan
    }

    public func makeUIViewController(context: Context) -> LiveBarcodeScannerController {
        let controller = LiveBarcodeScannerController()
        controller.resetDelaySeconds = resetDelaySeconds
        controller.onScan = onScan
        return controller
    }

    public func updateUIViewController(_ uiViewController: LiveBarcodeScannerController, context: Context) {
        uiViewController.resetDelaySeconds = resetDelaySeconds
        uiViewController.onScan = onScan
    }
}
#endif
