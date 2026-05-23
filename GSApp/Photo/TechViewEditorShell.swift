import SwiftUI
import UIKit

/// Shared scaffold for the two "edit a single annotation"
/// sheets we expose from the capture screen — the OCR text editor
/// and the pictogram label picker. Both want the same visual
/// rhythm (NavigationStack, inline title, Cancel + primary action
/// pair, keyboard accessory with a "Hide keyboard" button,
/// medium/large presentation detents) so the user only ever
/// learns one pattern. Specialised content sits inside `content`;
/// the primary action label / behaviour is configurable per sheet.
struct TechViewEditorShell<Content: View, Primary: View>: View {
    let title: String
    let onCancel: () -> Void
    let dismissKeyboard: () -> Void
    @ViewBuilder var primaryAction: () -> Primary
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: onCancel)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        primaryAction()
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(action: dismissKeyboard) {
                            Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                                .labelStyle(.titleAndIcon)
                                .font(.body.weight(.medium))
                        }
                    }
                }
        }
    }
}

/// Single source of truth for the category picker styling used
/// inside both sheets and on the labelled picto row. Kept in this
/// file so it travels with the shell.
struct TechViewCategoryControl: View {
    @Binding var selection: TechViewCategory?
    var placeholder: String = "Choose category"

    var body: some View {
        Menu {
            ForEach(TechViewCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    Label(category.displayName, systemImage: category.symbolName)
                }
            }
        } label: {
            if let selection {
                Label(selection.displayName, systemImage: selection.symbolName)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.22), in: Capsule())
                    .foregroundStyle(.white)
            } else {
                Label(placeholder, systemImage: "tag")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.22), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Red, full-width Delete button used by both the labelled picto
/// row and the OCR editor sheet.
struct TechViewDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Delete", systemImage: "trash")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }
}

/// Cross-platform helper that resigns first responder. Used as a
/// fallback in places where `@FocusState` can't reach every input
/// (e.g. the search bar of `.searchable` inside `PictoLabelPicker`).
@MainActor
func resignAllResponders() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}

/// Crops a source image to a Vision-normalised bounding box, with
/// an extra padding margin so the user sees a little context
/// around the text or icon. Returns nil when the math degenerates
/// (zero-size crop, missing cgImage). Preserves the source image's
/// EXIF orientation so the preview matches what the user saw on
/// the live camera.
func techViewsCrop(
    of image: UIImage,
    box: CGRect,
    paddingFractionX: CGFloat = 0.15,
    paddingFractionY: CGFloat = 0.4
) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let padded = box
        .insetBy(dx: -box.width * paddingFractionX, dy: -box.height * paddingFractionY)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    let imageWidth = CGFloat(cgImage.width)
    let imageHeight = CGFloat(cgImage.height)
    let pixelRect = CGRect(
        x: padded.minX * imageWidth,
        y: (1 - padded.maxY) * imageHeight,
        width: padded.width * imageWidth,
        height: padded.height * imageHeight
    ).integral
    guard pixelRect.width > 0, pixelRect.height > 0,
          let cropped = cgImage.cropping(to: pixelRect) else { return nil }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}
