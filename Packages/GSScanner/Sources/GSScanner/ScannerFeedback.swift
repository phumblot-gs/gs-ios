#if os(iOS)
import Foundation
import UIKit
import AudioToolbox

/// Centralised haptic + audio cues for the scanner flow. Every
/// public hook fires BOTH a haptic and a short system sound:
/// users get tactile feedback in any pocket / glove condition,
/// plus an audible cue that survives a phone-down workflow.
///
/// Sound choices are intentional:
///   - `didDetectCode`: 1104 — short "tock", neutral.
///   - `didFindReference`: 1057 — positive chime, confirmation.
///   - `didFailLookup(.notFound)`: 1073 — descending warning.
///   - `didFailLookup(.transport / .other)`: 1107 — harsher buzz.
/// The IDs are stable across iOS releases; system sounds are
/// preferred over bundled assets because they respect the OS
/// silent switch + per-app volume settings.
@MainActor
public final class ScannerFeedback {

    private let detectionImpact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    public init() {
        // Pre-warm so the first event is snappy.
        detectionImpact.prepare()
        notification.prepare()
    }

    /// Fired the moment a centered barcode is accepted. Quick
    /// medium impact + short tock — the result cue follows
    /// immediately, so this one stays subtle.
    public func didDetectCode() {
        detectionImpact.impactOccurred()
        detectionImpact.prepare()
        AudioServicesPlaySystemSound(1104)
    }

    /// The lookup returned at least one reference / the action
    /// succeeded. Success haptic + positive chime.
    public func didFindReference() {
        notification.notificationOccurred(.success)
        notification.prepare()
        AudioServicesPlaySystemSound(1057)
    }

    /// The lookup ran but came back empty (unknown EAN) or the
    /// action failed. Warning haptic for `.notFound` (something
    /// was found, just not what the user wanted), error haptic
    /// for network / unexpected failures.
    public func didFailLookup(reason: FailureReason) {
        switch reason {
        case .notFound:
            notification.notificationOccurred(.warning)
            AudioServicesPlaySystemSound(1073)
        case .transport, .other:
            notification.notificationOccurred(.error)
            AudioServicesPlaySystemSound(1107)
        }
        notification.prepare()
    }

    public enum FailureReason: Sendable {
        case notFound      // Server returned 200 with empty array
        case transport     // Network / HTTP error
        case other
    }
}
#endif
