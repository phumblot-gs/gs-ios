import SwiftUI
import GSAPIClient
import GSCore

/// Holds the authenticated user's `/account/me` payload and drives the
/// multi-account selection. Shared between app launch (seed accounts +
/// apply the active one) and the Profile screen (header + selector +
/// manual refresh).
@Observable
@MainActor
final class AccountStore {
    private(set) var me: AccountMe?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Fetches `/account/me`, pushes the accounts list into
    /// `DevSettings`, and applies the active account: the persisted
    /// selection when it still exists in the returned list, otherwise
    /// the user's home account (`me.account_id`).
    func load(settings: DevSettings) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let service = AccountService(environment: settings.currentEnvironment)
        do {
            let fetched = try await service.me()
            me = fetched
            settings.setAccounts(fetched.accounts, defaultAccountID: fetched.accountID)
            // Apply the active account constrained to the enabled set
            // (persisted selection if still enabled, else home).
            settings.applyActiveAccount(settings.resolvedActiveAccountID())
        } catch let err as GSHTTPClient.HTTPError {
            error = err.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}
