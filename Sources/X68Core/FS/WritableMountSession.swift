import Foundation

/// Opened experimental-write session (HDS/HDF or XDF/DIM).
public enum WritableSession: @unchecked Sendable {
    case hdd(WritableHddSession)
    case floppy(WritableFloppySession)

    public static func open(
        url: URL,
        partitionIndex: Int = 0,
        requireCleanFsck: Bool = true,
        createBackup: Bool = true,
        lockImage: Bool = true
    ) throws -> WritableSession {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        switch ImageDetector.detect(data: data).kind {
        case .hds, .hdf:
            let s = try WritableHddSession.open(
                url: url,
                partitionIndex: partitionIndex,
                requireCleanFsck: requireCleanFsck,
                createBackup: createBackup,
                lockImage: lockImage
            )
            return .hdd(s)
        case .xdf, .dim:
            let s = try WritableFloppySession.open(
                url: url,
                requireCleanFsck: requireCleanFsck,
                createBackup: createBackup,
                lockImage: lockImage
            )
            return .floppy(s)
        case .unknown:
            throw X68Error.unsupported("Unknown disk image format")
        }
    }

    public func listEntries(path: HumanPath = HumanPath()) throws -> [VolumeEntry] {
        switch self {
        case .hdd(let s): return try s.listEntries(path: path)
        case .floppy(let s): return try s.listEntries(path: path)
        }
    }

    public func readFile(path: HumanPath) throws -> Data {
        switch self {
        case .hdd(let s): return try s.readFile(path: path)
        case .floppy(let s): return try s.readFile(path: path)
        }
    }

    public func writeFile(path: HumanPath, contents: Data, overwrite: Bool = true) throws {
        switch self {
        case .hdd(let s): _ = try s.writeFile(path: path, contents: contents, overwrite: overwrite)
        case .floppy(let s): try s.writeFile(path: path, contents: contents, overwrite: overwrite)
        }
    }

    public func createFile(path: HumanPath) throws {
        try writeFile(path: path, contents: Data(), overwrite: true)
    }

    public func deleteFile(path: HumanPath) throws {
        switch self {
        case .hdd(let s): _ = try s.deleteFile(path: path)
        case .floppy(let s): try s.deleteFile(path: path)
        }
    }

    public func mkdir(path: HumanPath) throws {
        switch self {
        case .hdd(let s): _ = try s.mkdir(path: path)
        case .floppy(let s): try s.mkdir(path: path)
        }
    }

    public func truncate(path: HumanPath, size: Int) throws {
        switch self {
        case .hdd(let s): _ = try s.truncate(path: path, size: size)
        case .floppy(let s): try s.truncate(path: path, size: size)
        }
    }

    public func rename(from: HumanPath, to: HumanPath) throws {
        switch self {
        case .hdd(let s): try s.rename(from: from, to: to)
        case .floppy(let s): try s.rename(from: from, to: to)
        }
    }

    public func spaceInfo() throws -> VolumeSpaceInfo {
        switch self {
        case .hdd(let s): return try s.spaceInfo()
        case .floppy(let s): return try s.spaceInfo()
        }
    }

    public func fsck() throws -> FsckReport {
        switch self {
        case .hdd(let s): return try s.fsck()
        case .floppy(let s): return try s.fsck()
        }
    }
}
