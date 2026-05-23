import SwiftUI
import GSAPIClient
import GSCore

/// "Scanner" page in the Settings menu. Groups everything related
/// to the barcode-scan / stock-item flow: enabled stock statuses,
/// the workflow defaults, batch type catalogue, what the scanned
/// value resolves against, and the measurement unit.
struct SettingsScannerView: View {
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache

    @State private var isRefreshing = false

    var body: some View {
        Form {
            statusesSection
            workflowSection
            batchTypesSection
            searchAttributeSection
            measurementSection
            zoneSection
        }
        .navigationTitle("Scanner")
    }

    // MARK: - Enabled statuses

    private var statusesSection: some View {
        Section {
            ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                Toggle(isOn: Binding(
                    get: { settings.enabledStockItemStatuses.contains(status.rawValue) },
                    set: { isOn in
                        var set = settings.enabledStockItemStatuses
                        if isOn { set.insert(status.rawValue) } else { set.remove(status.rawValue) }
                        // Default-on-register can't be disabled.
                        set.insert(settings.defaultStockItemStatusOnRegister)
                        settings.enabledStockItemStatuses = set
                    }
                )) {
                    HStack {
                        Text(status.displayName)
                        Spacer()
                        Text("\(status.rawValue)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(status.rawValue == settings.defaultStockItemStatusOnRegister)
            }
        } header: {
            Text("Enabled statuses")
        } footer: {
            Text("Only enabled statuses appear in the change-status picker. The default-on-register status is always enabled.")
        }
    }

    // MARK: - Workflow (default status + catalog refresh)

    private var workflowSection: some View {
        Section {
            Picker("Default status on register", selection: $settings.defaultStockItemStatusOnRegister) {
                ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                    Text(status.displayName).tag(status.rawValue)
                }
            }
            Button {
                Task { await refreshCatalog() }
            } label: {
                HStack {
                    Label("Refresh catalog", systemImage: "arrow.clockwise")
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRefreshing)
            if let date = catalog.lastRefreshAt {
                LabeledContent("Last refresh", value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Workflow")
        } footer: {
            Text("Default status applied to newly-registered stock items. Refresh pulls fresh zones, categories, and batch types from Grand Shooting.")
        }
    }

    // MARK: - Batch types

    private var batchTypesSection: some View {
        Section {
            if settings.batchTypes.isEmpty {
                Text("No batch types known yet. They populate from your account's batches on the next refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.batchTypes, id: \.self) { type in
                    Text(type)
                }
                .onDelete { indexSet in
                    var types = settings.batchTypes
                    types.remove(atOffsets: indexSet)
                    settings.batchTypes = types
                }
            }
        } header: {
            Text("Batch types")
        } footer: {
            Text("Values offered when creating or editing a batch. Seeded from your existing batches; you can remove unwanted entries here.")
        }
    }

    // MARK: - Search attribute

    private var searchAttributeSection: some View {
        Section {
            Picker("Barcode maps to", selection: $settings.searchAttribute) {
                ForEach(StockService.SearchAttribute.allCases, id: \.rawValue) { attribute in
                    Text(attribute.displayName).tag(attribute)
                }
            }
        } header: {
            Text("Scan lookup")
        } footer: {
            Text("Which catalog attribute the scanned value is looked up against. Use `ean` unless your products are barcoded by their `ref` instead.")
        }
    }

    // MARK: - Measurements

    private var measurementSection: some View {
        Section {
            Picker("Unit", selection: $settings.measurementUnit) {
                ForEach(DevSettings.MeasurementUnit.allCases, id: \.rawValue) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
        } header: {
            Text("Measurements")
        } footer: {
            Text("Unit used when capturing dimensions in the Measures tab and storing them on the reference.")
        }
    }

    // MARK: - Zone

    @ViewBuilder
    private var zoneSection: some View {
        if catalog.hasZones {
            Section {
                Picker("Active zone", selection: Binding(
                    get: { settings.activeZone ?? catalog.zones.first?.smalltext ?? "" },
                    set: { newValue in settings.activeZone = newValue.isEmpty ? nil : newValue }
                )) {
                    ForEach(catalog.zones) { zone in
                        Text(zone.smalltext).tag(zone.smalltext)
                    }
                }
            } header: {
                Text("Zone")
            } footer: {
                Text("Studio area you are currently working in. Newly-created batches default to this zone.")
            }
        }
    }

    // MARK: - Actions

    private func refreshCatalog() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await catalog.refresh(environment: settings.currentEnvironment)
    }
}
