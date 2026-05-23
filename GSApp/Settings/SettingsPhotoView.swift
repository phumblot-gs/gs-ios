import SwiftUI
import GSAPIClient
import GSCamera
import GSCore

/// "Photo" page in the Settings menu. Houses the capture-behaviour
/// knobs: starting mode persistence, locked white balance, colour
/// grading profile, ICC colour space, and the per-mode focal
/// lengths (35mm-equivalent) the session should target.
struct SettingsPhotoView: View {
    @Bindable var settings: DevSettings

    /// Photographer-friendly focal stops. Includes 13 mm for the
    /// ultra-wide-native OCR sweet spot.
    private let focalChoices: [Int] = [13, 24, 28, 35, 50, 70, 85, 100, 120, 150, 200]

    private var availableLenses: [CameraInspector.LensInfo] {
        CameraInspector.availableBackLenses()
    }

    var body: some View {
        Form {
            captureBehaviourSection
            focalLengthsSection
        }
        .navigationTitle("Photo")
    }

    private var captureBehaviourSection: some View {
        Section {
            Picker("Starting mode", selection: capturePersistenceBinding) {
                Text("Always Presentation").tag(DevSettings.CapturePersistence.alwaysPresentation)
                Text("Remember last").tag(DevSettings.CapturePersistence.rememberLast)
            }

            Picker("White balance (Presentation)", selection: whiteBalanceBinding) {
                ForEach(PresentationWhiteBalance.allCases) { wb in
                    Text(wb.displayName).tag(wb)
                }
            }

            Picker("Colour profile (Presentation)", selection: colorProfileBinding) {
                ForEach(PresentationColorProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            if currentColorProfile != .none {
                Text(currentColorProfile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Colour space (JPEG profile)", selection: colorSpaceBinding) {
                ForEach(PresentationColorSpace.allCases) { space in
                    Text(space.displayName).tag(space)
                }
            }
            Text(currentColorSpace.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Capture behaviour")
        }
    }

    // MARK: - Bindings

    private var capturePersistenceBinding: Binding<DevSettings.CapturePersistence> {
        Binding(
            get: { settings.techViewsCapturePersistence },
            set: { settings.techViewsCapturePersistence = $0 }
        )
    }

    private var whiteBalanceBinding: Binding<PresentationWhiteBalance> {
        Binding(
            get: {
                PresentationWhiteBalance(rawValue: settings.techViewsWhiteBalanceRaw) ?? .auto
            },
            set: { settings.techViewsWhiteBalanceRaw = $0.rawValue }
        )
    }

    private var colorProfileBinding: Binding<PresentationColorProfile> {
        Binding(
            get: {
                PresentationColorProfile(rawValue: settings.techViewsColorProfileRaw) ?? .none
            },
            set: { settings.techViewsColorProfileRaw = $0.rawValue }
        )
    }

    private var currentColorProfile: PresentationColorProfile {
        PresentationColorProfile(rawValue: settings.techViewsColorProfileRaw) ?? .none
    }

    private var colorSpaceBinding: Binding<PresentationColorSpace> {
        Binding(
            get: {
                PresentationColorSpace(rawValue: settings.techViewsColorSpaceRaw) ?? .sRGB
            },
            set: { settings.techViewsColorSpaceRaw = $0.rawValue }
        )
    }

    private var currentColorSpace: PresentationColorSpace {
        PresentationColorSpace(rawValue: settings.techViewsColorSpaceRaw) ?? .sRGB
    }

    // MARK: - Focal lengths

    private var focalLengthsSection: some View {
        Section {
            focalRow(
                label: "Photo",
                value: Binding(
                    get: { settings.techViewsPresentationFocal },
                    set: { settings.techViewsPresentationFocal = $0 }
                )
            )
            focalRow(
                label: "Detail",
                value: Binding(
                    get: { settings.techViewsDetailFocal },
                    set: { settings.techViewsDetailFocal = $0 }
                )
            )
            focalRow(
                label: "OCR",
                value: Binding(
                    get: { settings.techViewsOCRFocal },
                    set: { settings.techViewsOCRFocal = $0 }
                )
            )
        } header: {
            Text("Focal length (35mm equivalent)")
        } footer: {
            availableLensesFooter
        }
    }

    @ViewBuilder
    private func focalRow(label: LocalizedStringKey, value: Binding<Int>) -> some View {
        Picker(label, selection: value) {
            ForEach(focalChoices, id: \.self) { mm in
                Text("\(mm) mm").tag(mm)
            }
        }
        if let choice = CameraInspector.bestLens(
            forTargetFocal35mm: value.wrappedValue,
            in: availableLenses
        ) {
            lensResolutionLine(choice: choice)
        }
    }

    @ViewBuilder
    private func lensResolutionLine(choice: CameraInspector.LensChoice) -> some View {
        let zoomString = String(format: "%.2f×", choice.zoomFactor)
        let lensName = choice.lens.displayName
        let nativeMM = choice.lens.nativeFocalLength35mm
        if choice.isTargetUnreachable {
            Label(
                "Cannot reach this focal — falls back to \(lensName) at \(nativeMM) mm.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
        } else if choice.requiresHeavyDigitalZoom {
            Label(
                "Uses \(lensName) (\(nativeMM) mm) × \(zoomString) — heavy digital crop, quality reduced.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
        } else {
            Text("Uses \(lensName) (\(nativeMM) mm) × \(zoomString).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var availableLensesFooter: some View {
        let summary = availableLenses
            .map { "\($0.displayName) ≈ \($0.nativeFocalLength35mm) mm" }
            .joined(separator: " · ")
        return Text(
            summary.isEmpty
            ? "No back camera detected."
            : "Detected back lenses: \(summary). The app picks the closest physical lens ≤ your target, then applies a digital zoom to reach it."
        )
    }
}
