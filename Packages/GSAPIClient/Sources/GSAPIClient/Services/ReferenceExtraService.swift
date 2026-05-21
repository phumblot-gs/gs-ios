import Foundation
import GSCore

/// GS API surface for `/reference/{reference_id}/extra` — the catch-all
/// field where we stash measurements (and anything else not modelled
/// directly in the catalog schema). The server merges the keys we send
/// with the existing `extra` map, so callers only need to provide the
/// keys they want to set.
public struct ReferenceExtraService: Sendable {

    /// One measurement value: a numeric distance plus its unit string
    /// (e.g. `"cm"`). Same shape on the way in and out, so the writer
    /// shares the reader's type defined on `ReferenceExtra`.
    public typealias MeasureValue = ReferenceExtra.MeasureValue

    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// PUT `/reference/:id/extra` with just the `measures` slice of the
    /// `extra` map. GS merges with whatever else is already there.
    public func updateMeasures(
        referenceID: Int,
        measures: [String: MeasureValue]
    ) async throws {
        let payload = ExtraPayload(extra: MeasuresWrapper(measures: measures))
        let _: EmptyResponse = try await http.put(
            "/reference/\(referenceID)/extra",
            body: payload,
            as: EmptyResponse.self
        )
    }

    /// PUT `/reference/:id/extra` with the `tech_views` slice. Only
    /// the keys present in `fields` are sent; everything else on
    /// `extra` (measures, other unmodelled keys) is left untouched by
    /// the GS merge.
    public func updateTechViews(
        referenceID: Int,
        fields: [String: String]
    ) async throws {
        let payload = ExtraPayload(extra: TechViewsWrapper(techViews: fields))
        let _: EmptyResponse = try await http.put(
            "/reference/\(referenceID)/extra",
            body: payload,
            as: EmptyResponse.self
        )
    }
}

// MARK: - Payload shapes

private struct ExtraPayload<Wrapped: Encodable & Sendable>: Encodable, Sendable {
    let extra: Wrapped
}

private struct MeasuresWrapper: Encodable, Sendable {
    let measures: [String: ReferenceExtraService.MeasureValue]
}

private struct TechViewsWrapper: Encodable, Sendable {
    let techViews: [String: String]

    private enum CodingKeys: String, CodingKey {
        case techViews = "tech_views"
    }
}
