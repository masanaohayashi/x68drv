import Foundation

/// Common list entry for any volume type.
public struct VolumeEntry: Equatable, Sendable {
    public var name: HumanFileName
    public var isDirectory: Bool
    public var size: UInt32

    public init(name: HumanFileName, isDirectory: Bool, size: UInt32) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// Capacity report for FUSE `statfs` / Finder free-space UI.
public struct VolumeSpaceInfo: Equatable, Sendable {
    /// Preferred I/O / allocation unit (usually bytes per cluster).
    public var blockSize: UInt64
    public var totalBlocks: UInt64
    public var freeBlocks: UInt64

    public init(blockSize: UInt64, totalBlocks: UInt64, freeBlocks: UInt64) {
        self.blockSize = blockSize
        self.totalBlocks = totalBlocks
        self.freeBlocks = freeBlocks
    }

    public var freeBytes: UInt64 { freeBlocks * blockSize }
    public var totalBytes: UInt64 { totalBlocks * blockSize }
}

/// Read-only volume operations used by the app and tools.
public protocol ReadableVolume: AnyObject {
    func listEntries(path: HumanPath) throws -> [VolumeEntry]
    func readFile(path: HumanPath) throws -> Data
    func export(path: HumanPath, to url: URL) throws
    func fsck() throws -> FsckReport
    /// Free/total space for host UI. Default: unknown (0 free).
    func spaceInfo() throws -> VolumeSpaceInfo
}

extension ReadableVolume {
    public func spaceInfo() throws -> VolumeSpaceInfo {
        VolumeSpaceInfo(blockSize: 1024, totalBlocks: 0, freeBlocks: 0)
    }
}

extension ReadableVolume {
    public func listEntries() throws -> [VolumeEntry] {
        try listEntries(path: HumanPath())
    }
}
