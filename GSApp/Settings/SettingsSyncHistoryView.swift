import SwiftUI
import GSAPIClient
import GSCore

/// History of central settings versions for the active account.
/// Lets an admin browse past pushes / restores, inspect the blob of a
/// chosen entry, restore it (moves the central pointer), or delete it
/// (soft-delete, refused on the entry that is currently applied).
struct SettingsSyncHistoryView: View {
    @Bindable var settings: DevSettings
    @Bindable var accountStore: AccountStore
    @Bindable var repository: SettingsSyncRepository

    @State private var entries: [SettingsSyncHistoryEntry] = []
    @State private var isLoading = false
    @State private var inspecting: SettingsSyncHistoryEntryDetail?
    @State private var restoringID: String?
    @State private var deletingID: String?
    @State private var errorMessage: String?
    /// The version hash locally applied on this device (= the
    /// pointer hash at last successful sync). Used to render the
    /// `applied` badge on the matching history row, which is a
    /// distinct concept from the server's `is_current` ("central"):
    /// the device may legitimately lag behind the central pointer
    /// when another device pushed and this one hasn't pulled yet.
    @State private var appliedHash: String?

    var body: some View {
        List {
            if isLoading && entries.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            ForEach(entries) { entry in
                row(for: entry)
            }
            if let msg = errorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("History")
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .sheet(item: $inspecting) { detail in
            HistoryDetailSheet(detail: detail)
        }
        .alert(
            "Restore this version?",
            isPresented: Binding(
                get: { restoringID != nil },
                set: { if !$0 { restoringID = nil } }
            ),
            actions: {
                Button("Restore", role: .destructive) {
                    if let id = restoringID {
                        Task { await performRestore(id) }
                    }
                    restoringID = nil
                }
                Button("Cancel", role: .cancel) { restoringID = nil }
            },
            message: {
                Text("Move the central pointer to this version and re-apply it locally.")
            }
        )
        .alert(
            "Delete this version?",
            isPresented: Binding(
                get: { deletingID != nil },
                set: { if !$0 { deletingID = nil } }
            ),
            actions: {
                Button("Delete", role: .destructive) {
                    if let id = deletingID {
                        Task { await performDelete(id) }
                    }
                    deletingID = nil
                }
                Button("Cancel", role: .cancel) { deletingID = nil }
            },
            message: {
                Text("Soft-delete this historical version. It will no longer appear here.")
            }
        )
    }

    // MARK: - Row

    private func row(for entry: SettingsSyncHistoryEntry) -> some View {
        Button {
            Task { await openDetail(versionID: entry.version_id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(formattedDate(entry.created_at))
                            .font(.subheadline.weight(.medium))
                        if entry.is_current {
                            HistoryBadge(text: "settings_sync_history_current", tint: .green)
                        }
                        if let applied = appliedHash, entry.hash == applied {
                            HistoryBadge(text: "settings_sync_history_applied", tint: .blue)
                        }
                    }
                    if let name = entry.created_by_user_name, !name.isEmpty {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(entry.hash.prefix(12)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .tint(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !entry.is_current {
                Button(role: .destructive) {
                    deletingID = entry.version_id
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button {
                restoringID = entry.version_id
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
        .disabled(!isAdmin)
    }

    // MARK: - Detail sheet

    private struct HistoryDetailSheet: View {
        let detail: SettingsSyncHistoryEntryDetail

        var body: some View {
            NavigationStack {
                ScrollView {
                    Text(prettyPrinted)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Version content")
                .navigationBarTitleDisplayMode(.inline)
            }
        }

        private var prettyPrinted: String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: detail.blobAsDictionary,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let s = String(data: data, encoding: .utf8) else {
                return "—"
            }
            return s
        }
    }

    // MARK: - Actions

    private var isAdmin: Bool {
        accountStore.me?.isAdmin ?? false
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        entries = await repository.loadHistory()
        appliedHash = repository.locallyAppliedHash()
        errorMessage = repository.lastErrorMessage
    }

    private func openDetail(versionID: String) async {
        if let detail = await repository.loadHistoryEntry(versionID: versionID) {
            inspecting = detail
        } else {
            errorMessage = repository.lastErrorMessage
        }
    }

    private func performRestore(_ id: String) async {
        let ok = await repository.restore(versionID: id)
        if ok {
            await reload()
        } else {
            errorMessage = repository.lastErrorMessage
        }
    }

    private func performDelete(_ id: String) async {
        let ok = await repository.deleteHistoryEntry(versionID: id)
        if ok {
            await reload()
        } else {
            errorMessage = repository.lastErrorMessage
        }
    }

    // MARK: - Helpers

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Compact pill rendered on a history row. Two badges coexist on the
/// same entry when this device just pushed: "central" (server's
/// `is_current`) and "applied" (matches the local `lastPulledHash`).
private struct HistoryBadge: View {
    let text: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
    }
}
