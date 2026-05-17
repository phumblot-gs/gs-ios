#if os(iOS)
import Foundation
import AVFoundation
#if canImport(ARKit)
import ARKit
#endif

/// Runtime capability detection for the current device.
///
/// Preferred over a hardcoded model list because Apple keeps shipping
/// new chassis combinations and an explicit allow-list ages badly.
/// Use this to gate features that need specific hardware (LiDAR for
/// scene reconstruction, triple-camera for macro autofocus at < 10 cm,
/// Apple Intelligence for on-device foundation models, etc.).
///
/// For human-readable docs, see `docs/SUPPORTED-DEVICES.md` in the repo.
public enum GSDeviceSupport {

    // MARK: - Cameras

    public static var hasTripleCamera: Bool {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) != nil
    }

    public static var hasDualWideCamera: Bool {
        AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) != nil
    }

    /// True if the back camera supports a minimum focus distance suitable
    /// for very close labels (< 10 cm) — i.e. has a macro-capable lens or
    /// triple-camera that auto-switches to ultra-wide at short range.
    public static var supportsCloseFocusForBarcodes: Bool {
        hasTripleCamera || hasDualWideCamera
    }

    /// Best back camera available, in preference order.
    /// Triple → DualWide → DualBack → BuiltIn ultra-wide → BuiltIn wide.
    public static func preferredBackCamera() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        for type in preferred {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    // MARK: - LiDAR

    public static var hasLiDAR: Bool {
        #if canImport(ARKit)
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        #else
        return false
        #endif
    }

    // MARK: - GPU / on-device AI

    /// Crude proxy for "this device runs the heaviest pipelines comfortably."
    /// True on the A17 Pro + (iPhone 15 Pro / 16 / 17 series), iPads M-series.
    public static var supportsHeavyOnDeviceML: Bool {
        ProcessInfo.processInfo.physicalMemory >= 7_000_000_000  // ≥ 7 GB RAM
    }

    // MARK: - Combined report

    public struct Capabilities: Sendable, Hashable {
        public let hasLiDAR: Bool
        public let hasTripleCamera: Bool
        public let supportsCloseFocusForBarcodes: Bool
        public let supportsHeavyOnDeviceML: Bool
        public let physicalMemoryGB: Double
    }

    public static func current() -> Capabilities {
        Capabilities(
            hasLiDAR: hasLiDAR,
            hasTripleCamera: hasTripleCamera,
            supportsCloseFocusForBarcodes: supportsCloseFocusForBarcodes,
            supportsHeavyOnDeviceML: supportsHeavyOnDeviceML,
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        )
    }
}
#endif
