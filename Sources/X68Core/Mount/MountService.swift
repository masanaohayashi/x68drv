import Foundation

public enum MountBackend: String, Equatable, Sendable {
    /// Live FUSE-T / macFUSE volume (shows under /Volumes).
    case fuse
    /// Materialize files under Application Support (fallback without FUSE).
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

/// Coordinates mounting: **FUSE when available**, otherwise snapshot folders.
public final class MountService: @unchecked Sendable {
    public static let shared = MountService()

    public private(set) var mounts: [MountRecord] = []
    public var maxMounts: Int = MountPointNamer.maxMounts

    private let fileManager: FileManager
    private let mountsRoot: URL
    private let lock = NSLock()
    private var fuseProcesses: [UUID: Process] = [:]

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

    /// Mount image. Prefers FUSE when FUSE-T/macFUSE is present and helper runs;
    /// otherwise uses snapshot export under Application Support.
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

        // Validate image early
        let disk = try DiskImage.open(url: standardized)
        _ = try disk.openVolume(partitionIndex: partitionIndex)

        let fuse = FuseAvailability.probe(fileManager: fileManager)
        var record: MountRecord?

        if preferFuse, fuse.isAvailable, let helper = helperExecutable() {
            do {
                record = try mountWithFuse(
                    helper: helper,
                    imageURL: standardized,
                    partitionIndex: partitionIndex
                )
            } catch {
                // Fall through to snapshot
                fputs("FUSE mount failed (\(error)); falling back to snapshot\n", stderr)
            }
        }

        if record == nil {
            record = try mountWithSnapshot(
                imageURL: standardized,
                partitionIndex: partitionIndex,
                disk: disk
            )
        }

        let finalRecord = record!
        mounts.append(finalRecord)
        return finalRecord
    }

    public func eject(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = mounts.firstIndex(where: { $0.id == id }) else {
            throw X68Error.io("Mount not found")
        }
        let record = mounts[idx]
        try tearDown(record)
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
        let procs = fuseProcesses
        mounts = []
        fuseProcesses = [:]
        lock.unlock()
        var firstError: Error?
        for record in copy {
            if let p = procs[record.id], p.isRunning {
                p.terminate()
            }
            do {
                try tearDownFiles(record)
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

    // MARK: - backends

    private func mountWithFuse(
        helper: URL,
        imageURL: URL,
        partitionIndex: Int
    ) throws -> MountRecord {
        let leafBase = MountPointNamer.sanitizeBaseName(imageURL.lastPathComponent)
        let partSuffix = partitionIndex == 0 ? "" : "-p\(partitionIndex)"
        var leaf = "x68drv-\(leafBase)\(partSuffix)"
        var mountURL = URL(fileURLWithPath: "/Volumes/\(leaf)")
        var n = 1
        while fileManager.fileExists(atPath: mountURL.path), n < 50 {
            leaf = "x68drv-\(leafBase)\(partSuffix)-\(n)"
            mountURL = URL(fileURLWithPath: "/Volumes/\(leaf)")
            n += 1
        }

        // Create empty mount point (FUSE-T will attach)
        try? fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = helper
        process.arguments = [
            imageURL.path,
            mountURL.path,
            "--partition", "\(partitionIndex)",
            "-o", "volname=\(imageURL.lastPathComponent),rdonly,local,allow_other",
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // Wait until mount is live (or process dies)
        let deadline = Date().addingTimeInterval(8)
        var mounted = false
        while Date() < deadline {
            if !process.isRunning {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                try? fileManager.removeItem(at: mountURL)
                throw X68Error.io("FUSE helper exited early: \(errText)")
            }
            // Check for a successful mount: path exists and is not empty or resource fork
            if isLikelyMounted(mountURL) {
                mounted = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if !mounted {
            process.terminate()
            try? fileManager.removeItem(at: mountURL)
            throw X68Error.io("Timed out waiting for FUSE mount at \(mountURL.path)")
        }

        let record = MountRecord(
            sourceURL: imageURL,
            mountURL: mountURL,
            partitionIndex: partitionIndex,
            backend: .fuse,
            displayName: imageURL.lastPathComponent
        )
        fuseProcesses[record.id] = process
        return record
    }

    private func isLikelyMounted(_ url: URL) -> Bool {
        // On success, getattr("/") works and mount table lists it.
        var statBuf = stat()
        if stat(url.path, &statBuf) != 0 { return false }
        // Snapshot dirs also exist — for FUSE, process is running and path is mountpoint.
        // Check mntfromname via getmntinfo if needed; simple check: can readdir
        if let contents = try? fileManager.contentsOfDirectory(atPath: url.path) {
            // Empty root is valid; existence of directory after helper started is enough if process lives.
            _ = contents
            return true
        }
        return false
    }

    private func mountWithSnapshot(
        imageURL: URL,
        partitionIndex: Int,
        disk: DiskImage
    ) throws -> MountRecord {
        let volume = try disk.openVolume(partitionIndex: partitionIndex)
        try fileManager.createDirectory(at: mountsRoot, withIntermediateDirectories: true)
        let existingNames = Set(mounts.map { $0.mountURL.lastPathComponent })
        let mountURL = try MountPointNamer.allocate(
            baseDirectory: mountsRoot,
            imageFileName: imageURL.lastPathComponent,
            partitionIndex: partitionIndex,
            existing: existingNames,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: mountURL.path) {
            try fileManager.removeItem(at: mountURL)
        }
        try SnapshotExporter.exportTree(volume: volume, to: mountURL, fileManager: fileManager)
        try? fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mountURL.path)

        return MountRecord(
            sourceURL: imageURL,
            mountURL: mountURL,
            partitionIndex: partitionIndex,
            backend: .snapshot,
            displayName: imageURL.lastPathComponent
        )
    }

    private func tearDown(_ record: MountRecord) throws {
        if let proc = fuseProcesses.removeValue(forKey: record.id), proc.isRunning {
            proc.terminate()
            // Give FUSE-T a moment; also umount
            let umount = Process()
            umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            umount.arguments = [record.mountURL.path]
            try? umount.run()
            umount.waitUntilExit()
        }
        try tearDownFiles(record)
    }

    private func tearDownFiles(_ record: MountRecord) throws {
        switch record.backend {
        case .snapshot:
            if fileManager.fileExists(atPath: record.mountURL.path) {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: record.mountURL.path)
                try fileManager.removeItem(at: record.mountURL)
            }
        case .fuse:
            if fileManager.fileExists(atPath: record.mountURL.path) {
                // Unmount should remove contents; clean empty dir if left
                try? fileManager.removeItem(at: record.mountURL)
            }
        }
    }

    public func helperExecutable() -> URL? {
        // 1) Next to unit-test / swift run products
        let buildCandidates = [
            // swift run debug
            FileManager.default.currentDirectoryPath + "/.build/debug/x68mount-helper",
            FileManager.default.currentDirectoryPath + "/.build/arm64-apple-macosx/debug/x68mount-helper",
            FileManager.default.currentDirectoryPath + "/.build/release/x68mount-helper",
        ]
        for path in buildCandidates {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // 2) Inside app bundle Helpers/
        if let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/x68mount-helper", isDirectory: false) as URL? {
            if fileManager.isExecutableFile(atPath: helpers.path) { return helpers }
        }
        if let macOS = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("x68mount-helper") {
            if fileManager.isExecutableFile(atPath: macOS.path) { return macOS }
        }
        // 3) PATH
        if let path = findInPath("x68mount-helper") {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func findInPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
