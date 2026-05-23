import SwiftUI
import GSAPIClient
import GSCamera
import GSCore

/// "Photo" page in the Settings menu. Houses the capture-behaviour
/// knobs: starting mode persistence, locked white balance, colour
/// grading profile, and the ICC colour space tagged onto JPEG.
struct SettingsPhotoView: View {
    @Bindable var settings: DevSettings

    var body: some View {
        Form {
            captureBehaviourSection
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
        } footer: {
            Text("Photo uses the wide-angle camera with the white balance, colour profile and colour space chosen above. Detail switches to the ultra-wide camera (focuses down to ~2 cm) but keeps the same look — for close-up product shots. OCR also uses the ultra-wide but with auto white balance and no colour processing; it's the only mode where Vision OCR + pictogram detection run after capture, and its JPEGs keep the sensor's native colour profile. Focal length, white-balance mode, ISO and lens model are written into the JPEG EXIF metadata for all modes.")
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
}
