import Foundation

public enum MountBackend: String, Equatable, Sendable {
    /// Live FUSE mount (future helper). Not used until FUSE stack + helper are present.
    case fuse
    /// Materialize files under Application Support and open in Finder.
    case snapshot
}

public struct MountRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceURL: URL
    public var mountURL: URL
    public var partitionIndex: Int
    public var backend: MountBackend
    public var displayName: String

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        mountURL: URL,
        partitionIndex: Int,
        backend: MountBackend,
        displayName: String
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.mountURL = mountURL
        self.partitionIndex = partitionIndex
        self.backend = backend
        self.displayName = displayName
    }
}

/// Coordinates mounting disk images for the app (snapshot backend for v0.1 without FUSE helper).
public final class MountService: @unchecked Sendable {
    public static let shared = MountService()

    public private(set) var mounts: [MountRecord] = []
    public var maxMounts: Int = MountPointNamer.maxMounts

    private let fileManager: FileManager
    private let mountsRoot: URL
    private let lock = NSLock()

    public init(fileManager: FileManager = .default, mountsRoot: URL? = nil) {
        self.fileManager = fileManager
        if let mountsRoot {
            self.mountsRoot = mountsRoot
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.mountsRoot = base
                .appendingPathComponent("x68drv", isDirectory: true)
                .appendingPathComponent("Mounts", isDirectory: true)
        }
    }

    public func fuseStatus() -> FuseAvailability {
        FuseAvailability.probe(fileManager: fileManager)
    }

    /// Mount image at `url`. Reuses existing mount for same source+partition.
    @discardableResult
    public func mount(
        url: URL,
        partitionIndex: Int = 0,
        preferFuse: Bool = true
    ) throws -> MountRecord {
        lock.lock()
        defer { lock.unlock() }

        let standardized = url.standardizedFileURL
        if let existing = mounts.first(where: {
            $0.sourceURL.standardizedFileURL == standardized && $0.partitionIndex == partitionIndex
        }) {
            return existing
        }

        guard mounts.count < maxMounts else {
            throw X68Error.limit("Maximum of \(maxMounts) mounts reached")
        }

        let disk = try DiskImage.open(url: standardized)
        let volume = try disk.openVolume(partitionIndex: partitionIndex)

        // Prefer FUSE when available *and* helper exists; else snapshot.
        let backend: MountBackend
        let fuse = FuseAvailability.probe(fileManager: fileManager)
        if preferFuse, fuse.isAvailable, helperExecutable() != nil {
            // Helper path reserved for later; fall through to snapshot until helper ships.
            backend = .snapshot
        } else {
            backend = .snapshot
        }

        try fileManager.createDirectory(at: mountsRoot, withIntermediateDirectories: true)
        let existingNames = Set(mounts.map { $0.mountURL.lastPathComponent })
        let mountURL = try MountPointNamer.allocate(
            baseDirectory: mountsRoot,
            imageFileName: standardized.lastPathComponent,
            partitionIndex: partitionIndex,
            existing: existingNames,
            fileManager: fileManager
        )

        switch backend {
        case .snapshot:
            if fileManager.fileExists(atPath: mountURL.path) {
                try fileManager.removeItem(at: mountURL)
            }
            try SnapshotExporter.exportTree(volume: volume, to: mountURL, fileManager: fileManager)
            // Mark snapshot read-only for the user where possible.
            try? fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mountURL.path)
        case .fuse:
            throw X68Error.unsupported("FUSE helper not yet installed in this build")
        }

        let record = MountRecord(
            sourceURL: standardized,
            mountURL: mountURL,
            partitionIndex: partitionIndex,
            backend: backend,
            displayName: standardized.lastPathComponent
        )
        mounts.append(record)
        return record
    }

    public func eject(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = mounts.firstIndex(where: { $0.id == id }) else {
            throw X68Error.io("Mount not found")
        }
        let record = mounts[idx]
        try removeMountFiles(record)
        mounts.remove(at: idx)
    }

    public func eject(sourceURL: URL, partitionIndex: Int = 0) throws {
        let std = sourceURL.standardizedFileURL
        guard let record = mounts.first(where: {
            $0.sourceURL.standardizedFileURL == std && $0.partitionIndex == partitionIndex
        }) else {
            throw X68Error.io("Mount not found for \(sourceURL.lastPathComponent)")
        }
        try eject(id: record.id)
    }

    public func ejectAll() throws {
        lock.lock()
        let copy = mounts
        mounts = []
        lock.unlock()
        var firstError: Error?
        for record in copy {
            do {
                try removeMountFiles(record)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    public func existingMount(for sourceURL: URL, partitionIndex: Int = 0) -> MountRecord? {
        let std = sourceURL.standardizedFileURL
        return mounts.first {
            $0.sourceURL.standardizedFileURL == std && $0.partitionIndex == partitionIndex
        }
    }

    private func removeMountFiles(_ record: MountRecord) throws {
        switch record.backend {
        case .snapshot:
            if fileManager.fileExists(atPath: record.mountURL.path) {
                // May be 0o555 — make writable before delete.
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: record.mountURL.path)
                try fileManager.removeItem(at: record.mountURL)
            }
        case .fuse:
            // umount helper TBD
            break
        }
    }

    private func helperExecutable() -> URL? {
        // Look next to the main app for x68mount-helper (Phase 6 full FUSE).
        if let built = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("x68mount-helper") {
            if fileManager.isExecutableFile(atPath: built.path) { return built }
        }
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("x68mount-helper")
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }
}
