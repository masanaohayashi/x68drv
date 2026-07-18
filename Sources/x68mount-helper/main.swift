import Foundation
import Darwin
import X68Core
import FuseBridge

/// FUSE frontend for a Human68k volume.
///
/// Usage:
///   x68mount-helper <image> <mountpoint> [--partition N] [--experimental-write] [fuse options...]
///
/// Default is read-only. `--experimental-write` enables HDS/HDF write via WritableHddSession
/// (create / write / unlink / mkdir / truncate). Copy the image first.
///
/// Requires FUSE-T (or compatible libfuse) at runtime (via dlopen).
@main
enum X68MountHelper {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs(
                """
                usage: x68mount-helper <image> <mountpoint> [--partition N] [--experimental-write] [fuse options...]

                Default: read-only. --experimental-write requires HDS/HDF and mutates the image
                (backup .x68drv-bak, exclusive lock, fsck-clean preflight).

                """,
                stderr
            )
            exit(2)
        }

        let imagePath = args[1]
        let mountPoint = args[2]
        var partition = 0
        var experimentalWrite = false
        var fuseArgs: [String] = [args[0], "-f", mountPoint]

        var i = 3
        while i < args.count {
            let a = args[i]
            if a == "--partition", i + 1 < args.count {
                partition = Int(args[i + 1]) ?? 0
                i += 2
                continue
            }
            if a == "--experimental-write" {
                experimentalWrite = true
                i += 1
                continue
            }
            fuseArgs.append(a)
            i += 1
        }

        let volName = (imagePath as NSString).lastPathComponent
        if !fuseArgs.contains(where: { $0.contains("volname=") }) {
            let ro = experimentalWrite ? "" : "rdonly,"
            fuseArgs.append(contentsOf: ["-o", "volname=\(volName),\(ro)local"])
        } else if experimentalWrite {
            // Drop rdonly from user-supplied opts if present.
            fuseArgs = fuseArgs.map { arg in
                arg.replacingOccurrences(of: "rdonly,", with: "")
                    .replacingOccurrences(of: ",rdonly", with: "")
                    .replacingOccurrences(of: "rdonly", with: "")
            }
        }

        do {
            if experimentalWrite {
                let session = try WritableHddSession.open(
                    url: URL(fileURLWithPath: imagePath),
                    partitionIndex: partition,
                    requireCleanFsck: true,
                    createBackup: true,
                    lockImage: true
                )
                FuseSession.shared.installWritable(session: session)
                fputs("x68mount-helper: experimental-write enabled for \(imagePath)\n", stderr)
            } else {
                let disk = try DiskImage.open(url: URL(fileURLWithPath: imagePath))
                let volume = try disk.openVolume(partitionIndex: partition)
                FuseSession.shared.install(volume: volume)
            }
        } catch {
            fputs("x68mount-helper: failed to open image: \(error)\n", stderr)
            exit(1)
        }

        try? FileManager.default.createDirectory(
            atPath: mountPoint,
            withIntermediateDirectories: true
        )

        var cArgs: [UnsafeMutablePointer<CChar>?] = fuseArgs.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        let argc = Int32(cArgs.count)

        let code = cArgs.withUnsafeMutableBufferPointer { buf -> Int32 in
            x68_fuse_run(argc, buf.baseAddress)
        }
        exit(code)
    }
}

// MARK: - C callbacks (no capture)

@_cdecl("x68_swift_getattr")
func x68_swift_getattr(_ path: UnsafePointer<CChar>?, _ stbuf: UnsafeMutablePointer<stat>?) -> Int32 {
    FuseSession.shared.getattr(path, stbuf)
}

@_cdecl("x68_swift_readdir")
func x68_swift_readdir(
    _ path: UnsafePointer<CChar>?,
    _ buf: UnsafeMutableRawPointer?,
    _ fillerCtx: UnsafeMutableRawPointer?
) -> Int32 {
    FuseSession.shared.readdir(path, fillerCtx)
}

@_cdecl("x68_swift_open")
func x68_swift_open(
    _ path: UnsafePointer<CChar>?,
    _ flags: Int32,
    _ outFH: UnsafeMutablePointer<UInt64>?,
    _ outSize: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    FuseSession.shared.openFile(path, flags: flags, outFH, outSize)
}

