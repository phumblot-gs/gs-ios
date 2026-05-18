import Foundation

/// A catalog SKU. The single mandatory field is `ref`; everything else is
/// optional in the GS data model.
public struct Reference: Sendable, Hashable, Identifiable, Codable {
    public let id: Int?
    public let ref: String
    public let ean: String?
    public let eans: [String]?
    public let smalltext: String?
    public let categoryID: Int?
    public let univers: String?
    public let gamme: String?
    public let family: String?
    public let sku: String?
    public let brand: String?
    public let collection: String?
    public let gender: String?
    public let color: String?
    public let hexaColor: String?
    public let size: String?
    public let tags: [String]?
    public let online: String?
    public let productRef: String?
    public let productSmalltext: String?

    public init(
        id: Int? = nil,
        ref: String,
        ean: String? = nil,
        eans: [String]? = nil,
        smalltext: String? = nil,
        categoryID: Int? = nil,
        univers: String? = nil,
        gamme: String? = nil,
        family: String? = nil,
        sku: String? = nil,
        brand: String? = nil,
        collection: String? = nil,
        gender: String? = nil,
        color: String? = nil,
        hexaColor: String? = nil,
        size: String? = nil,
        tags: [String]? = nil,
        online: String? = nil,
        productRef: String? = nil,
        productSmalltext: String? = nil
    ) {
        self.id = id
        self.ref = ref
        self.ean = ean
        self.eans = eans
        self.smalltext = smalltext
        self.categoryID = categoryID
        self.univers = univers
        self.gamme = gamme
        self.family = family
        self.sku = sku
        self.brand = brand
        self.collection = collection
        self.gender = gender
        self.color = color
        self.hexaColor = hexaColor
        self.size = size
        self.tags = tags
        self.online = online
        self.productRef = productRef
        self.productSmalltext = productSmalltext
    }

    private enum CodingKeys: String, CodingKey {
        case id = "reference_id"
        case ref
        case ean
        case eans
        case smalltext
        case categoryID = "category_id"
        case univers
        case gamme
        case family
        case sku
        case brand
        case collection
        case gender
        case color
        case hexaColor = "hexa_color"
        case size
        case tags
        case online
        case productRef = "product_ref"
        case productSmalltext = "product_smalltext"
    }

    /// Best human label, falling back through smalltext → ref.
    public var displayName: String {
        smalltext.map { "\($0)" } ?? ref
    }
}
