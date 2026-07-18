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

/// Read-only volume operations used by the app and tools.
public protocol ReadableVolume: AnyObject {
    func listEntries(path: HumanPath) throws -> [VolumeEntry]
    func readFile(path: HumanPath) throws -> Data
    func export(path: HumanPath, to url: URL) throws
    func fsck() throws -> FsckReport
}

extension ReadableVolume {
    public func listEntries() throws -> [VolumeEntry] {
        try listEntries(path: HumanPath())
    }
}
