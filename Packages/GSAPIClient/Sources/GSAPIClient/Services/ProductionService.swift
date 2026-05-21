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

    /// GET /production?shooting_method_id=…. GS returns an
    /// array-of-arrays (productions grouped by some server-side
    /// bucket); flatten before handing back. We deliberately don't
    /// pass `startdate` as a query filter — empirically GS doesn't
    /// match productions on a date-only value, so we filter
    /// client-side in `findOrCreateToday` instead. Cheaper to
    /// download the (small) list than risk creating duplicates.
    public func list(shootingMethodID: Int) async throws -> [Production] {
        let nested = try await http.get(
            "/production",
            query: ["shooting_method_id": String(shootingMethodID)],
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

    /// Find-or-create: returns the first production matching the
    /// shooting method whose `startdate` falls on `date` (local
    /// timezone), creating one when none exists. Filtering by date
    /// is client-side — see `list(shootingMethodID:)` for the why.
    public func findOrCreateToday(
        shootingMethodID: Int,
        smalltext: String = "TECH VIEWS",
        date: Date = .now,
        timezone: String = TimeZone.current.identifier
    ) async throws -> Production {
        let all = try await list(shootingMethodID: shootingMethodID)
        let todayPrefix = Self.dayFormatter.string(from: date)
        if let production = all.first(where: { ($0.startdate ?? "").hasPrefix(todayPrefix) }) {
            return production
        }
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
