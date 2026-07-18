import Foundation

/// Supported SASI/HDF layout classes (design.md G-HDF-a/b).
public enum HdfLayoutClass: String, Equatable, Sendable {
    /// Headerless; partition table at 0x400; start LBA in 256-byte units.
    case sasiX68k256 = "hdf-sasi-x68k-256"
    case unknown
}

/// SASI hard disk image (`.hdf`).
public final class HdfImage: @unchecked Sendable {
    public let data: Data
    public let layoutClass: HdfLayoutClass
    public let partitions: [PartitionEntry]

    /// XM6 classic fixed sizes (bytes).
    public static let xm6FixedSizes: Set<Int> = [
        0x9F_5400, // 10MB
        0x13C_9800, // 20MB
        0x279_3000, // 40MB
    ]

    public init(data: Data) throws {
        self.data = data
        let classified = Self.classify(data: data)
        self.layoutClass = classified
        guard classified == .sasiX68k256 else {
            throw X68Error.unsupported(
                "Unsupported HDF layout class '\(classified.rawValue)' (only hdf-sasi-x68k-256 is mountable)"
            )
        }
        self.partitions = try PartitionTable.parse(
            data: data,
            at: PartitionTable.hdfSasiOffset,
            unitBytes: 256
        )
        guard !partitions.isEmpty else {
            throw X68Error.format("No partitions found in HDF image")
        }
    }

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data)
    }

    public static func classify(data: Data) -> HdfLayoutClass {
        // Must not look like X68SCSI1 HDS.
        if data.count >= 8, Data(data[0..<8]) == SxSIHeader.magic {
            return .unknown
        }
        guard data.count >= 0x410 else { return .unknown }
        guard Data(data[0x400..<0x404]) == PartitionTable.magic else {
            return .unknown
        }
        // Expect at least one partition-like name at +0x10
        return .sasiX68k256
    }

    public func openVolume(index: Int = 0) throws -> HddVolume {
        guard index >= 0, index < partitions.count else {
            throw X68Error.filesystem("Partition index out of range: \(index)")
        }
        return try HddVolume(imageData: data, partition: partitions[index])
    }
}
