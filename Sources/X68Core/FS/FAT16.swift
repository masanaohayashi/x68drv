import Foundation

/// Big-endian FAT16 chain walker (Human68k HDD volumes).
public struct FAT16BE: Sendable {
    public let table: Data
    public let maxClusters: Int

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
