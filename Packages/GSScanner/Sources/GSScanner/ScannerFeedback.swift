#if os(iOS)
import Foundation
import UIKit
import AVFoundation
import AudioToolbox.AudioServices

/// Centralised haptic + system-audio cues for the scanner flow.
///
/// We use AudioServicesPlaySystemSoundID with iOS's built-in tones — they're
/// instant, free, and recognisable. If we later want a more distinctive
/// brand sound, swap these out for bundled .caf assets.
@MainActor
public final class ScannerFeedback {

    // System sound IDs — see https://github.com/TUNER88/iOSSystemSoundsLibrary
    // 1057 = "Tink" (positive ack), 1073 = "BeepBeep" (negative).
    private static let detectionTickID: SystemSoundID = 1306   // soft "begin recording"
    private static let successBeepID: SystemSoundID = 1057
    private static let errorBeepID: SystemSoundID = 1073

    private let detectionImpact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    public init() {
        // Pre-warm the generators so the first event is snappy.
        detectionImpact.prepare()
        notification.prepare()
    }

    /// Fires the moment a barcode is detected in frame and accepted as the
    /// "centered candidate". Quick tactile cue with no audio so we don't
    /// step on the success/error beep that follows the API call.
    public func didDetectCode() {
        detectionImpact.impactOccurred()
        AudioServicesPlaySystemSoundID(Self.detectionTickID)
        // Re-prepare for the next event.
        detectionImpact.prepare()
    }

    /// The lookup returned a reference.
    public func didFindReference() {
        notification.notificationOccurred(.success)
        AudioServicesPlaySystemSoundID(Self.successBeepID)
        notification.prepare()
    }

    /// The lookup ran but came back empty (unknown EAN), OR failed for
    /// transport reasons. Pick the appropriate variant from the call site.
    public func didFailLookup(reason: FailureReason) {
        switch reason {
        case .notFound:
            notification.notificationOccurred(.warning)
        case .transport, .other:
            notification.notificationOccurred(.error)
        }
        AudioServicesPlaySystemSoundID(Self.errorBeepID)
        notification.prepare()
    }

    public enum FailureReason: Sendable {
        case notFound      // Server returned 200 with empty array
        case transport     // Network / HTTP error
        case other
    }
}
#endif
