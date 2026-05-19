#if os(iOS)
import SwiftUI
import SwiftData
import GSAPIClient

/// Step 2 of the capture flow: pick the category the captured object
/// belongs to, or create a brand-new one. Existing categories are sorted
/// by image-embedding distance to the captured object; the closest match
/// is presented as the primary suggestion.
struct MeasureCategoryPickerView: View {
    let settings: DevSettings
    let frame: CapturedFrame
    let includedSubjects: [DetectedSubject]
    /// Called once a category is committed (existing pick OR newly
    /// created). Phase 4 hooks into this to start the point-placement
    /// flow.
    let onSelected: @MainActor (MeasureCategory, CapturedFrame) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MeasureCategory.createdAt, order: .reverse)
    private var allCategories: [MeasureCategory]

    @State private var newEmbedding: Data?
    @State private var ranking: [Ranked] = []
    @State private var isRanking = true
    @State private var showCreate = false

    private struct Ranked: Identifiable {
        let id = UUID()
        let category: MeasureCategory
        let distance: Float?  // nil when the category has no stored embedding
    }

    var body: some View {
        List {
            previewSection
            if !allCategories.isEmpty {
                suggestionsSection
            }
            createSection
        }
        .navigationTitle("Choose a category")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await computeRanking()
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                MeasureCategoryCreateView(
                    settings: settings,
                    capturedFrame: frame,
                    newEmbedding: newEmbedding
                ) { created in
                    showCreate = false
                    onSelected(created, frame)
                }
            }
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            Image(uiImage: frame.image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .cornerRadius(12)
            HStack {
                Label("\(includedSubjects.count) object(s) kept", systemImage: "person.fill.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if isRanking {
                HStack { ProgressView(); Text("Looking for similar objects…") }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ranking) { row in
                    Button {
                        onSelected(row.category, frame)
                    } label: {
                        suggestionRow(row)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Sorted by visual similarity. The closer to the top, the better the match.")
        }
    }

    private var createSection: some View {
        Section {
            Button {
                showCreate = true
            } label: {
                Label("Create a new category", systemImage: "plus.circle.fill")
            }
        } footer: {
            Text("If none of the suggestions fit, define a new category using this capture as the example.")
        }
    }

    // MARK: - Row UI

    @ViewBuilder
    private func suggestionRow(_ row: Ranked) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: row.category)
                .frame(width: 56, height: 56)
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.category.name).font(.headline)
                if let distance = row.distance {
                    Text(confidenceLabel(for: distance))
                        .font(.caption)
                        .foregroundStyle(distance < 5 ? .green : (distance < 15 ? .orange : .secondary))
                } else {
                    Text("No reference image yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(for category: MeasureCategory) -> some View {
        if let data = category.exampleImageData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: "tag").foregroundStyle(.secondary)
            }
        }
    }

    private func confidenceLabel(for distance: Float) -> String {
        // VNGenerateImageFeaturePrint distances range roughly 0...30.
        // Empirically <5 is very close, 5-15 is plausible, >15 is far.
        switch distance {
        case ..<5: return "Strong match"
        case ..<15: return "Plausible match"
        default: return "Distant — likely different"
        }
    }

    // MARK: - Compute

    private func computeRanking() async {
        isRanking = true
        defer { isRanking = false }
        do {
            let mask = includedSubjects.first?.mask
            let embedding = try await ImageEmbeddingService.embed(frame.image, maskedBy: mask)
            newEmbedding = embedding
            var rows: [Ranked] = allCategories.map { cat in
                let dist = cat.imageEmbedding.flatMap { ImageEmbeddingService.distance(embedding, $0) }
                return Ranked(category: cat, distance: dist)
            }
            // Categories with a measurable distance go first, sorted asc;
            // anything without an embedding lands at the bottom.
            rows.sort { lhs, rhs in
                switch (lhs.distance, rhs.distance) {
                case (let l?, let r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.category.createdAt > rhs.category.createdAt
                }
            }
            ranking = rows
        } catch {
            // No embedding — still list categories so the user can pick
            // manually.
            ranking = allCategories.map { Ranked(category: $0, distance: nil) }
        }
    }
}
#endif
