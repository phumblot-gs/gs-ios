import Foundation
import GSCore

/// CRUD on `/production` — list productions filtered by shooting
/// method + day, and create a fresh one when nothing matches the
/// current day yet.
public struct ProductionService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// GET /production?shooting_method_id=…&startdate=YYYY-MM-DD.
    /// GS returns an array-of-arrays (productions grouped by some
    /// server-side bucket); flatten before handing back.
    public func list(shootingMethodID: Int, date: Date) async throws -> [Production] {
        let dateString = Self.dayFormatter.string(from: date)
        let nested = try await http.get(
            "/production",
            query: [
                "shooting_method_id": String(shootingMethodID),
                "startdate": dateString
            ],
            as: [[Production]].self
        )
        return nested.flatMap { $0 }
    }

    /// POST /production with the minimal payload the tech-views flow
    /// needs (smalltext, startdate, timezone, shooting_method_id).
    /// GS responds with a flat `[Production]` (the freshly-created
    /// row), unlike the GET which wraps in `[[Production]]`. We grab
    /// the first element.
    public func create(
        shootingMethodID: Int,
        smalltext: String,
        startdate: Date,
        timezone: String
    ) async throws -> Production {
        Self.startdateFormatter.timeZone = TimeZone(identifier: timezone) ?? .current
        let payload = CreatePayload(
            smalltext: smalltext,
            startdate: Self.startdateFormatter.string(from: startdate),
            timezone: timezone,
            shootingMethodID: shootingMethodID
        )
        let created: [Production] = try await http.post(
            "/production",
            body: payload,
            as: [Production].self
        )
        guard let production = created.first else {
            throw GSHTTPClient.HTTPError.http(
                status: 500,
                body: "Production create returned an empty response."
            )
        }
        return production
    }

    /// Find-or-create: returns the first production for the given
    /// shooting method on `date`, creating one when GS reports none.
    public func findOrCreateToday(
        shootingMethodID: Int,
        smalltext: String = "TECH VIEWS",
        date: Date = .now,
        timezone: String = TimeZone.current.identifier
    ) async throws -> Production {
        let existing = try await list(shootingMethodID: shootingMethodID, date: date)
        if let production = existing.first { return production }
        return try await create(
            shootingMethodID: shootingMethodID,
            smalltext: smalltext,
            startdate: date,
            timezone: timezone
        )
    }

    private struct CreatePayload: Encodable, Sendable {
        let smalltext: String
        let startdate: String
        let timezone: String
        let shootingMethodID: Int

        private enum CodingKeys: String, CodingKey {
            case smalltext, startdate, timezone
            case shootingMethodID = "shooting_method_id"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let startdateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
