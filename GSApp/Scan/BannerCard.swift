import SwiftUI

/// Translucent card surfaced below the live-scanner reticle to
/// report the outcome of a barcode scan. Used by both
/// `ScanProductFlow` (looking up a reference to view details) and
/// `RegisterProductFlow` (looking up a reference to add to a batch).
struct BannerCard: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let accent: Color
    var showProgress: Bool = false
    var chevron: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            if showProgress {
                ProgressView().controlSize(.small)
            } else if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.4), lineWidth: 1)
        )
    }
}
