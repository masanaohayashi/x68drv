import Foundation
import Darwin

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
    /// Snapshot (non-FUSE) export root under Application Support.
    private let mountsRoot: URL
    /// Live FUSE mountpoints (user-writable; FUSE-T shows `volname` in Finder).
    private let fuseMountsRoot: URL
    private let lock = NSLock()
    private var fuseProcesses: [UUID: Process] = [:]

    public init(fileManager: FileManager = .default, mountsRoot: URL? = nil) {
        self.fileManager = fileManager
        if let mountsRoot {
            self.mountsRoot = mountsRoot
            self.fuseMountsRoot = mountsRoot.appendingPathComponent("Fuse", isDirectory: true)
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            let app = base.appendingPathComponent("x68drv", isDirectory: true)
            self.mountsRoot = app.appendingPathComponent("Mounts", isDirectory: true)
            self.fuseMountsRoot = app.appendingPathComponent("Volumes", isDirectory: true)
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

        if preferFuse, fuse.isAvailable {
            if let helper = helperExecutable() {
                do {
                    record = try mountWithFuse(
                        helper: helper,
                        imageURL: standardized,
                        partitionIndex: partitionIndex
                    )
                } catch {
                    // Fall through to snapshot
                    fputs("x68drv: FUSE mount failed (\(error)); falling back to snapshot\n", stderr)
                }
            } else {
                fputs(
                    "x68drv: FUSE is installed but x68mount-helper was not found; falling back to snapshot\n",
                    stderr
                )
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
                try tearDownFiles(record, forceUnmount: record.backend == .fuse)
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

    /// Recover leftovers after crash / force-quit / quit without eject.
    ///
    /// - Terminates stray `x68mount-helper` processes for our mount roots
    /// - Force-unmounts anything still mounted under the FUSE root
    /// - Deletes orphan snapshot folders and empty mountpoint dirs
    ///
    /// Safe to call on every launch (in-memory mount list is empty then).
    @discardableResult
    public func reclaimOrphans() -> Int {
        lock.lock()
        // If we still have live mounts in this process, only clean *unknown* dirs.
        let livePaths = Set(mounts.map { $0.mountURL.standardizedFileURL.path })
        lock.unlock()

        var cleaned = 0
        terminateStrayHelpers()
        cleaned += reclaimDirectoryTree(at: fuseMountsRoot, livePaths: livePaths, unmountFirst: true)
        cleaned += reclaimDirectoryTree(at: mountsRoot, livePaths: livePaths, unmountFirst: false)
        return cleaned
    }

    /// Paths we manage (for diagnostics / tests).
    public var snapshotRootURL: URL { mountsRoot }
    public var fuseRootURL: URL { fuseMountsRoot }

    // MARK: - backends

    private func mountWithFuse(
        helper: URL,
        imageURL: URL,
        partitionIndex: Int
    ) throws -> MountRecord {
        // Prefer a user-writable mountpoint. Creating under /Volumes needs root on modern
        // macOS; FUSE-T still surfaces `volname` in Finder (sidebar / Desktop) via NFS.
        try fileManager.createDirectory(at: fuseMountsRoot, withIntermediateDirectories: true)

        let existingNames = Set(
            (try? fileManager.contentsOfDirectory(atPath: fuseMountsRoot.path)) ?? []
        ).union(Set(mounts.map(\.mountURL.lastPathComponent)))

        let mountURL = try MountPointNamer.allocate(
            baseDirectory: fuseMountsRoot,
            imageFileName: imageURL.lastPathComponent,
            partitionIndex: partitionIndex,
            existing: existingNames,
            fileManager: fileManager
        )
        // Fresh empty directory for the mount point
        if fileManager.fileExists(atPath: mountURL.path) {
            try fileManager.removeItem(at: mountURL)
        }
        try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)

        let volName = fuseVolumeName(for: imageURL, partitionIndex: partitionIndex)
        // noappledouble: fewer junk files; local: treat as local volume in Finder
        let fuseOpts = "volname=\(volName),rdonly,local,noappledouble,noapplexattr"

        let process = Process()
        process.executableURL = helper
        process.arguments = [
            imageURL.path,
            mountURL.path,
            "--partition", "\(partitionIndex)",
            "-o", fuseOpts,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // Wait until the path appears in the mount table (empty dir is NOT enough).
        let deadline = Date().addingTimeInterval(10)
        var mounted = false
        while Date() < deadline {
            if !process.isRunning {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                try? fileManager.removeItem(at: mountURL)
                throw X68Error.io("FUSE helper exited early: \(errText)")
            }
            if isPathMounted(mountURL) {
                mounted = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if !mounted {
            process.terminate()
            // Best-effort unmount if half-attached
            let umount = Process()
            umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            umount.arguments = [mountURL.path]
            try? umount.run()
            umount.waitUntilExit()
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

    private func fuseVolumeName(for imageURL: URL, partitionIndex: Int) -> String {
        let base = imageURL.lastPathComponent
        if partitionIndex == 0 { return base }
        return "\(base) (p\(partitionIndex))"
    }

    /// True when `url` is an active mount point (not merely an empty directory).
    private func isPathMounted(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        // Prefer getfsstat — avoids spawning mount(8) and is cheap.
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        // mntonname is the mount point path
        let mnton = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        let std = path
        let priv = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        if mnton == std || mnton == priv || mnton == path { return true }
        // Also: if filesystem type looks like nfs/fuse and mount-from is fuse-t
        let mntfrom = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        if mntfrom.hasPrefix("fuse-t:") { return true }
        // Directory exists but is not a mount → mntonname is a parent (e.g. /)
        // Compare device of path vs parent.
        var parentStat = stat()
        var selfStat = stat()
        let parent = (path as NSString).deletingLastPathComponent
        if stat(path, &selfStat) == 0, stat(parent, &parentStat) == 0 {
            return selfStat.st_dev != parentStat.st_dev
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
            // Brief wait so FUSE-T can exit cleanly before umount.
            let deadline = Date().addingTimeInterval(1.5)
            while proc.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                proc.terminate() // already sent; macOS has no Process.interrupt reliably → kill via signal
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        try tearDownFiles(record, forceUnmount: record.backend == .fuse)
    }

    private func tearDownFiles(_ record: MountRecord, forceUnmount: Bool = false) throws {
        if forceUnmount || record.backend == .fuse {
            unmountPath(record.mountURL)
        }
        guard fileManager.fileExists(atPath: record.mountURL.path) else { return }
        // Snapshots are chmod 0555; bump perms so delete works.
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: record.mountURL.path)
        try fileManager.removeItem(at: record.mountURL)
    }

    private func unmountPath(_ url: URL) {
        let path = url.path
        // Skip if nothing is mounted here (avoids hanging umount on plain folders).
        guard isPathMounted(url) else { return }

        runProcessWithTimeout(
            executable: "/sbin/umount",
            arguments: [path],
            timeout: 2
        )
        if isPathMounted(url) {
            runProcessWithTimeout(
                executable: "/usr/sbin/diskutil",
                arguments: ["unmount", "force", path],
                timeout: 3
            )
        }
    }

    /// Run a short-lived helper process; kill it if it exceeds `timeout` (NFS hard-mount hang).
    private func runProcessWithTimeout(executable: String, arguments: [String], timeout: TimeInterval) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            usleep(50_000)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    /// Delete unknown children under a managed root (orphan recovery).
    private func reclaimDirectoryTree(at root: URL, livePaths: Set<String>, unmountFirst: Bool) -> Int {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }
        var cleaned = 0
        for child in children {
            let path = child.standardizedFileURL.path
            if livePaths.contains(path) { continue }
            if unmountFirst {
                unmountPath(child)
            }
            do {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                // Walk RO tree
                if let enumerator = fileManager.enumerator(atPath: path) {
                    for case let rel as String in enumerator {
                        let full = (path as NSString).appendingPathComponent(rel)
                        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
                    }
                }
                try fileManager.removeItem(at: child)
                cleaned += 1
            } catch {
                fputs("x68drv: could not remove orphan \(path): \(error)\n", stderr)
            }
        }
        return cleaned
    }

    /// Kill leftover helpers from a previous session that still hold our FUSE roots.
    private func terminateStrayHelpers() {
        // Use pgrep (small output) — full `ps -ax` + Pipe can deadlock when the
        // pipe buffer fills and the parent waits for exit.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "x68mount-helper"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return
        }
        // Bounded wait
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return }

        // PIDs of helpers we still own in this process — leave them alone.
        lock.lock()
        let livePIDs = Set(fuseProcesses.values.map(\.processIdentifier))
        lock.unlock()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if pid == getpid() || livePIDs.contains(pid) { continue }
            kill(pid, SIGTERM)
            usleep(80_000)
            kill(pid, SIGKILL)
        }
    }

    public func helperExecutable() -> URL? {
        var candidates: [String] = []

        // 1) Inside app bundle (product path)
        let bundle = Bundle.main.bundleURL
        candidates += [
            bundle.appendingPathComponent("Contents/Helpers/x68mount-helper").path,
            bundle.appendingPathComponent("Contents/MacOS/x68mount-helper").path,
            bundle.appendingPathComponent("Contents/Resources/x68mount-helper").path,
        ]
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("x68mount-helper").path)
        }

        // 2) SPM / swift build next to cwd or known project layouts
        let cwd = fileManager.currentDirectoryPath
        candidates += [
            cwd + "/.build/debug/x68mount-helper",
            cwd + "/.build/arm64-apple-macosx/debug/x68mount-helper",
            cwd + "/.build/x86_64-apple-macosx/debug/x68mount-helper",
            cwd + "/.build/release/x68mount-helper",
            cwd + "/.build/arm64-apple-macosx/release/x68mount-helper",
        ]

        // 3) When Xcode launches the app, cwd is often "/" — walk from executable
        //    up looking for a sibling SPM checkout with a built helper.
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                candidates += [
                    dir.appendingPathComponent(".build/debug/x68mount-helper").path,
                    dir.appendingPathComponent(".build/arm64-apple-macosx/debug/x68mount-helper").path,
                    dir.appendingPathComponent(".build/release/x68mount-helper").path,
                ]
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // 4) Developer convenience: absolute path via env
        if let env = ProcessInfo.processInfo.environment["X68MOUNT_HELPER"] {
            candidates.insert(env, at: 0)
        }

        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // 5) PATH
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
