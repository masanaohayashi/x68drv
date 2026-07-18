import Foundation

/// Big-endian FAT16 chain walker / mutator (Human68k HDD volumes).
public struct FAT16BE: Sendable {
    public private(set) var table: Data
    public let maxClusters: Int

    /// End-of-chain marker (0xFFFF).
    public static let endOfChain = 0xFFFF
    /// Free cluster value.
    public static let free = 0

    public init(table: Data, maxClusters: Int) {
        self.table = table
        self.maxClusters = maxClusters
    }

    public func entry(cluster: Int) throws -> Int {
        guard cluster >= 0, cluster <= maxClusters else {
            throw X68Error.filesystem("FAT16 cluster out of range: \(cluster)")
        }
        let index = cluster * 2
        guard index + 1 < table.count else {
            throw X68Error.filesystem("FAT16 table truncated at cluster \(cluster)")
        }
        return Int(try Endian.readUInt16BE(table, at: index))
    }

    /// Little-endian read of the same slot (for wrong-endian negative tests).
    public func entryLE(cluster: Int) throws -> Int {
        let index = cluster * 2
        guard index + 1 < table.count else {
            throw X68Error.filesystem("FAT16 table truncated")
        }
        return Int(try Endian.readUInt16LE(table, at: index))
    }

    public mutating func setEntry(cluster: Int, value: Int) throws {
        guard cluster >= 0, cluster <= maxClusters else {
            throw X68Error.filesystem("FAT16 cluster out of range: \(cluster)")
        }
        let index = cluster * 2
        guard index + 1 < table.count else {
            throw X68Error.filesystem("FAT16 table truncated at cluster \(cluster)")
        }
        try Endian.writeUInt16BE(UInt16(value & 0xFFFF), to: &table, at: index)
    }

    /// Free cluster numbers in [2...maxClusters] that currently hold 0.
    public func freeClusters(limit: Int) throws -> [Int] {
        var result: [Int] = []
        guard limit > 0 else { return result }
        for c in 2...maxClusters {
            if try entry(cluster: c) == Self.free {
                result.append(c)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Count free data clusters (cluster indices 2...maxClusters with value 0).
    public func countFreeClusters() throws -> Int {
        guard maxClusters >= 2 else { return 0 }
        var n = 0
        for c in 2...maxClusters {
            if try entry(cluster: c) == Self.free { n += 1 }
        }
        return n
    }

    /// Number of addressable data clusters (indices 2...maxClusters inclusive).
    public var dataClusterCount: Int {
        max(0, maxClusters - 1)
    }

    /// Allocate a chain of `count` free clusters; last entry = EOF.
    /// Returns the list of clusters (length `count`).
    public mutating func allocateChain(count: Int) throws -> [Int] {
        guard count > 0 else {
            throw X68Error.filesystem("allocateChain requires count > 0")
        }
        let free = try freeClusters(limit: count)
        guard free.count == count else {
            throw X68Error.limit("Disk full: need \(count) free clusters, have \(free.count)")
        }
        for i in 0..<count {
            let next = (i + 1 < count) ? free[i + 1] : Self.endOfChain
            try setEntry(cluster: free[i], value: next)
        }
        return free
    }

    /// Mark every cluster in `chain` as free (0).
    public mutating func freeChain(_ chain: [Int]) throws {
        for c in chain {
            try setEntry(cluster: c, value: Self.free)
        }
    }

    public func chain(from start: Int, maxLength: Int = 65536) throws -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        var current = start
        // EOF: 0xFFF8...0xFFFF
        while current >= 2 && current < 0xFFF8 {
            if seen.contains(current) {
                throw X68Error.filesystem("FAT16 cycle detected at cluster \(current)")
            }
            if result.count >= maxLength {
                throw X68Error.limit("FAT16 chain exceeds \(maxLength) clusters")
            }
            seen.insert(current)
            result.append(current)
            current = try entry(cluster: current)
        }
        if current >= 0xFFF8 || current == 0 {
            return result
        }
        if current == 0xFFF7 {
            throw X68Error.filesystem("FAT16 bad cluster in chain")
        }
        return result
    }
}
