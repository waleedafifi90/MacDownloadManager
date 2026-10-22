import Foundation

/// Caps the combined speed of every download that shares it. One limiter can be shared
/// by all downloads (the global limit) and each download can have its own as well.
public actor SpeedLimiter {
    /// Nil or 0 means unlimited.
    public private(set) var bytesPerSecond: Int64?
    /// Bytes that may be used right now; negative means callers owe time.
    private var allowance: Double = 0
    private var lastRefill = Date()

    public init(bytesPerSecond: Int64? = nil) {
        self.bytesPerSecond = bytesPerSecond
    }

    public func setLimit(_ bytesPerSecond: Int64?) {
        self.bytesPerSecond = bytesPerSecond
        allowance = 0
        lastRefill = Date()
    }

    /// Waits until `count` bytes may be used without exceeding the limit.
    func acquire(_ count: Int) async throws {
        guard let rate = bytesPerSecond, rate > 0 else { return }
        let now = Date()
        // Allow at most a quarter second of burst.
        allowance = min(allowance + Double(rate) * now.timeIntervalSince(lastRefill), Double(rate) / 4)
        lastRefill = now
        allowance -= Double(count)
        if allowance < 0 {
            try await Task.sleep(for: .seconds(-allowance / Double(rate)))
        }
    }
}
