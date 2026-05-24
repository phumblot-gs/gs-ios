import SwiftUI
import GSCamera

/// UI sugar local to GSApp so `GSCamera` can stay independent of
/// SwiftUI / SF Symbols. Drives the three-way toggle button on the
/// capture screen.
extension CaptureMode {
    /// Cycle order: photo → detail → ocr → photo. Driven by the
    /// shutter-adjacent toggle button.
    var nextInRotation: CaptureMode {
        switch self {
        case .presentation: .detail
        case .detail: .ocr
        case .ocr: .presentation
        // `.measure` is locked, never reached by the rotation
        // toggle. Falling through to `.presentation` keeps the
        // switch exhaustive.
        case .measure: .presentation
        }
    }

    var iconName: String {
        switch self {
        case .presentation: "camera"
        case .detail: "camera.macro"
        case .ocr: "text.viewfinder"
        case .measure: "ruler"
        }
    }

    var shortLabel: String {
        switch self {
        case .presentation: "Photo"
        case .detail: "Detail"
        case .ocr: "OCR"
        case .measure: "Measure"
        }
    }

    /// Background colour for the toggle pill. OCR uses the accent
    /// tint to signal "Vision is on". Detail uses a muted accent so
    /// the user notices it's a sibling of OCR but not the OCR one.
    var toggleBackground: Color {
        switch self {
        case .presentation: Color.black.opacity(0.5)
        case .detail: Color.accentColor.opacity(0.45)
        case .ocr: Color.accentColor.opacity(0.85)
        case .measure: Color.black.opacity(0.5)
        }
    }
}
