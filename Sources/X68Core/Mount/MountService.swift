import Foundation
import Darwin

public enum MountBackend: String, Equatable, Sendable {
    /// Live FUSE-T volume (Finder volume).
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
    /// True when FUSE was started with `--experimental-write` (HDS/HDF only).
    public var experimentalWrite: Bool

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        mountURL: URL,
        partitionIndex: Int,
        backend: MountBackend,
        displayName: String,
        experimentalWrite: Bool = false
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.mountURL = mountURL
        self.partitionIndex = partitionIndex
        self.backend = backend
        self.displayName = displayName
        self.experimentalWrite = experimentalWrite
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

    /// Mount image. Prefers FUSE when FUSE-T is present and helper runs;
    /// otherwise uses snapshot export under Application Support.
    ///
    /// - Parameter experimentalWrite: When true, starts FUSE with
    ///   `--experimental-write` (HDS/HDF only; mutates the image). Does **not**
    ///   fall back to a read-only snapshot — fails if FUSE/write cannot run.
    @discardableResult
    public func mount(
        url: URL,
        partitionIndex: Int = 0,
        preferFuse: Bool = true,
        experimentalWrite: Bool = false
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

        // Write mode only for HDS/HDF. Other formats mount read-only (setting stays on).
        let writeEligible: Bool = {
            guard experimentalWrite else { return false }
            switch disk.detection.kind {
            case .hds, .hdf: return true
            default: return false
            }
        }()

        let fuse = FuseAvailability.probe(fileManager: fileManager)
        var record: MountRecord?

        if preferFuse, fuse.isAvailable {
            if let helper = helperExecutable() {
                do {
                    record = try mountWithFuse(
                        helper: helper,
                        imageURL: standardized,
                        partitionIndex: partitionIndex,
                        experimentalWrite: writeEligible
                    )
                } catch {
                    if writeEligible {
                        // HDS/HDF write intent must not silently become a RO folder.
                        throw error
                    }
                    fputs("x68drv: FUSE mount failed (\(error)); falling back to snapshot\n", stderr)
                }
            } else if writeEligible {
                throw X68Error.io(
                    "Experimental write requires x68mount-helper (rebuild the app or: swift build --product x68mount-helper)"
                )
            } else {
                fputs(
                    "x68drv: FUSE is installed but x68mount-helper was not found; falling back to snapshot\n",
                    stderr
                )
            }
        } else if writeEligible {
            let reason: String
            if case .unavailable(let r) = fuse {
                reason = r
            } else {
                reason = "FUSE not available"
            }
            throw X68Error.io(
                "Experimental write mount needs FUSE-T. \(reason)"
            )
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
        // Detach from in-memory tables first so the UI never keeps a "stuck" mount
        // while unmount/kill runs (can take several seconds).
        lock.lock()
        guard let idx = mounts.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            throw X68Error.io("Mount not found")
        }
        let record = mounts.remove(at: idx)
        let proc = fuseProcesses.removeValue(forKey: record.id)
        lock.unlock()

        tearDownDetached(record: record, process: proc)
    }

