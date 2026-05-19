import SwiftUI
import SwiftData
import GSAPIClient
import GSCore

/// Root of the "Mesures" tab (formerly "LiDAR"). LiDAR-only feature so
/// we gate the entry behind `GSDeviceSupport.hasLiDAR` — on devices
/// without LiDAR we show a friendly explanation instead of a broken UI.
struct MeasureTab: View {
    let settings: DevSettings

    var body: some View {
        NavigationStack {
            Group {
                if GSDeviceSupport.hasLiDAR {
                    MeasureCategoryListView(settings: settings)
                } else {
                    notSupportedView
                }
            }
            .navigationTitle("Measures")
        }
    }

    private var notSupportedView: some View {
        ContentUnavailableView {
            Label("Measures need LiDAR", systemImage: "cube.transparent.fill")
        } description: {
            Text("Measure works only on devices with a LiDAR scanner — iPhone Pro / Pro Max and iPad Pro.")
        }
    }
}

/// Placeholder list — phases 2-5 fill this in. For now it just lists the
/// categories already in SwiftData so we can verify persistence works.
struct MeasureCategoryListView: View {
    let settings: DevSettings

    @Query(sort: \MeasureCategory.createdAt, order: .reverse) private var categories: [MeasureCategory]

    var body: some View {
        Group {
            if categories.isEmpty {
                ContentUnavailableView {
                    Label("No categories yet", systemImage: "ruler")
                } description: {
                    Text("Start a measurement to capture an object. The first capture creates a category; subsequent ones are recognised automatically.")
                }
            } else {
                List(categories) { category in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name).font(.headline)
                        Text("\(category.templates.count) measurements")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Phase 2 lands the capture flow here.
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(true) // re-enabled in Phase 2
            }
        }
    }
}
