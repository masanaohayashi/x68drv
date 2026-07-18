import Foundation

/// Unified entry point for opening host disk image files.
public struct DiskImage: Sendable {
    public let url: URL?
    public let data: Data
    public let detection: DetectionResult

    public init(data: Data, url: URL? = nil) {
        self.data = data
        self.url = url
        self.detection = ImageDetector.detect(data: data)
    }

    public static func open(url: URL) throws -> DiskImage {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return DiskImage(data: data, url: url)
    }

    public static func open(data: Data) -> DiskImage {
        DiskImage(data: data, url: nil)
    }

    /// Open the default volume (partition 0 for HDS, the only volume for floppies).
    public func openDefaultVolume() throws -> any ReadableVolume {
        try openVolume(partitionIndex: 0)
    }

    /// Open a volume. `partitionIndex` is ignored for single-volume floppies.
    public func openVolume(partitionIndex: Int) throws -> any ReadableVolume {
        switch detection.kind {
        case .xdf, .dim:
            return try FloppyVolume(imageData: data, detection: detection)
        case .hds:
            let hds = try HdsImage(data: data)
            return try hds.openVolume(index: partitionIndex)
        case .hdf:
            throw X68Error.unsupported(
                "HDF open not enabled in this build (Phase 7); class detection only"
            )
        case .unknown:
            throw X68Error.unsupported("Unknown disk image format")
        }
    }

    /// Partition count (1 for floppies).
    public func partitionCount() throws -> Int {
        switch detection.kind {
        case .xdf, .dim:
            return 1
        case .hds:
            return try HdsImage(data: data).partitions.count
        case .hdf, .unknown:
            return 0
        }
    }

    public func partitionEntries() throws -> [PartitionEntry] {
        switch detection.kind {
        case .hds:
            return try HdsImage(data: data).partitions
        default:
            return []
        }
    }
}

// Ensure class types conform.
extension FloppyVolume: ReadableVolume {}
extension HddVolume: ReadableVolume {}
