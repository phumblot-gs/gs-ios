import Foundation

/// A logical grouping of stock items — a box, a shelf, a pallet.
/// Optionally linked to a `Zone` (string label, per the GS API). The
/// `code` attribute is a barcode the user can scan to open the batch's
/// contents directly.
public struct Batch: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let smalltext: String?
    public let code: String?
    public let type: String?
    public let zone: String?
    public let dateCre: String?
    public let dateMod: String?

    public init(
        id: Int,
        smalltext: String? = nil,
        code: String? = nil,
        type: String? = nil,
        zone: String? = nil,
        dateCre: String? = nil,
        dateMod: String? = nil
    ) {
        self.id = id
        self.smalltext = smalltext
        self.code = code
        self.type = type
        self.zone = zone
        self.dateCre = dateCre
        self.dateMod = dateMod
    }

    private enum CodingKeys: String, CodingKey {
        case id = "batch_id"
        case smalltext
        case code
        case type
        case zone
        case dateCre = "date_cre"
        case dateMod = "date_mod"
    }

    /// Custom decoder: GS sometimes returns `batch_id` as a String even
    /// though the spec documents it as a number. Accept both Int and
    /// numeric String shapes so list + update paths don't blow up.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decode(Int.self, forKey: .id) {
            self.id = intID
        } else if let stringID = try? c.decode(String.self, forKey: .id), let n = Int(stringID) {
            self.id = n
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c,
                debugDescription: "batch_id is missing or not coercible to Int"
            )
        }
        self.smalltext = try c.decodeIfPresent(String.self, forKey: .smalltext)
        self.code = try c.decodeIfPresent(String.self, forKey: .code)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.zone = try c.decodeIfPresent(String.self, forKey: .zone)
        self.dateCre = try c.decodeIfPresent(String.self, forKey: .dateCre)
        self.dateMod = try c.decodeIfPresent(String.self, forKey: .dateMod)
    }

    public var displayName: String {
        if let smalltext, !smalltext.isEmpty { return smalltext }
        if let code, !code.isEmpty { return code }
        return "Batch #\(id)"
    }
}
