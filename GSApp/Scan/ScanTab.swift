import SwiftUI
import GSAPIClient

/// Root of the Scan tab — a Wallet-style menu with three entries. Tapping
/// an entry pushes the corresponding flow onto the navigation stack.
struct ScanTab: View {
    let settings: DevSettings

    var body: some View {
        NavigationStack {
            ScanMenuView(settings: settings)
                .navigationTitle("Scan")
        }
    }
}

struct ScanMenuView: View {
    let settings: DevSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ScanMenuCard(
                    title: "Scan products",
                    subtitle: "Look up a reference and update its stock item status.",
                    systemImage: "barcode.viewfinder",
                    gradient: [.blue, .cyan],
                    destination: AnyView(ScanProductFlow(settings: settings))
                )

                ScanMenuCard(
                    title: "Batches",
                    subtitle: "Browse boxes and shelves. Scan a batch barcode to open it.",
                    systemImage: "shippingbox.fill",
                    gradient: [.orange, .yellow],
                    destination: AnyView(BatchListView(settings: settings))
                )

                ScanMenuCard(
                    title: "Register products",
                    subtitle: "Scan an item to add it to a batch in your stock.",
                    systemImage: "plus.rectangle.on.rectangle",
                    gradient: [.green, .mint],
                    destination: AnyView(RegisterProductFlow(settings: settings))
                )
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct ScanMenuCard: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let systemImage: String
    let gradient: [Color]
    let destination: AnyView

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
