#if os(iOS)
import Foundation
import AVFoundation

/// Cross-cutting symbology enum used by both the legacy VisionKit scanner
/// and the new AVFoundation `LiveBarcodeScanner`. We expose this instead of
/// `AVMetadataObject.ObjectType` so callers don't have to import AVFoundation.
public enum ScannedSymbology: Sendable, Hashable {
    case ean13
    case ean8
    case upcE
    case code128
    case code39
    case code93
    case itf14
    case qr
    case dataMatrix
    case pdf417
    case aztec
    case other(String)

    /// 1D barcodes get a horizontal "underline" in the overlay; 2D codes
    /// get four L-shaped corner brackets.
    public var isOneDimensional: Bool {
        switch self {
        case .ean13, .ean8, .upcE, .code128, .code39, .code93, .itf14:
            return true
        case .qr, .dataMatrix, .pdf417, .aztec:
            return false
        case .other:
            return false
        }
    }

    public init(_ av: AVMetadataObject.ObjectType) {
        switch av {
        case .ean13: self = .ean13
        case .ean8: self = .ean8
        case .upce: self = .upcE
        case .code128: self = .code128
        case .code39: self = .code39
        case .code93: self = .code93
        case .itf14: self = .itf14
        case .qr: self = .qr
        case .dataMatrix: self = .dataMatrix
        case .pdf417: self = .pdf417
        case .aztec: self = .aztec
        default: self = .other(av.rawValue)
        }
    }

    public static let allSupportedAVTypes: [AVMetadataObject.ObjectType] = [
        .ean13, .ean8, .upce, .code128, .code39, .code93, .itf14,
        .qr, .dataMatrix, .pdf417, .aztec
    ]
}
#endif
