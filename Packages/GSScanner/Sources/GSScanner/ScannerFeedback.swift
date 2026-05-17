#if os(iOS)
import Foundation
import UIKit

/// Centralised haptic + audio cues for the scanner flow.
///
/// **Current state**: haptic-only. The first attempt used
/// `AudioServicesPlaySystemSoundID` from `AudioToolbox`, but the iOS 26 SDK
/// doesn't expose those C symbols to Swift any more (neither
/// `import AudioToolbox` nor the `.AudioServices` submodule put them in
/// scope under xcodebuild). The plan is to bundle short `.caf` cues in the
/// package and play them with `AVAudioPlayer` once we have the assets —
/// see `didDetectCode`, `didFindReference`, `didFailLookup` below.
@MainActor
public final class ScannerFeedback {

    private let detectionImpact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    public init() {
        // Pre-warm so the first event is snappy.
        detectionImpact.prepare()
        notification.prepare()
    }

    /// Fired the moment a centered barcode is accepted. A quick medium
    /// impact is enough on its own; the lookup result follows immediately.
    public func didDetectCode() {
        detectionImpact.impactOccurred()
        detectionImpact.prepare()
        // TODO: bundle and play a short "tick" .caf when assets land.
    }

    /// The lookup returned at least one reference.
    public func didFindReference() {
        notification.notificationOccurred(.success)
        notification.prepare()
        // TODO: bundle and play a short "ok" .caf when assets land.
    }

    /// The lookup ran but came back empty (unknown EAN) or failed.
    public func didFailLookup(reason: FailureReason) {
        switch reason {
        case .notFound:
            notification.notificationOccurred(.warning)
        case .transport, .other:
            notification.notificationOccurred(.error)
        }
        notification.prepare()
        // TODO: bundle and play a short "error" .caf when assets land.
    }

    public enum FailureReason: Sendable {
        case notFound      // Server returned 200 with empty array
        case transport     // Network / HTTP error
        case other
    }
}
#endif
