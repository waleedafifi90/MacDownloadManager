/// A byte range of the target file downloaded by one connection.
/// `current` is the next byte to write; `end` is inclusive and can shrink
/// when another connection takes over the second half of this range.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Int64
    public var current: Int64
    public var end: Int64

    public init(start: Int64, current: Int64? = nil, end: Int64) {
        self.start = start
        self.current = current ?? start
        self.end = end
    }

    public var remaining: Int64 { max(0, end - current + 1) }
    public var downloaded: Int64 { current - start }
    public var isComplete: Bool { current > end }
}

public enum SegmentPlanner {
    /// While the file is still one segment, the first split starts at most this many
    /// "steps" past what has arrived, so the beginning of the file fills in roughly in
    /// order (useful for previewing media). Values follow IDM's ChunksList::Insert.
    static let firstSplitFactor: Int64 = 10
    static let firstSplitSlack: Int64 = 11_680

    /// Dynamic segmentation: when a connection is free and no idle segment is left,
    /// split the segment with the most remaining bytes and hand its second half to the
    /// free connection. Returns the index of the new segment, or nil if nothing is
    /// worth splitting.
    public static func splitLargest(_ segments: inout [Segment], minSplitSize: Int64) -> Int? {
        guard let i = segments.indices.max(by: { segments[$0].remaining < segments[$1].remaining }) else {
            return nil
        }
        let s = segments[i]
        guard s.remaining >= 2 * minSplitSize else { return nil }
        var newStart = s.current + s.remaining / 2
        if segments.count == 1 {
            newStart = min(newStart, s.start + firstSplitFactor * (s.downloaded + firstSplitSlack))
            newStart = max(newStart, s.current + minSplitSize)
        }
        segments[i].end = newStart - 1
        segments.append(Segment(start: newStart, end: s.end))
        return segments.count - 1
    }
}
