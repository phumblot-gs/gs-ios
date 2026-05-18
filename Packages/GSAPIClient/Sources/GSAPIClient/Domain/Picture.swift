import Foundation

/// One picture row from `/picture`. A single physical photo may have many
/// `Picture` rows tracking it through statuses — the convention is to group
/// by `filePath` and keep the row with the highest `pictureStatus`.
public struct Picture: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let ref: String?
    public let referenceID: String?
    public let path: String?
    public let filePath: String?
    public let thumbnail: String?
    public let smalltext: String?
    public let pictureStatus: Int?
    public let viewTypeCode: String?
    public let width: Int?
    public let height: Int?
    public let fileSize: Int?
    public let dateCre: String?
    public let dateMod: String?
    public let validationDate: String?

    public init(
        id: Int,
        ref: String? = nil,
        referenceID: String? = nil,
        path: String? = nil,
        filePath: String? = nil,
        thumbnail: String? = nil,
        smalltext: String? = nil,
        pictureStatus: Int? = nil,
        viewTypeCode: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fileSize: Int? = nil,
        dateCre: String? = nil,
        dateMod: String? = nil,
        validationDate: String? = nil
    ) {
        self.id = id
        self.ref = ref
        self.referenceID = referenceID
        self.path = path
        self.filePath = filePath
        self.thumbnail = thumbnail
        self.smalltext = smalltext
        self.pictureStatus = pictureStatus
        self.viewTypeCode = viewTypeCode
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.dateCre = dateCre
        self.dateMod = dateMod
        self.validationDate = validationDate
    }

    private enum CodingKeys: String, CodingKey {
        case id = "picture_id"
        case ref
        case referenceID = "reference_id"
        case path
        case filePath = "file_path"
        case thumbnail
        case smalltext
        case pictureStatus = "picturestatus"
        case viewTypeCode = "view_type_code"
        case width
        case height
        case fileSize = "filesize"
        case dateCre = "date_cre"
        case dateMod = "date_mod"
        case validationDate = "validation_date"
    }

    /// Custom decoder so `reference_id` survives the schema's
    /// `x-alternatives: [string, number]` — GS returns it as a number on
    /// some endpoints and a string on others. Same flex applied to
    /// `picture_id` defensively (the spec says `number` but reality varies).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // picture_id is required — try Int then String.
        if let intID = try? c.decode(Int.self, forKey: .id) {
            self.id = intID
        } else if let stringID = try? c.decode(String.self, forKey: .id), let n = Int(stringID) {
            self.id = n
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "picture_id missing or not coercible to Int")
        }
        self.ref = try c.decodeIfPresent(String.self, forKey: .ref)
        if let stringRefID = try? c.decodeIfPresent(String.self, forKey: .referenceID) {
            self.referenceID = stringRefID
        } else if let intRefID = try? c.decodeIfPresent(Int.self, forKey: .referenceID) {
            self.referenceID = String(intRefID)
        } else {
            self.referenceID = nil
        }
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        self.filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        self.thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        self.smalltext = try c.decodeIfPresent(String.self, forKey: .smalltext)
        self.pictureStatus = try c.decodeIfPresent(Int.self, forKey: .pictureStatus)
        self.viewTypeCode = try c.decodeIfPresent(String.self, forKey: .viewTypeCode)
        self.width = try c.decodeIfPresent(Int.self, forKey: .width)
        self.height = try c.decodeIfPresent(Int.self, forKey: .height)
        self.fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        self.dateCre = try c.decodeIfPresent(String.self, forKey: .dateCre)
        self.dateMod = try c.decodeIfPresent(String.self, forKey: .dateMod)
        self.validationDate = try c.decodeIfPresent(String.self, forKey: .validationDate)
    }

    public var thumbnailURL: URL? {
        thumbnail.flatMap { URL(string: $0) }
    }
}

/// Helpers for collapsing a raw `[Picture]` from the API into the per-file
/// "latest status" view the user wants to see.
public extension Array where Element == Picture {
    /// Group by `filePath`, keep the entry with the highest `pictureStatus`
    /// in each group. Returns the surviving entries.
    func latestByFilePath() -> [Picture] {
        var byPath: [String: Picture] = [:]
        for picture in self {
            let key = picture.filePath ?? "picture_id:\(picture.id)"
            let best = byPath[key]
            if best == nil || (picture.pictureStatus ?? -1) > (best?.pictureStatus ?? -1) {
                byPath[key] = picture
            }
        }
        return Array<Picture>(byPath.values)
    }
}