@_cdecl("x68_swift_read")
func x68_swift_read(
    _ fh: UInt64,
    _ buf: UnsafeMutablePointer<CChar>?,
    _ size: Int,
    _ offset: off_t
) -> Int32 {
    FuseSession.shared.readFile(fh, buf, size, offset)
}

@_cdecl("x68_swift_release")
func x68_swift_release(_ fh: UInt64) -> Int32 {
    FuseSession.shared.releaseFile(fh)
}

@_cdecl("x68_swift_write")
func x68_swift_write(
    _ fh: UInt64,
    _ buf: UnsafePointer<CChar>?,
    _ size: Int,
    _ offset: off_t
) -> Int32 {
    FuseSession.shared.writeFile(fh, buf, size, offset)
}

@_cdecl("x68_swift_create")
func x68_swift_create(
    _ path: UnsafePointer<CChar>?,
    _ mode: mode_t,
    _ outFH: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    FuseSession.shared.createFile(path, mode: mode, outFH)
}

@_cdecl("x68_swift_unlink")
func x68_swift_unlink(_ path: UnsafePointer<CChar>?) -> Int32 {
    FuseSession.shared.unlinkPath(path)
}

@_cdecl("x68_swift_mkdir")
func x68_swift_mkdir(_ path: UnsafePointer<CChar>?, _ mode: mode_t) -> Int32 {
    FuseSession.shared.mkdirPath(path, mode: mode)
}

@_cdecl("x68_swift_truncate")
func x68_swift_truncate(_ path: UnsafePointer<CChar>?, _ size: off_t) -> Int32 {
    FuseSession.shared.truncatePath(path, size: size)
}

// MARK: - Session

final class FuseSession: @unchecked Sendable {
    static let shared = FuseSession()

    private enum Backend {
        case readOnly(any ReadableVolume)
        case writable(WritableHddSession)
    }

    private struct OpenHandle {
        var path: HumanPath
        var data: Data
        var writable: Bool
        var dirty: Bool
    }

    private var backend: Backend?
    private var openFiles: [UInt64: OpenHandle] = [:]
    private var nextFH: UInt64 = 1
    private let lock = NSLock()

    private var isWritable: Bool {
        if case .writable = backend { return true }
        return false
    }

    func install(volume: any ReadableVolume) {
        self.backend = .readOnly(volume)
        x68_fuse_set_callbacks(
            x68_swift_getattr,
            x68_swift_readdir,
            x68_swift_open,
            x68_swift_read,
            x68_swift_release
        )
    }

    func installWritable(session: WritableHddSession) {
        self.backend = .writable(session)
        x68_fuse_set_callbacks(
            x68_swift_getattr,
            x68_swift_readdir,
            x68_swift_open,
            x68_swift_read,
            x68_swift_release
        )
        x68_fuse_set_write_callbacks(
            x68_swift_write,
            x68_swift_create,
            x68_swift_unlink,
            x68_swift_mkdir,
            x68_swift_truncate
        )
    }

    private func humanPath(from posix: String) -> HumanPath {
        if posix == "/" { return HumanPath() }
        let trimmed = posix.hasPrefix("/") ? String(posix.dropFirst()) : posix
        return HumanPath(display: trimmed)
    }

    private func listEntries(path: HumanPath) throws -> [VolumeEntry] {
        switch backend {
        case .readOnly(let vol):
            return try vol.listEntries(path: path)
        case .writable(let session):
            return try session.listEntries(path: path)
        case .none:
            throw X68Error.io("No volume")
        }
    }

    private func readVolumeFile(path: HumanPath) throws -> Data {
        switch backend {
        case .readOnly(let vol):
            return try vol.readFile(path: path)
        case .writable(let session):
            return try session.readFile(path: path)
        case .none:
            throw X68Error.io("No volume")
        }
    }

