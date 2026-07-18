import Foundation

/// SCSI / SxSI hard disk image (`.hds`).
public final class HdsImage: @unchecked Sendable {
    public let data: Data
    public let header: SxSIHeader
    public let partitions: [PartitionEntry]

    public init(data: Data) throws {
        self.data = data
        self.header = try SxSIHeader.parse(data)
        self.partitions = try PartitionTable.parse(data: data)
        guard !partitions.isEmpty else {
            throw X68Error.format("No partitions found in HDS image")
        }
    }

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data)
    }

    public func openVolume(index: Int = 0) throws -> HddVolume {
        guard index >= 0, index < partitions.count else {
            throw X68Error.filesystem("Partition index out of range: \(index)")
        }
        return try HddVolume(imageData: data, partition: partitions[index])
    }
}
