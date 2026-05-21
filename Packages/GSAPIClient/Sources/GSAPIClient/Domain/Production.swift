import Foundation

/// A "production" on the Grand Shooting account — the time-bucketed
/// container under which photos are uploaded. Technical-view uploads
/// target the production matching the user-selected shooting method
/// on the current day; we create it on demand when none exists yet.
public struct Production: Sendable, Hashable, Identifiable, Codable {
    public let rootID: Int
    public let benchID: Int?
    public let smalltext: String?
    public let startdate: String?
    public let timezone: String?
    public let shootingMethodID: Int?

    public var id: Int { rootID }

    public init(
        rootID: Int,
        benchID: Int? = nil,
        smalltext: String? = nil,
        startdate: String? = nil,
        timezone: String? = nil,
        shootingMethodID: Int? = nil
    ) {
        self.rootID = rootID
        self.benchID = benchID
        self.smalltext = smalltext
        self.startdate = startdate
        self.timezone = timezone
        self.shootingMethodID = shootingMethodID
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "root_id"
        case benchID = "bench_id"
        case smalltext
        case startdate
        case timezone
        case shootingMethodID = "shooting_method_id"
    }
}
