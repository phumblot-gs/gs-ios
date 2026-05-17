import Foundation
import os

// MARK: - Domain Models

/// A physical sample (a single unit being photographed / shipped).
public struct Sample: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let barcode: String
    public let productID: UUID?
    public let receivedAt: Date?
    public let shippedAt: Date?

    public init(
        id: UUID = UUID(),
        barcode: String,
        productID: UUID? = nil,
        receivedAt: Date? = nil,
        shippedAt: Date? = nil
    ) {
        self.id = id
        self.barcode = barcode
        self.productID = productID
        self.receivedAt = receivedAt
        self.shippedAt = shippedAt
    }
}

/// A product reference (SKU-level).
public struct Product: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let sku: String
    public let name: String
    public let brand: String?

    public init(id: UUID = UUID(), sku: String, name: String, brand: String? = nil) {
        self.id = id
        self.sku = sku
        self.name = name
        self.brand = brand
    }
}

/// A shipment (in or out) of one or more samples.
public struct Shipment: Sendable, Hashable, Identifiable, Codable {
    public enum Direction: String, Sendable, Codable {
        case inbound
        case outbound
    }

    public let id: UUID
    public let direction: Direction
    public let trackingNumber: String?
    public let sampleIDs: [UUID]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        direction: Direction,
        trackingNumber: String? = nil,
        sampleIDs: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.trackingNumber = trackingNumber
        self.sampleIDs = sampleIDs
        self.createdAt = createdAt
    }
}

/// A LiDAR-derived physical measurement (millimetres).
public struct Measurement: Sendable, Hashable, Codable {
    public let widthMM: Double
    public let heightMM: Double
    public let depthMM: Double
    public let capturedAt: Date

    public init(widthMM: Double, heightMM: Double, depthMM: Double, capturedAt: Date = Date()) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.depthMM = depthMM
        self.capturedAt = capturedAt
    }
}

// MARK: - Logging

/// Thin wrapper over `os.Logger` so the rest of the codebase doesn't import `os` directly.
public struct GSLogger: Sendable {
    public static let subsystem = "com.grandshooting.gsmobile"

    private let logger: Logger

    public init(category: String) {
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    public func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    public func fault(_ message: String) { logger.fault("\(message, privacy: .public)") }
}

// MARK: - Configuration

/// Backend configuration — sharded per account (e.g. `api-34.grand-shooting.com`).
public struct GSEnvironment: Sendable, Hashable, Codable {
    public let apiBaseURL: URL
    public let oauthEntryURL: URL

    public init(apiBaseURL: URL, oauthEntryURL: URL) {
        self.apiBaseURL = apiBaseURL
        self.oauthEntryURL = oauthEntryURL
    }

    /// Default placeholder shard. Replace at runtime once user selects/enters their account.
    public static let placeholder = GSEnvironment(
        apiBaseURL: URL(string: "https://api-34.grand-shooting.com/v3")!,
        oauthEntryURL: URL(string: "https://api.mobile.grand-shooting.com/auth/start")!
    )
}
