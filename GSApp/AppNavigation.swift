import SwiftUI

/// Cross-tab navigation coordinator. Owns the `TabView` selection +
/// the Scan tab's `NavigationPath` so any view in the app can request
/// "land the user on Scanner → Scan products" programmatically (e.g.
/// after finishing tech views for a product).
@Observable
@MainActor
final class AppNavigation {
    enum AppTab: Hashable {
        case scan, photo, measure, history, settings
    }

    /// Marker pushed onto `scanPath` to drive the Scan stack onto the
    /// product scanner. Matched by a `navigationDestination(for:)` on
    /// the Scan tab.
    struct ScanProductsRoute: Hashable {}

    var selectedTab: AppTab = .scan
    var scanPath = NavigationPath()

    /// Switches to the Scan tab and replaces its navigation stack with
    /// the Scan-products scanner. Use after finishing a product flow
    /// to start a new scan.
    func navigateToScanProducts() {
        selectedTab = .scan
        scanPath = NavigationPath()
        scanPath.append(ScanProductsRoute())
    }
}
