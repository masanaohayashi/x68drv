import Foundation
import Darwin

/// In-memory HDS/HDF write session for experimental FUSE / helper paths.
///
/// Mutates a full image buffer via `HddInject` (ordered flush), then optionally
/// persists to disk. **Not** product UI write — opt-in only.
public final class WritableHddSession: @unchecked Sendable {
    public private(set) var imageData: Data
    public let imageURL: URL?
    public let partitionIndex: Int
    public private(set) var partition: PartitionEntry

    private var volume: HddVolume
    private let lock = NSLock()
    private var madeBackup = false
    private var imageFD: Int32 = -1

    public var isWritable: Bool { true }

    /// Open HDS/HDF for experimental write.
    ///
    /// - Parameters:
    ///   - url: Image path (held exclusively when `lockImage` is true).
    ///   - partitionIndex: Partition to mutate.
    ///   - requireCleanFsck: Reject if RO fsck finds issues.
    ///   - createBackup: Best-effort `.x68drv-bak` beside the image before first persist.
    ///   - lockImage: `flock(LOCK_EX)` on the image file.
    public static func open(
        url: URL,
        partitionIndex: Int = 0,
        requireCleanFsck: Bool = true,
        createBackup: Bool = true,
        lockImage: Bool = true
    ) throws -> WritableHddSession {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let session = try WritableHddSession(
            imageData: data,
            imageURL: url,
            partitionIndex: partitionIndex
        )
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

    /// In-memory only (tests).
    public init(imageData: Data, imageURL: URL? = nil, partitionIndex: Int = 0) throws {
        let detection = ImageDetector.detect(data: imageData)
        guard detection.kind == .hds || detection.kind == .hdf else {
            throw X68Error.unsupported(
                "WritableHddSession supports HDS/HDF only (got \(detection.kind.rawValue))"
            )
        }
        self.imageData = imageData
        self.imageURL = imageURL
        self.partitionIndex = partitionIndex
        self.partition = try Self.partitionEntry(data: imageData, index: partitionIndex)
        self.volume = try HddVolume(imageData: imageData, partition: self.partition)
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

    private var shouldBackup: Bool

    // MARK: - Read (volume)

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

    public func lookupEntry(path: HumanPath) throws -> VolumeEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let leaf = path.components.last else { return nil }
        let parent = HumanPath(components: Array(path.components.dropLast()))
        let entries = try volume.listEntries(path: parent)
        return entries.first {
            $0.name.stem.uppercased() == leaf.stem.uppercased()
                && $0.name.ext.uppercased() == leaf.ext.uppercased()
        }
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

    // MARK: - Write ops

    /// Create empty file or overwrite with contents (inject ordered flush).
    @discardableResult
    public func writeFile(path: HumanPath, contents: Data, overwrite: Bool = true) throws -> HddInject.Result {
        lock.lock()
        defer { lock.unlock() }
        let (mutated, result) = try HddInject.injectFile(
            imageData: imageData,
            partition: partition,
            path: path,
            contents: contents,
            overwrite: overwrite
        )
        try apply(mutated)
        return result
    }

    /// Ensure path exists as empty file (create). Fails if directory; overwrites file if present.
    @discardableResult
    public func createFile(path: HumanPath) throws -> HddInject.Result {
        try writeFile(path: path, contents: Data(), overwrite: true)
    }

    @discardableResult
    public func deleteFile(path: HumanPath) throws -> HddInject.DeleteResult {
        lock.lock()
        defer { lock.unlock() }
        let (mutated, result) = try HddInject.deleteFile(
            imageData: imageData,
            partition: partition,
            path: path
        )
        try apply(mutated)
        return result
    }

    /// `path` last component is the directory name; parents must exist.
    @discardableResult
    public func mkdir(path: HumanPath) throws -> HddInject.MkdirResult {
        guard let leaf = path.components.last else {
            throw X68Error.filesystem("Empty mkdir path")
        }
        let parent = HumanPath(components: Array(path.components.dropLast()))
        lock.lock()
        defer { lock.unlock() }
        let (mutated, result) = try HddInject.mkdir(
            imageData: imageData,
            partition: partition,
            parentPath: parent,
            name: leaf
        )
        try apply(mutated)
        return result
    }

    /// Truncate existing file (or create empty if missing and size == 0).
    @discardableResult
    public func truncate(path: HumanPath, size: Int) throws -> HddInject.Result {
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
        return try writeFile(path: path, contents: data, overwrite: true)
    }

    /// Force persist current buffer to `imageURL` (no-op if in-memory only).
    public func persist() throws {
        lock.lock()
        defer { lock.unlock() }
        try persistLocked()
    }

    // MARK: - private

    private func apply(_ mutated: Data) throws {
        imageData = mutated
        // Partition offsets are stable for HDS/HDF layout; re-resolve for safety.
        partition = try Self.partitionEntry(data: imageData, index: partitionIndex)
        volume = try HddVolume(imageData: imageData, partition: partition)
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
        // Prefer clonefile when available (APFS).
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

    private static func partitionEntry(data: Data, index: Int) throws -> PartitionEntry {
        let detection = ImageDetector.detect(data: data)
        switch detection.kind {
        case .hds:
            let parts = try HdsImage(data: data).partitions
            guard index >= 0, index < parts.count else {
                throw X68Error.filesystem("Partition index out of range: \(index)")
            }
            return parts[index]
        case .hdf:
            let parts = try HdfImage(data: data).partitions
            guard index >= 0, index < parts.count else {
                throw X68Error.filesystem("Partition index out of range: \(index)")
            }
            return parts[index]
        default:
            throw X68Error.unsupported(
                "WritableHddSession supports HDS/HDF only (got \(detection.kind.rawValue))"
            )
        }
    }
}
