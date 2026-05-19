import SwiftUI
import SwiftData
import GSAPIClient
import GSCore

/// Root of the "Mesures" tab. LiDAR-only feature gated through
/// `GSDeviceSupport.hasLiDAR` — non-LiDAR devices see a friendly
/// explanation instead of broken UI.
struct MeasureTab: View {
    let settings: DevSettings

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                if GSDeviceSupport.hasLiDAR {
                    MeasureCategoryListView(settings: settings)
                } else {
                    notSupportedView
                }
                #else
                notSupportedView
                #endif
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

#if os(iOS)
/// Categories list with a "+" CTA opening the capture flow. Phase 3
/// will turn the destination into a real category picker; for now it
/// stops after capture.
struct MeasureCategoryListView: View {
    let settings: DevSettings

    @Query(sort: \MeasureCategory.createdAt, order: .reverse) private var categories: [MeasureCategory]
    @State private var showCapture = false

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
                    showCapture = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            NavigationStack {
                MeasureCaptureView(settings: settings) { _, _ in
                    // Phase 3 will route into category selection here.
                    showCapture = false
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showCapture = false }
                    }
                }
            }
        }
    }
}
#endif