    fileprivate func getattr(_ cPath: UnsafePointer<CChar>?, _ stbuf: UnsafeMutablePointer<stat>?) -> Int32 {
        guard let cPath, let stbuf, backend != nil else { return -EIO }
        let pathStr = String(cString: cPath)
        memset(stbuf, 0, MemoryLayout<stat>.size)

        let dirMode: mode_t = isWritable ? (S_IFDIR | 0o755) : (S_IFDIR | 0o555)
        let fileMode: mode_t = isWritable ? (S_IFREG | 0o644) : (S_IFREG | 0o444)

        if pathStr == "/" {
            stbuf.pointee.st_mode = dirMode
            stbuf.pointee.st_nlink = 2
            stbuf.pointee.st_uid = getuid()
            stbuf.pointee.st_gid = getgid()
            return 0
        }

        // Dirty open handles win for size (Finder write-in-progress).
        let hp = humanPath(from: pathStr)
        lock.lock()
        if let open = openFiles.values.first(where: { $0.path == hp && $0.dirty }) {
            stbuf.pointee.st_mode = fileMode
            stbuf.pointee.st_nlink = 1
            stbuf.pointee.st_uid = getuid()
            stbuf.pointee.st_gid = getgid()
            stbuf.pointee.st_size = off_t(open.data.count)
            lock.unlock()
            return 0
        }
        lock.unlock()

        guard let leaf = hp.components.last else { return -ENOENT }
        let parent = HumanPath(components: Array(hp.components.dropLast()))
        do {
            let entries = try listEntries(path: parent)
            guard let entry = entries.first(where: {
                $0.name.stem.uppercased() == leaf.stem.uppercased()
                    && $0.name.ext.uppercased() == leaf.ext.uppercased()
            }) else {
                return -ENOENT
            }
            stbuf.pointee.st_uid = getuid()
            stbuf.pointee.st_gid = getgid()
            stbuf.pointee.st_nlink = 1
            if entry.isDirectory {
                stbuf.pointee.st_mode = dirMode
                stbuf.pointee.st_nlink = 2
            } else {
                stbuf.pointee.st_mode = fileMode
                stbuf.pointee.st_size = off_t(entry.size)
            }
            return 0
        } catch {
            return mapError(error)
        }
    }

    fileprivate func readdir(_ cPath: UnsafePointer<CChar>?, _ fillerCtx: UnsafeMutableRawPointer?) -> Int32 {
        guard let cPath, let fillerCtx, backend != nil else { return -EIO }
        let pathStr = String(cString: cPath)
        let hp = humanPath(from: pathStr)
        do {
            let entries = try listEntries(path: hp)
            for entry in entries {
                entry.name.display.withCString { cstr in
                    _ = x68_fuse_add_direntry(fillerCtx, cstr)
                }
            }
            return 0
        } catch {
            return mapError(error)
        }
    }

    fileprivate func openFile(
        _ cPath: UnsafePointer<CChar>?,
        flags: Int32,
        _ outFH: UnsafeMutablePointer<UInt64>?,
        _ outSize: UnsafeMutablePointer<UInt64>?
    ) -> Int32 {
        guard let cPath, let outFH, let outSize, backend != nil else { return -EIO }
        let pathStr = String(cString: cPath)
        if pathStr == "/" { return -EISDIR }
        let hp = humanPath(from: pathStr)
        let acc = flags & O_ACCMODE
        let wantWrite = acc == O_WRONLY || acc == O_RDWR
        if wantWrite && !isWritable { return -EROFS }

        do {
            var data = Data()
            if (flags & O_TRUNC) != 0, wantWrite {
                data = Data()
            } else {
                do {
                    data = try readVolumeFile(path: hp)
                } catch {
                    if wantWrite {
                        // Allow open of missing file only when O_CREAT (create op handles that).
                        return -ENOENT
                    }
                    return -ENOENT
                }
            }

            if wantWrite, (flags & O_TRUNC) != 0, case .writable(let session) = backend {
                try session.writeFile(path: hp, contents: data, overwrite: true)
            }

            lock.lock()
            let fh = nextFH
            nextFH += 1
            openFiles[fh] = OpenHandle(
                path: hp,
                data: data,
                writable: wantWrite,
                dirty: wantWrite && (flags & O_TRUNC) != 0
            )
            lock.unlock()
            outFH.pointee = fh
            outSize.pointee = UInt64(data.count)
            return 0
        } catch {
            return mapError(error)
        }
    }

    fileprivate func readFile(
        _ fh: UInt64,
        _ buf: UnsafeMutablePointer<CChar>?,
        _ size: Int,
        _ offset: off_t
    ) -> Int32 {
        guard let buf else { return -EIO }
        lock.lock()
        let handle = openFiles[fh]
        lock.unlock()
        guard let handle else { return -EBADF }
        let data = handle.data
        if offset >= data.count { return 0 }
        let start = Int(offset)
        let count = min(size, data.count - start)
        data.copyBytes(
            to: UnsafeMutableRawPointer(buf).assumingMemoryBound(to: UInt8.self),
            from: start..<(start + count)
        )
        return Int32(count)
    }

