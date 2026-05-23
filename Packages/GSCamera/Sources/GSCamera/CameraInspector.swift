import Foundation
@preconcurrency import AVFoundation

#if os(iOS)

/// Read-only helpers that describe the host iPhone's camera
/// hardware in 35mm-equivalent terms. Used by:
///   - `CameraSessionController` to pick the best physical lens
///     for a target focal length and compute the digital zoom
///     factor needed to reach it.
///   - the Settings UI to render which lens + zoom each per-mode
///     focal choice would resolve to on the current device, and
///     warn when the digital crop is too aggressive (> 4×).
public enum CameraInspector {

    /// Describes one physical back camera. `nativeFocalLength35mm`
    /// is computed from `activeFormat.videoFieldOfView` so we
    /// don't need a per-iPhone-model hardcoded table — works on
    /// any back camera Apple ships now or in the future.
    public struct LensInfo: Sendable, Hashable, Identifiable {
        public let deviceTypeRawValue: String
        public let nativeFocalLength35mm: Int
        public let displayName: String
        public var id: String { deviceTypeRawValue }
    }

    /// The lens the session would pick for a given target focal
    /// + the digital zoom factor needed to reach it.
    public struct LensChoice: Sendable, Hashable {
        public let lens: LensInfo
        public let zoomFactor: Double
        public let isTargetUnreachable: Bool

        /// We consider digital zoom beyond 4× "heavy" — the
        /// resolution drop is visible and the noise starts to
        /// show. Anything below that is fine.
        public var requiresHeavyDigitalZoom: Bool {
            zoomFactor > 4.0
        }
    }

    /// Enumerates every physical back camera the device exposes,
    /// in ascending native-focal order (ultra-wide → wide → tele).
    public static func availableBackLenses() -> [LensInfo] {
        let candidates: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInUltraWideCamera, "Ultra-wide"),
            (.builtInWideAngleCamera, "Wide"),
            (.builtInTelephotoCamera, "Telephoto")
        ]
        return candidates.compactMap { type, name in
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { return nil }
            let focal = focalLength35mm(forFOV: Double(device.activeFormat.videoFieldOfView))
            return LensInfo(
                deviceTypeRawValue: type.rawValue,
                nativeFocalLength35mm: focal,
                displayName: name
            )
        }
        .sorted { $0.nativeFocalLength35mm < $1.nativeFocalLength35mm }
    }

    /// Picks the lens whose native focal is ≤ target and closest
    /// to it, then computes the digital zoom needed. When the
    /// target is shorter than every available lens (e.g. user
    /// asks for 13 mm on a non-Pro iPhone without ultra-wide), we
    /// fall back to the widest lens at zoom = 1× and mark the
    /// choice as unreachable so callers can warn the user.
    public static func bestLens(
        forTargetFocal35mm target: Int,
        in lenses: [LensInfo]
    ) -> LensChoice? {
        guard !lenses.isEmpty else { return nil }
        if let chosen = lenses.last(where: { $0.nativeFocalLength35mm <= target }) {
            let zoom = max(Double(target) / Double(chosen.nativeFocalLength35mm), 1.0)
            return LensChoice(lens: chosen, zoomFactor: zoom, isTargetUnreachable: false)
        }
        // Target is shorter than every available lens. Use the
        // widest and clamp zoom to 1.0 — we can't go below a
        // single lens's native focal.
        guard let widest = lenses.first else { return nil }
        return LensChoice(lens: widest, zoomFactor: 1.0, isTargetUnreachable: true)
    }

    /// Converts horizontal field-of-view (degrees) to the
    /// 35mm-equivalent focal length using the standard formula:
    /// `f = (sensor_width / 2) / tan(FOV / 2)` with `sensor_width`
    /// = 36 mm (full-frame width). Result rounded to the nearest
    /// integer millimetre.
    public static func focalLength35mm(forFOV degreesHorizontal: Double) -> Int {
        guard degreesHorizontal > 0 else { return 0 }
        let halfFOVRad = (degreesHorizontal / 2.0) * .pi / 180.0
        let denom = tan(halfFOVRad)
        guard denom > 0 else { return 0 }
        return Int((18.0 / denom).rounded())
    }
}

#endif
