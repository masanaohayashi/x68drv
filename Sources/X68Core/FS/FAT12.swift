import Foundation

/// Little-endian FAT12 chain walker with cycle / length guards.
public struct FAT12: Sendable {
    public let table: Data
    public let maxClusters: Int

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
        // Bad cluster marks etc.
        if current == 0xFF7 {
            throw X68Error.filesystem("FAT12 bad cluster in chain")
        }
        return result
    }
}
