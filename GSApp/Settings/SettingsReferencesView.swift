import SwiftUI
import GSAPIClient

/// "References" page in the Settings menu. Lets the user pick which
/// reference attributes appear in the reference / stock-item info block
/// and in what order. Includes the active account's custom catalog
/// columns (`prefs.catalog_extra_cols`).
struct SettingsReferencesView: View {
    @Bindable var settings: DevSettings

    @State private var entries: [ReferenceAttributeConfigEntry] = []
    @State private var labelsByID: [String: String] = [:]

    var body: some View {
        List {
            Section {
                ForEach($entries, id: \.id) { $entry in
                    Button {
                        entry.visible.toggle()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.visible ? "eye" : "eye.slash")
                                .foregroundStyle(entry.visible ? Color.accentColor : .secondary)
                                .frame(width: 22)
                            Text(verbatim: labelsByID[entry.id] ?? entry.id)
                                .foregroundStyle(entry.visible ? .primary : .secondary)
                            Spacer()
                        }
                    }
                    .tint(.primary)
                }
                .onMove { from, to in
                    entries.move(fromOffsets: from, toOffset: to)
                }
            } header: {
                Text("Displayed attributes")
            } footer: {
                Text("Tap to show or hide an attribute; drag to reorder. This drives the reference and stock-item info block. The reference code is always shown as the header.")
            }
        }
        .navigationTitle("References")
        .toolbar { EditButton() }
        .onAppear { rebuild() }
        .onChange(of: entries) { _, _ in persist() }
        // Re-sync if the active account (and thus its extra columns)
        // changes while this screen is open.
        .onChange(of: settings.activeAccountID) { _, _ in rebuild() }
    }

    private func rebuild() {
        let available = ReferenceAttributeCatalog.available(extraColumns: settings.activeCatalogExtraColumns)
        labelsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.label) })
        entries = ReferenceAttributeCatalog
            .reconciled(available: available, storedJSON: settings.referenceAttributeConfigJSON)
            .map { ReferenceAttributeConfigEntry(id: $0.attribute.id, visible: $0.visible) }
    }

    private func persist() {
        guard !entries.isEmpty else { return }
        settings.referenceAttributeConfigJSON = ReferenceAttributeCatalog.encode(entries)
    }
}