    fileprivate func writeFile(
        _ fh: UInt64,
        _ buf: UnsafePointer<CChar>?,
        _ size: Int,
        _ offset: off_t
    ) -> Int32 {
        guard isWritable else { return -EROFS }
        guard let buf, size >= 0, offset >= 0 else { return -EINVAL }
        lock.lock()
        guard var handle = openFiles[fh], handle.writable else {
            lock.unlock()
            return -EBADF
        }
        let end = Int(offset) + size
        if handle.data.count < end {
            handle.data.append(Data(count: end - handle.data.count))
        }
        let raw = UnsafeRawPointer(buf).assumingMemoryBound(to: UInt8.self)
        handle.data.replaceSubrange(
            Int(offset)..<end,
            with: UnsafeBufferPointer(start: raw, count: size)
        )
        handle.dirty = true
        openFiles[fh] = handle
        lock.unlock()
        return Int32(size)
    }

    fileprivate func releaseFile(_ fh: UInt64) -> Int32 {
        lock.lock()
        guard let handle = openFiles.removeValue(forKey: fh) else {
            lock.unlock()
            return 0
        }
        lock.unlock()

        if handle.dirty, case .writable(let session) = backend {
            do {
                try session.writeFile(path: handle.path, contents: handle.data, overwrite: true)
            } catch {
                return mapError(error)
            }
        }
        return 0
    }

    fileprivate func createFile(
        _ cPath: UnsafePointer<CChar>?,
        mode: mode_t,
        _ outFH: UnsafeMutablePointer<UInt64>?
    ) -> Int32 {
        _ = mode
        guard let cPath, let outFH else { return -EIO }
        guard case .writable(let session) = backend else { return -EROFS }
        let pathStr = String(cString: cPath)
        if pathStr == "/" { return -EISDIR }
        let hp = humanPath(from: pathStr)
        do {
            try session.createFile(path: hp)
            lock.lock()
            let fh = nextFH
            nextFH += 1
            openFiles[fh] = OpenHandle(path: hp, data: Data(), writable: true, dirty: false)
            lock.unlock()
            outFH.pointee = fh
            return 0
        } catch {
            return mapError(error)
        }
    }

    fileprivate func unlinkPath(_ cPath: UnsafePointer<CChar>?) -> Int32 {
        guard let cPath else { return -EIO }
        guard case .writable(let session) = backend else { return -EROFS }
        let hp = humanPath(from: String(cString: cPath))
        do {
            try session.deleteFile(path: hp)
            return 0
        } catch {
            return mapError(error)
        }
    }

    fileprivate func mkdirPath(_ cPath: UnsafePointer<CChar>?, mode: mode_t) -> Int32 {
        _ = mode
        guard let cPath else { return -EIO }
        guard case .writable(let session) = backend else { return -EROFS }
        let hp = humanPath(from: String(cString: cPath))
        do {
            try session.mkdir(path: hp)
            return 0
        } catch {
            return mapError(error)
        }
    }

    fileprivate func truncatePath(_ cPath: UnsafePointer<CChar>?, size: off_t) -> Int32 {
        guard let cPath else { return -EIO }
        guard case .writable(let session) = backend else { return -EROFS }
        guard size >= 0 else { return -EINVAL }
        let hp = humanPath(from: String(cString: cPath))

        lock.lock()
        if let key = openFiles.first(where: { $0.value.path == hp })?.key {
            var h = openFiles[key]!
            if h.data.count > Int(size) {
                h.data = h.data.prefix(Int(size))
            } else if h.data.count < Int(size) {
                h.data.append(Data(count: Int(size) - h.data.count))
            }
            h.dirty = true
            openFiles[key] = h
            lock.unlock()
            return 0
        }
        lock.unlock()

        do {
            try session.truncate(path: hp, size: Int(size))
            return 0
        } catch {
            return mapError(error)
        }
    }

    private func mapError(_ error: Error) -> Int32 {
        let msg = (error as? X68Error).map(\.localizedDescription) ?? "\(error)"
        let lower = msg.lowercased()
        if lower.contains("not found") { return -ENOENT }
        if lower.contains("full") || lower.contains("limit") { return -ENOSPC }
        if lower.contains("exists") { return -EEXIST }
        if lower.contains("directory") && lower.contains("refus") { return -EISDIR }
        if lower.contains("unsupported") { return -ENOTSUP }
        return -EIO
    }
}

