import SwiftUI
import GSAPIClient
import GSCore

/// Prominent active-account selector shown under the title on the Scan
/// and Settings tabs. Deliberately styled apart from the menu cards —
/// a tinted accent fill with a leading accent bar — so it stands out.
/// Tapping opens the single-select picker over the enabled accounts.
///
/// Call sites should gate on `settings.activeAccountID != nil` so the
/// bar only appears once an account context exists.
struct ActiveAccountBar: View {
    @Bindable var settings: DevSettings
    @State private var showPicker = false

    private var activeAccount: AccountInfo? {
        settings.accounts.first { $0.accountID == settings.activeAccountID }
    }

    private var canSwitch: Bool {
        settings.enabledAccounts.count >= 2
    }

    var body: some View {
        Button {
            if canSwitch { showPicker = true }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Active account")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.accentColor)
                    HStack(spacing: 6) {
                        Text(activeAccount?.company ?? "—")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let id = settings.activeAccountID {
                            Text("· #\(id)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 8)

                if canSwitch {
                    HStack(spacing: 4) {
                        Text("Change")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
        .fullScreenCover(isPresented: $showPicker) {
            AccountPickerSheet(
                title: "Select account",
                accounts: settings.enabledAccounts,
                recentIDs: settings.recentAccountIDs,
                mode: .single(active: settings.activeAccountID, onPick: { pick($0) })
            )
        }
    }

    /// Switches the active account and refreshes the account-scoped
    /// referentials (catalog) so the rest of the app reflects it.
    private func pick(_ id: Int) {
        guard id != settings.activeAccountID else { return }
        settings.applyActiveAccount(id)
        Task { await CatalogCache.shared.refresh(environment: settings.currentEnvironment) }
    }
}
