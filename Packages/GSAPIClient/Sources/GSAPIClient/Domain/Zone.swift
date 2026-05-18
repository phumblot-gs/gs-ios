import Foundation

/// Physical storage zone in the studio. GS identifies zones by their
/// `smalltext` label only — there's no numeric `zone_id`. Many accounts
/// have none; the UI hides every zone control when `CatalogCache.zones`
/// is empty.
public struct Zone: Sendable, Hashable, Identifiable, Codable {
    public let smalltext: String

    /// SwiftUI / lookup identity = the label itself (it's the only way GS
    /// distinguishes one zone from another).
    public var id: String { smalltext }

    public init(smalltext: String) {
        self.smalltext = smalltext
    }
}
