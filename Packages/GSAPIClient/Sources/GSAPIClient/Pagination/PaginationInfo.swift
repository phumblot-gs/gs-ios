import Foundation

/// Pagination metadata returned by Grand Shooting list endpoints. The
/// values live in response headers — the body is just the array.
public struct PaginationInfo: Sendable, Hashable {
    /// `X-Total-Count` — total number of items on the server.
    public let total: Int?
    /// `X-Offset` — offset of the first item in this page.
    public let offset: Int
    /// `X-Count` — number of items in this page.
    public let count: Int

    public init(total: Int?, offset: Int, count: Int) {
        self.total = total
        self.offset = offset
        self.count = count
    }

    public init(from headers: [AnyHashable: Any]) {
        func intHeader(_ name: String) -> Int? {
            for (key, value) in headers {
                guard let keyString = key as? String else { continue }
                if keyString.caseInsensitiveCompare(name) == .orderedSame {
                    if let intValue = value as? Int { return intValue }
                    if let stringValue = value as? String { return Int(stringValue) }
                }
            }
            return nil
        }
        self.total = intHeader("X-Total-Count")
        self.offset = intHeader("X-Offset") ?? 0
        self.count = intHeader("X-Count") ?? 0
    }

    /// True if there's at least one item past `offset + count`.
    public var hasMore: Bool {
        guard let total else {
            // Conservative: if the server didn't send X-Total-Count, assume
            // more if we got a full page (no way to know the exact server
            // page size, so we treat "got something" as "maybe more").
            return count > 0
        }
        return offset + count < total
    }

    public var nextOffset: Int { offset + count }
}
