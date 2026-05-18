import Foundation

/// Workflow status of a physical sample (`stock_item`) inside Grand Shooting.
/// The numeric values are the raw values the GS API uses; the cases are
/// named after the labels documented in the GS API spec.
///
/// Not a strict workflow graph — any status can transition to any other —
/// but the natural progression is roughly:
/// `receive → addToStock → prepare → markAsDispatched → backInWarehouse`,
/// with the others used for edge cases (transfers, errors, returns, etc.).
public enum StockItemStatus: Int, Sendable, Hashable, CaseIterable, Codable {
    case warehouseStock = 10
    case picking = 12
    case sent = 15
    case sentFromWarehouse = 17
    case receive = 20
    case addToStock = 30
    case inventory = 40
    case transfer = 45
    case enriched = 48
    case prepare = 50
    case clientReturn = 51
    case error = 60
    case markAsDispatched = 70
    case backInWarehouse = 75
    case lost = 90

    public var displayName: String {
        switch self {
        case .warehouseStock: return String(localized: "Warehouse stock")
        case .picking: return String(localized: "Picking")
        case .sent: return String(localized: "Sent")
        case .sentFromWarehouse: return String(localized: "Sent from warehouse")
        case .receive: return String(localized: "Receive")
        case .addToStock: return String(localized: "Add to stock")
        case .inventory: return String(localized: "Inventory")
        case .transfer: return String(localized: "Transfer")
        case .enriched: return String(localized: "Enriched")
        case .prepare: return String(localized: "Prepare")
        case .clientReturn: return String(localized: "Client return")
        case .error: return String(localized: "Error")
        case .markAsDispatched: return String(localized: "Mark as dispatched")
        case .backInWarehouse: return String(localized: "Back in warehouse")
        case .lost: return String(localized: "Lost")
        }
    }

    /// The order presented in UI pickers (default is `Self.allCases` which
    /// matches the raw-value sort order — same as the GS spec). The user
    /// can disable individual statuses via `DevSettings.enabledStockItemStatuses`.
    public static var orderedCases: [StockItemStatus] { allCases }
}
