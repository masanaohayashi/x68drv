import Foundation
import Darwin

/// In-memory XDF/DIM write session for experimental FUSE / helper paths.
public final class WritableFloppySession: @unchecked Sendable {
    public private(set) var imageData: Data
    public let imageURL: URL?

    private var volume: FloppyVolume
    private let lock = NSLock()
    private var madeBackup = false
    private var imageFD: Int32 = -1
    private var shouldBackup: Bool

    public static func open(
        url: URL,
        requireCleanFsck: Bool = true,
        createBackup: Bool = true,
        lockImage: Bool = true
    ) throws -> WritableFloppySession {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let session = try WritableFloppySession(imageData: data, imageURL: url)
        if requireCleanFsck {
            let report = try session.volume.fsck()
            guard report.isClean else {
                let detail = report.issues.prefix(3).map(\.message).joined(separator: "; ")
                throw X68Error.filesystem("fsck not clean (refusing write): \(detail)")
            }
        }
        if lockImage {
            try session.acquireExclusiveLock(url: url)
        }
        session.shouldBackup = createBackup
        return session
    }

    public init(imageData: Data, imageURL: URL? = nil) throws {
        let detection = ImageDetector.detect(data: imageData)
        guard detection.kind == .xdf || detection.kind == .dim else {
            throw X68Error.unsupported(
                "WritableFloppySession supports XDF/DIM only (got \(detection.kind.rawValue))"
            )
        }
        self.imageData = imageData
        self.imageURL = imageURL
        self.volume = try FloppyVolume(imageData: imageData, detection: detection)
        self.shouldBackup = false
    }

    deinit {
        if imageFD >= 0 {
            var fl = Self.makeFlock(type: F_UNLCK)
            _ = fcntl(imageFD, F_SETLK, &fl)
            Darwin.close(imageFD)
            imageFD = -1
        }
    }

    private static func makeFlock(type: Int32) -> flock {
        var fl = flock()
        fl.l_start = 0
        fl.l_len = 0
        fl.l_pid = 0
        fl.l_type = Int16(type)
        fl.l_whence = Int16(SEEK_SET)
        return fl
    }

    public func listEntries(path: HumanPath = HumanPath()) throws -> [VolumeEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try volume.listEntries(path: path)
    }

    public func readFile(path: HumanPath) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try volume.readFile(path: path)
    }

    public func fsck() throws -> FsckReport {
        lock.lock()
        defer { lock.unlock() }
        return try volume.fsck()
    }

    public func spaceInfo() throws -> VolumeSpaceInfo {
        lock.lock()
        defer { lock.unlock() }
        return try volume.spaceInfo()
    }

    public func writeFile(path: HumanPath, contents: Data, overwrite: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        let (mutated, _) = try FloppyInject.injectFile(
            imageData: imageData,
            path: path,
            contents: contents,
            overwrite: overwrite
        )
        try apply(mutated)
    }

    public func deleteFile(path: HumanPath) throws {
        lock.lock()
        defer { lock.unlock() }
        let (mutated, _) = try FloppyInject.deleteFile(imageData: imageData, path: path)
        try apply(mutated)
    }

    public func mkdir(path: HumanPath) throws {
        guard let leaf = path.components.last else {
            throw X68Error.filesystem("Empty mkdir path")
        }
        let parent = HumanPath(components: Array(path.components.dropLast()))
        lock.lock()
        defer { lock.unlock() }
        let (mutated, _) = try FloppyInject.mkdir(
            imageData: imageData,
            parentPath: parent,
            name: leaf
        )
        try apply(mutated)
    }

    public func rename(from: HumanPath, to: HumanPath) throws {
        lock.lock()
        defer { lock.unlock() }
        let mutated = try FloppyInject.renameFile(imageData: imageData, from: from, to: to)
        try apply(mutated)
    }

    public func truncate(path: HumanPath, size: Int) throws {
        guard size >= 0 else {
            throw X68Error.filesystem("Negative truncate size")
        }
        lock.lock()
        let existing: Data?
        do {
            existing = try volume.readFile(path: path)
        } catch {
            existing = nil
        }
        lock.unlock()

        var data = existing ?? Data()
        if data.count > size {
            data = data.prefix(size)
        } else if data.count < size {
            data.append(Data(count: size - data.count))
        }
        try writeFile(path: path, contents: data, overwrite: true)
    }

    private func apply(_ mutated: Data) throws {
        imageData = mutated
        volume = try FloppyVolume(imageData: imageData)
        try persistLocked()
    }

    private func persistLocked() throws {
        guard let imageURL else { return }
        if shouldBackup, !madeBackup {
            try Self.bestEffortBackup(of: imageURL)
            madeBackup = true
        }
        try Self.atomicWrite(imageData, to: imageURL)
    }

    private func acquireExclusiveLock(url: URL) throws {
        let fd = Darwin.open(url.path, O_RDWR)
        guard fd >= 0 else {
            throw X68Error.io("Cannot open image for exclusive lock: \(url.path)")
        }
        var fl = Self.makeFlock(type: F_WRLCK)
        if fcntl(fd, F_SETLK, &fl) != 0 {
            Darwin.close(fd)
            throw X68Error.io("Image is locked by another process: \(url.lastPathComponent)")
        }
        imageFD = fd
    }

    private static func bestEffortBackup(of url: URL) throws {
        let bak = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".x68drv-bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: bak.path) {
            try? fm.removeItem(at: bak)
        }
        if Darwin.clonefile(url.path, bak.path, 0) == 0 {
            return
        }
        try fm.copyItem(at: url, to: bak)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).x68drv-w-\(UUID().uuidString).tmp"
        )
        try data.write(to: tmp, options: [.atomic])
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
