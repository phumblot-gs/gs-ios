import SwiftUI
import GSAPIClient
import GSCore

/// "Sync" page in the Settings menu. Surfaces the central
/// settings-sync state for the active account: status card,
/// metadata of the last write (who / when / push or restore),
/// and the Push / Pull / History actions. The whole feature is
/// gated on `AccountMe.isAdmin` — non-admins see read-only state.
struct SettingsSyncView: View {
    @Bindable var settings: DevSettings
    @Bindable var accountStore: AccountStore
    @Bindable var repository: SettingsSyncRepository

    @State private var snackbar: SnackbarMessage?
    @State private var isCheckingOnAppear = false
    @State private var confirmPush = false
    @State private var confirmPull = false

    var body: some View {
        Form {
            statusSection
            metadataSection
            actionsSection
            historyLinkSection
            if !isAdmin {
                adminFooterSection
            }
        }
        .navigationTitle("Sync")
        .overlay(alignment: .bottom) {
            if let snackbar {
                snackbarView(snackbar)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .task {
            guard !isCheckingOnAppear else { return }
            isCheckingOnAppear = true
            defer { isCheckingOnAppear = false }
            await repository.checkForRemoteUpdate()
        }
        .alert(
            "settings_sync_push_confirm_title",
            isPresented: $confirmPush
        ) {
            Button("settings_sync_dialog_confirm", role: .destructive) {
                Task { await performPush() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("settings_sync_push_confirm_message")
        }
        .alert(
            "settings_sync_pull_confirm_title",
            isPresented: $confirmPull
        ) {
            Button("settings_sync_dialog_confirm", role: .destructive) {
                Task { await performPull() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("settings_sync_pull_confirm_message")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusBadgeColor)
                    .frame(width: 12, height: 12)
                Text(statusBadgeLabel)
                    .font(.body.weight(.semibold))
                Spacer()
                if repository.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Text(statusDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Status")
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        if let summary = repository.summary {
            Section {
                if let author = summary.updated_by_user_name, !author.isEmpty {
                    LabeledContent("Last writer", value: author)
                }
                if let date = summary.updatedAtDate {
                    LabeledContent("Last update", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let action = summary.last_action {
                    LabeledContent("Last action", value: action.capitalized)
                }
            } header: {
                Text("Central entry")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                confirmPush = true
            } label: {
                HStack {
                    Label("Push local settings", systemImage: "icloud.and.arrow.up")
                    Spacer()
                }
            }
            .disabled(!canPush)

            Button {
                confirmPull = true
            } label: {
                HStack {
                    Label("Pull central settings", systemImage: "icloud.and.arrow.down")
                    Spacer()
                }
            }
            .disabled(!isAdmin || repository.isLoading)
        } footer: {
            Text("Push uploads your current preferences as the new central version for this active account. Pull replaces your local preferences with the central version.")
        }
    }

    private var historyLinkSection: some View {
        Section {
            NavigationLink {
                SettingsSyncHistoryView(
                    settings: settings,
                    accountStore: accountStore,
                    repository: repository
                )
            } label: {
                Label("View history", systemImage: "clock.arrow.circlepath")
            }
            .disabled(!isAdmin)
        }
    }

    private var adminFooterSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Read only — settings sync is reserved for main-account admins.")
        }
    }

    // MARK: - Derived

    private var isAdmin: Bool {
        accountStore.me?.isAdmin ?? false
    }

    private var canPush: Bool {
        guard isAdmin, !repository.isLoading else { return false }
        let snapshot = SyncableSettings.snapshot(from: settings)
        return !SyncableSettings.isAllDefault(snapshot)
    }

    private var statusBadgeColor: Color {
        switch repository.state {
        case .noRemote: return .gray
        case .synced: return .green
        case .localModified: return .orange
        case .remoteNewer: return .blue
        case .diverged: return .red
        }
    }

    private var statusBadgeLabel: LocalizedStringKey {
        switch repository.state {
        case .noRemote: return "No central entry"
        case .synced: return "Synced"
        case .localModified: return "Local changes"
        case .remoteNewer: return "Newer version available"
        case .diverged: return "Diverged"
        }
    }

    private var statusDescription: LocalizedStringKey {
        switch repository.state {
        case .noRemote: return "No central settings have been pushed for this account yet."
        case .synced: return "Your local preferences match the central version."
        case .localModified: return "You've changed local preferences since the last pull. Push to share them."
        case .remoteNewer: return "Another device pushed a newer version. Pull to apply it locally."
        case .diverged: return "Local and central changed since the last pull. Pushing will overwrite the central version."
        }
    }

    // MARK: - Actions

    private func performPush() async {
        do {
            let ok = try await repository.push()
            if ok {
                switch repository.lastAction {
                case .overwrittenByOtherDevice:
                    snackbar = SnackbarMessage(
                        text: String(localized: "Saved — but another device wrote at the same time."),
                        tone: .warning
                    )
                default:
                    snackbar = SnackbarMessage(
                        text: String(localized: "Settings pushed."),
                        tone: .success
                    )
                }
            } else if let msg = repository.lastErrorMessage {
                snackbar = SnackbarMessage(text: msg, tone: .info)
            }
        } catch SettingsSyncError.rateLimited(let s) {
            snackbar = SnackbarMessage(
                text: String(localized: "Slow down — retry in \(s) s."),
                tone: .warning
            )
        } catch {
            if let msg = repository.lastErrorMessage {
                snackbar = SnackbarMessage(text: msg, tone: .error)
            }
        }
    }

    private func performPull() async {
        let ok = await repository.pull()
        if ok {
            snackbar = SnackbarMessage(
                text: String(localized: "Pulled central settings."),
                tone: .success
            )
        } else if let msg = repository.lastErrorMessage {
            snackbar = SnackbarMessage(text: msg, tone: .error)
        }
    }

    // MARK: - Snackbar

    private struct SnackbarMessage: Identifiable {
        let id = UUID()
        let text: String
        let tone: Tone
        enum Tone { case success, warning, error, info }
    }

    private func snackbarView(_ message: SnackbarMessage) -> some View {
        Text(message.text)
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(snackbarColor(for: message.tone), in: Capsule())
            .task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if snackbar?.id == message.id {
                    snackbar = nil
                }
            }
    }

    private func snackbarColor(for tone: SnackbarMessage.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return .blue
        }
    }
}
