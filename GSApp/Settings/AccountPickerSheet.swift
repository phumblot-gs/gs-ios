import SwiftUI
import GSAPIClient

/// Full-screen account picker. Two modes:
///
/// - `.single` (Scan tab): pick THE active account from the enabled
///   pool. When the pool has more than `recentShortcutThreshold`
///   accounts, the three most-recently-selected ones are surfaced as
///   shortcut chips above the filter.
/// - `.multi` (Profile): toggle which accounts are enabled. No recents
///   shortcut; the set is committed on dismiss.
///
/// A filter field (name or `account_id`) is shared by both modes and
/// scales the picker to large account lists.
struct AccountPickerSheet: View {
    enum Mode {
        case single(active: Int?, onPick: (Int) -> Void)
        case multi(initial: Set<Int>, onCommit: (Set<Int>) -> Void)
    }

    let title: LocalizedStringKey
    let accounts: [AccountInfo]
    /// Most-recent-first account ids (single mode only).
    let recentIDs: [Int]
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var enabledDraft: Set<Int> = []

    private static let recentShortcutThreshold = 5
    private static let recentShortcutCount = 3

    private var isMulti: Bool {
        if case .multi = mode { return true }
        return false
    }

    /// The 3 most-recent accounts that still exist — single mode only,
    /// and only when the pool is large enough to warrant a shortcut.
    private var recentAccounts: [AccountInfo] {
        guard case .single = mode,
              accounts.count > Self.recentShortcutThreshold else { return [] }
        return recentIDs.prefix(Self.recentShortcutCount).compactMap { id in
            accounts.first { $0.accountID == id }
        }
    }

    private var filteredAccounts: [AccountInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return accounts }
        return accounts.filter { account in
            (account.company ?? "").lowercased().contains(q)
                || String(account.accountID).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !recentAccounts.isEmpty {
                    recentsBar
                    Divider()
                }
                filterField
                Divider()
                accountList
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isMulti {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { commitMulti() }
                    }
                }
            }
            .onAppear {
                if case .multi(let initial, _) = mode { enabledDraft = initial }
            }
        }
    }

    // MARK: - Recents shortcut (single mode)

    private var recentsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recentAccounts) { account in
                        Button {
                            pick(account.accountID)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.company ?? "—")
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text("#\(account.accountID)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isActive(account.accountID) ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isActive(account.accountID) ? Color.accentColor : .clear, lineWidth: 1)
                            )
                        }
                        .tint(.primary)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Filter

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name or ID", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var accountList: some View {
        List {
            if filteredAccounts.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(filteredAccounts) { account in
                    Button {
                        rowTapped(account.accountID)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.company ?? "—")
                                    .foregroundStyle(.primary)
                                Text("#\(account.accountID)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if let host = account.apiHost {
                                    Text(host)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if isRowSelected(account.accountID) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Selection helpers

    private func isActive(_ id: Int) -> Bool {
        if case .single(let active, _) = mode { return active == id }
        return false
    }

    private func isRowSelected(_ id: Int) -> Bool {
        switch mode {
        case .single(let active, _): return active == id
        case .multi: return enabledDraft.contains(id)
        }
    }

    private func rowTapped(_ id: Int) {
        switch mode {
        case .single:
            pick(id)
        case .multi:
            if enabledDraft.contains(id) { enabledDraft.remove(id) }
            else { enabledDraft.insert(id) }
        }
    }

    private func pick(_ id: Int) {
        if case .single(_, let onPick) = mode {
            onPick(id)
            dismiss()
        }
    }

    private func commitMulti() {
        if case .multi(_, let onCommit) = mode {
            onCommit(enabledDraft)
        }
        dismiss()
    }
}
