import Foundation

/// The authenticated user's identity + the GS accounts they can
/// access, as returned by `GET /account/me`. Only the fields the app
/// actually uses are decoded; the rich `prefs` blob per account is
/// ignored.
public struct AccountMe: Sendable, Hashable, Codable {
    public let firstname: String?
    public let email: String?
    public let company: String?
    public let avatar: String?
    /// The user's home account — drives the default shard for
    /// `/stock*` calls and the identity shown at the top of Profile.
    public let accountID: Int?
    /// User role on the main account. The settings-sync backend
    /// gates every read/write on `role == "admin"` — non-admins
    /// can't push, pull, or browse history.
    public let role: String?
    /// Every account the user can switch between. Each carries its own
    /// `api_host` (shard) so switching reroutes the API.
    public let accounts: [AccountInfo]

    public init(
        firstname: String? = nil,
        email: String? = nil,
        company: String? = nil,
        avatar: String? = nil,
        accountID: Int? = nil,
        role: String? = nil,
        accounts: [AccountInfo] = []
    ) {
        self.firstname = firstname
        self.email = email
        self.company = company
        self.avatar = avatar
        self.accountID = accountID
        self.role = role
        self.accounts = accounts
    }

    /// True when the user is an admin of the main account. Drives the
    /// client-side gating of the Settings-Sync UI (boutons grisés,
    /// auto-pull skip, etc.) so non-admins never hit a 403 from the
    /// backend.
    public var isAdmin: Bool {
        role?.lowercased() == "admin"
    }

    private enum CodingKeys: String, CodingKey {
        case firstname
        case email
        case company
        case avatar
        case accountID = "account_id"
        case role
        case accounts
    }
}

/// One GS account the user can access. `apiHost` is the shard the
/// account's data lives on (e.g. `https://api-34.grand-shooting.com`).
public struct AccountInfo: Sendable, Hashable, Codable, Identifiable {
    public let accountID: Int
    public let company: String?
    public let apiHost: String?
    /// Custom catalog columns configured on this account
    /// (`prefs.catalog_extra_cols`). Surfaced so the reference info
    /// block can offer them as displayable attributes.
    public let catalogExtraColumns: [CatalogExtraColumn]

    public var id: Int { accountID }

    public init(
        accountID: Int,
        company: String? = nil,
        apiHost: String? = nil,
        catalogExtraColumns: [CatalogExtraColumn] = []
    ) {
        self.accountID = accountID
        self.company = company
        self.apiHost = apiHost
        self.catalogExtraColumns = catalogExtraColumns
    }

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case company
        case apiHost = "api_host"
        case prefs
    }

    private enum PrefsKeys: String, CodingKey {
        case catalogExtraCols = "catalog_extra_cols"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(Int.self, forKey: .accountID)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        apiHost = try c.decodeIfPresent(String.self, forKey: .apiHost)
        if let prefs = try? c.nestedContainer(keyedBy: PrefsKeys.self, forKey: .prefs),
           let cols = try? prefs.decodeIfPresent([CatalogExtraColumn].self, forKey: .catalogExtraCols) {
            catalogExtraColumns = cols
        } else {
            catalogExtraColumns = []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountID, forKey: .accountID)
        try c.encodeIfPresent(company, forKey: .company)
        try c.encodeIfPresent(apiHost, forKey: .apiHost)
        if !catalogExtraColumns.isEmpty {
            var prefs = c.nestedContainer(keyedBy: PrefsKeys.self, forKey: .prefs)
            try prefs.encode(catalogExtraColumns, forKey: .catalogExtraCols)
        }
    }
}

/// A custom catalog column declared on an account
/// (`prefs.catalog_extra_cols[]`). `key` matches the value's field on
/// a reference; `label` is the human title to show.
public struct CatalogExtraColumn: Sendable, Hashable, Codable, Identifiable {
    public let key: String?
    public let label: String?
    public let type: String?

    public var id: String { key ?? label ?? "" }

    /// A column is displayable only when it has both a key (to read the
    /// value off a reference) and a label (to title the row).
    public var isDisplayable: Bool {
        (key?.isEmpty == false) && (label?.isEmpty == false)
    }

    public init(key: String?, label: String?, type: String? = nil) {
        self.key = key
        self.label = label
        self.type = type
    }
}
