import Foundation

/// Little-endian FAT12 chain walker / mutator (Human68k floppy volumes).
public struct FAT12: Sendable {
    public private(set) var table: Data
    public let maxClusters: Int

    public static let endOfChain = 0xFFF
    public static let free = 0

    public init(table: Data, maxClusters: Int) {
        self.table = table
        self.maxClusters = maxClusters
    }

    public func entry(cluster: Int) throws -> Int {
        guard cluster >= 0, cluster <= maxClusters else {
            throw X68Error.filesystem("FAT12 cluster out of range: \(cluster)")
        }
        let index = (cluster * 3) / 2
        guard index + 1 < table.count else {
            throw X68Error.filesystem("FAT12 table truncated at cluster \(cluster)")
        }
        let b0 = Int(table[index])
        let b1 = Int(table[index + 1])
        if cluster & 1 == 0 {
            return b0 | ((b1 & 0x0F) << 8)
        } else {
            return (b0 >> 4) | (b1 << 4)
        }
    }

    public mutating func setEntry(cluster: Int, value: Int) throws {
        guard cluster >= 0, cluster <= maxClusters else {
            throw X68Error.filesystem("FAT12 cluster out of range: \(cluster)")
        }
        let index = (cluster * 3) / 2
        guard index + 1 < table.count else {
            throw X68Error.filesystem("FAT12 table truncated at cluster \(cluster)")
        }
        let v = value & 0xFFF
        if cluster & 1 == 0 {
            table[index] = UInt8(v & 0xFF)
            table[index + 1] = (table[index + 1] & 0xF0) | UInt8((v >> 8) & 0x0F)
        } else {
            table[index] = (table[index] & 0x0F) | UInt8((v << 4) & 0xF0)
            table[index + 1] = UInt8((v >> 4) & 0xFF)
        }
    }

    public func freeClusters(limit: Int) throws -> [Int] {
        var result: [Int] = []
        guard limit > 0, maxClusters >= 2 else { return result }
        for c in 2...maxClusters {
            if try entry(cluster: c) == Self.free {
                result.append(c)
                if result.count >= limit { break }
            }
        }
        return result
    }

    public func countFreeClusters() throws -> Int {
        guard maxClusters >= 2 else { return 0 }
        var n = 0
        for c in 2...maxClusters {
            if try entry(cluster: c) == Self.free { n += 1 }
        }
        return n
    }

    public var dataClusterCount: Int {
        max(0, maxClusters - 1)
    }

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

    public mutating func freeChain(_ chain: [Int]) throws {
        for c in chain {
            try setEntry(cluster: c, value: Self.free)
        }
    }

    /// Walk cluster chain starting at `start`. Stops on EOF (>= 0xFF8).
    public func chain(from start: Int, maxLength: Int = 4096) throws -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        var current = start
        while current >= 2 && current < 0xFF8 {
            if seen.contains(current) {
                throw X68Error.filesystem("FAT12 cycle detected at cluster \(current)")
            }
            if result.count >= maxLength {
                throw X68Error.limit("FAT12 chain exceeds \(maxLength) clusters")
            }
            seen.insert(current)
            result.append(current)
            current = try entry(cluster: current)
        }
        if current >= 0xFF8 || current == 0 {
            return result
        }
        if current == 0xFF7 {
            throw X68Error.filesystem("FAT12 bad cluster in chain")
        }
        return result
    }
}
