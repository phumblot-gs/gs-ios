import Foundation
import GSCore

/// CRUD on `/production` — list productions filtered by shooting
/// method + day, and create a fresh one when nothing matches the
/// current day yet.
public struct ProductionService: Sendable {
    private let http: GSHTTPClient
    private let logger = GSLogger(category: "ProductionService")

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
        timezone: String,
        templateID: Int? = nil
    ) async throws -> Production {
        Self.startdateFormatter.timeZone = TimeZone(identifier: timezone) ?? .current
        let payload = CreatePayload(
            smalltext: smalltext,
            startdate: Self.startdateFormatter.string(from: startdate),
            timezone: timezone,
            shootingMethodID: shootingMethodID,
            templateID: templateID
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
    /// shooting method whose `startdate` falls on `date` (in
    /// `timezone`), creating one when none exists. Filtering by date
    /// is client-side — see `list(shootingMethodID:)` for the why.
    ///
    /// Race-rallying on create: two devices listing in parallel both
    /// see an empty same-day result and both POST, splitting the
    /// day's shoots across two productions. After our own POST, we
    /// re-list and converge on the production with the smallest
    /// `rootID` for the day (deterministic across clients by GS's
    /// insertion order). We don't delete our duplicate — leave the
    /// extra empty production on the server for a human to clean up;
    /// no photos are misrouted in the meantime.
    public func findOrCreateToday(
        shootingMethodID: Int,
        smalltext: String = "TECH VIEWS",
        date: Date = .now,
        timezone: String = TimeZone.current.identifier,
        templateID: Int? = nil
    ) async throws -> Production {
        let all = try await list(shootingMethodID: shootingMethodID)
        if let production = all.first(where: {
            Self.startdate($0.startdate, isSameDayAs: date, timezone: timezone)
        }) {
            return production
        }
        let created = try await create(
            shootingMethodID: shootingMethodID,
            smalltext: smalltext,
            startdate: date,
            timezone: timezone,
            templateID: templateID
        )
        // Race window: any other device that listed before our POST
        // and hasn't created yet will create theirs after we did,
        // landing in the same day but with a higher rootID. Re-list
        // and pick the lowest-rootID same-day entry so every client
        // converges on it.
        let rechecked = (try? await list(shootingMethodID: shootingMethodID)) ?? []
        let sameDay = rechecked.filter {
            Self.startdate($0.startdate, isSameDayAs: date, timezone: timezone)
        }
        if let canonical = sameDay.min(by: { $0.rootID < $1.rootID }),
           canonical.rootID != created.rootID {
            logger.info("Rallying to earlier same-day production rootID=\(canonical.rootID) (we created \(created.rootID) as a duplicate)")
            return canonical
        }
        return created
    }

    /// True when a production's `startdate` (as returned by GS, in any
    /// common ISO-ish shape) falls on the same calendar day as `date`.
    /// Parsing to an absolute instant first makes the match
    /// timezone-safe: a production created just after midnight in
    /// `timezone` is still "today" even when GS echoes the value back
    /// in UTC (which is what broke the previous string-prefix check —
    /// 00:34 Europe/Paris is the *previous* day in UTC, so no "today"
    /// production was ever found and a new one was created per photo).
    static func startdate(_ raw: String?, isSameDayAs date: Date, timezone: String) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        let tz = TimeZone(identifier: timezone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        if let parsed = parseDate(raw, assuming: tz) {
            return calendar.isDate(parsed, inSameDayAs: date)
        }
        // Last-resort fallback: bare day-prefix compare in `tz`.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return raw.hasPrefix(f.string(from: date))
    }

    /// Parses the date shapes GS realistically returns: an ISO-8601
    /// instant (with `Z` / `+hh:mm`, optional fractional seconds), or
    /// a timezone-less `yyyy-MM-dd[THH:mm:ss]` string interpreted in
    /// `tz` (the timezone we created the production under).
    private static func parseDate(_ raw: String, assuming tz: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = pattern
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    private struct CreatePayload: Encodable, Sendable {
        let smalltext: String
        let startdate: String
        let timezone: String
        let shootingMethodID: Int
        // Optional: omitted from the JSON when nil (synthesized
        // `encode(to:)` uses `encodeIfPresent` for optionals), so a
        // template-less production is created without it. The API
        // expects `bench_template_id` (the OpenAPI spec's
        // `template_id` is stale and rejected with a 400).
        let templateID: Int?

        private enum CodingKeys: String, CodingKey {
            case smalltext, startdate, timezone
            case shootingMethodID = "shooting_method_id"
            case templateID = "bench_template_id"
        }
    }

    private static let startdateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