    public func eject(sourceURL: URL, partitionIndex: Int = 0) throws {
        let std = sourceURL.standardizedFileURL
        lock.lock()
        let record = mounts.first {
            $0.sourceURL.standardizedFileURL == std && $0.partitionIndex == partitionIndex
        }
        lock.unlock()
        guard let record else {
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
        for record in copy {
            tearDownDetached(record: record, process: procs[record.id])
        }
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
        partitionIndex: Int,
        experimentalWrite: Bool = false
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
        let ro = experimentalWrite ? "" : "rdonly,"
        let fuseOpts = "volname=\(volName),\(ro)local,noappledouble,noapplexattr"

        var arguments = [
            imageURL.path,
            mountURL.path,
            "--partition", "\(partitionIndex)",
        ]
        if experimentalWrite {
            arguments.append("--experimental-write")
        }
        arguments.append(contentsOf: ["-o", fuseOpts])

        // Capture early stderr to a temp file (not a Pipe). A full Pipe buffer
        // blocks the helper forever and freezes Finder eject / umount.
        let errLog = fileManager.temporaryDirectory
            .appendingPathComponent("x68mount-\(UUID().uuidString).log")
        fileManager.createFile(atPath: errLog.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errLog)

        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.standardError = errHandle
        process.standardOutput = FileHandle.nullDevice
        // Detach from our process group so SIGTERM on the app doesn't leave a
        // half-dead NFS mount; we manage lifecycle via fuseProcesses.
        process.qualityOfService = .userInitiated

        try process.run()
        try? errHandle.close()

        // Wait until the path appears in the mount table (empty dir is NOT enough).
        let deadline = Date().addingTimeInterval(10)
        var mounted = false
        while Date() < deadline {
            if !process.isRunning {
                let errText = (try? String(contentsOf: errLog, encoding: .utf8)) ?? ""
                try? fileManager.removeItem(at: errLog)
                try? fileManager.removeItem(at: mountURL)
                throw X68Error.io("FUSE helper exited early: \(errText)")
            }
            if isPathMounted(mountURL) {
                mounted = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        try? fileManager.removeItem(at: errLog)

        if !mounted {
            terminateHelperProcess(process)
            unmountPath(mountURL)
            try? fileManager.removeItem(at: mountURL)
            throw X68Error.io("Timed out waiting for FUSE mount at \(mountURL.path)")
        }

        let record = MountRecord(
            sourceURL: imageURL,
            mountURL: mountURL,
            partitionIndex: partitionIndex,
            backend: .fuse,
            displayName: imageURL.lastPathComponent,
            experimentalWrite: experimentalWrite
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

    /// Unmount + kill helper. Best-effort: never throws (callers already detached record).
    ///
    /// Order matters for FUSE-T (NFS): **unmount first**, then stop helper. Killing the
    /// helper while the NFS mount is busy often leaves a stuck volume that Finder
    /// cannot eject.
    private func tearDownDetached(record: MountRecord, process: Process?) {
        if record.backend == .fuse {
            // 1) Ask the volume to go away (helper should exit when fuse_main returns).
            unmountPath(record.mountURL)
            // 2) Wait briefly for clean helper exit.
            if let proc = process, proc.isRunning {
                waitForProcessExit(proc, timeout: 1.0)
            }
            // 3) Force-kill leftover helper (and its process group if possible).
            if let proc = process, proc.isRunning {
                terminateHelperProcess(proc)
            }
            // 4) Second unmount pass after helper death.
            unmountPath(record.mountURL)
        } else if let proc = process, proc.isRunning {
            terminateHelperProcess(proc)
        }

        removeMountDirectory(record.mountURL)
    }

    private func tearDownFiles(_ record: MountRecord, forceUnmount: Bool = false) {
        if forceUnmount || record.backend == .fuse {
            unmountPath(record.mountURL)
        }
        removeMountDirectory(record.mountURL)
    }

    private func removeMountDirectory(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        // Snapshots are chmod 0555; bump perms so delete works.
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if let enumerator = fileManager.enumerator(atPath: url.path) {
            for case let rel as String in enumerator {
                let full = (url.path as NSString).appendingPathComponent(rel)
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
            }
        }
        try? fileManager.removeItem(at: url)
    }

    private func unmountPath(_ url: URL) {
        let path = url.path
        // Skip if nothing is mounted here (avoids hanging umount on plain folders).
        guard isPathMounted(url) else { return }

        // Soft → hard escalation (each call is time-bounded).
        runProcessWithTimeout(executable: "/sbin/umount", arguments: [path], timeout: 1.5)
        if isPathMounted(url) {
            runProcessWithTimeout(executable: "/sbin/umount", arguments: ["-f", path], timeout: 1.5)
        }
        if isPathMounted(url) {
            runProcessWithTimeout(
                executable: "/usr/sbin/diskutil",
                arguments: ["unmount", "force", path],
                timeout: 2.5
            )
        }
        if isPathMounted(url) {
            // Last resort: some FUSE-T builds respond better to umount -f -l semantics;
            // macOS umount has -f only.
            runProcessWithTimeout(executable: "/sbin/umount", arguments: ["-f", path], timeout: 1.0)
        }
    }

    private func waitForProcessExit(_ proc: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func terminateHelperProcess(_ proc: Process) {
        let pid = proc.processIdentifier
        guard pid > 0 else { return }
        // Kill the helper process only (not -pid group: Foundation.Process is not
        // always a group leader; killing the group can hit unrelated PIDs).
        kill(pid, SIGTERM)
        waitForProcessExit(proc, timeout: 0.8)
        if proc.isRunning {
            kill(pid, SIGKILL)
            waitForProcessExit(proc, timeout: 0.3)
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
