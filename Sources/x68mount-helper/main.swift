import Foundation
import Darwin
import X68Core
import FuseBridge

/// FUSE frontend for a Human68k volume (read-only).
///
/// Usage:
///   x68mount-helper <image> <mountpoint> [--partition N] [fuse options...]
///
/// Requires FUSE-T (or compatible libfuse) at runtime (via dlopen).
@main
enum X68MountHelper {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs(
                "usage: x68mount-helper <image> <mountpoint> [--partition N] [fuse options...]\n",
                stderr
            )
            exit(2)
        }

        let imagePath = args[1]
        let mountPoint = args[2]
        var partition = 0
        var fuseArgs: [String] = [args[0], "-f", mountPoint]

        var i = 3
        while i < args.count {
            let a = args[i]
            if a == "--partition", i + 1 < args.count {
                partition = Int(args[i + 1]) ?? 0
                i += 2
                continue
            }
            fuseArgs.append(a)
            i += 1
        }

        let volName = (imagePath as NSString).lastPathComponent
        if !fuseArgs.contains(where: { $0.contains("volname=") }) {
            fuseArgs.append(contentsOf: ["-o", "volname=\(volName),rdonly,local"])
        }

        do {
            let disk = try DiskImage.open(url: URL(fileURLWithPath: imagePath))
            let volume = try disk.openVolume(partitionIndex: partition)
            FuseSession.shared.install(volume: volume)
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
    _ outFH: UnsafeMutablePointer<UInt64>?,
    _ outSize: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    FuseSession.shared.openFile(path, outFH, outSize)
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

// MARK: - Session

final class FuseSession: @unchecked Sendable {
    static let shared = FuseSession()

    private var volume: (any ReadableVolume)?
    private var openFiles: [UInt64: Data] = [:]
    private var nextFH: UInt64 = 1
    private let lock = NSLock()

    func install(volume: any ReadableVolume) {
        self.volume = volume
        x68_fuse_set_callbacks(
            x68_swift_getattr,
            x68_swift_readdir,
            x68_swift_open,
            x68_swift_read,
            x68_swift_release
        )
    }

    private func humanPath(from posix: String) -> HumanPath {
        if posix == "/" { return HumanPath() }
        let trimmed = posix.hasPrefix("/") ? String(posix.dropFirst()) : posix
        return HumanPath(display: trimmed)
    }

    fileprivate func getattr(_ cPath: UnsafePointer<CChar>?, _ stbuf: UnsafeMutablePointer<stat>?) -> Int32 {
        guard let cPath, let stbuf, let volume else { return -EIO }
        let pathStr = String(cString: cPath)
        memset(stbuf, 0, MemoryLayout<stat>.size)

        if pathStr == "/" {
            stbuf.pointee.st_mode = S_IFDIR | 0o555
            stbuf.pointee.st_nlink = 2
            stbuf.pointee.st_uid = getuid()
            stbuf.pointee.st_gid = getgid()
            return 0
        }

        let hp = humanPath(from: pathStr)
        guard let leaf = hp.components.last else { return -ENOENT }
        let parent = HumanPath(components: Array(hp.components.dropLast()))
        do {
            let entries = try volume.listEntries(path: parent)
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
                stbuf.pointee.st_mode = S_IFDIR | 0o555
                stbuf.pointee.st_nlink = 2
            } else {
                stbuf.pointee.st_mode = S_IFREG | 0o444
                stbuf.pointee.st_size = off_t(entry.size)
            }
            return 0
        } catch {
            return -EIO
        }
    }

    fileprivate func readdir(_ cPath: UnsafePointer<CChar>?, _ fillerCtx: UnsafeMutableRawPointer?) -> Int32 {
        guard let cPath, let fillerCtx, let volume else { return -EIO }
        let pathStr = String(cString: cPath)
        let hp = humanPath(from: pathStr)
        do {
            let entries = try volume.listEntries(path: hp)
            for entry in entries {
                entry.name.display.withCString { cstr in
                    _ = x68_fuse_add_direntry(fillerCtx, cstr)
                }
            }
            return 0
        } catch {
            return -EIO
        }
    }

    fileprivate func openFile(
        _ cPath: UnsafePointer<CChar>?,
        _ outFH: UnsafeMutablePointer<UInt64>?,
        _ outSize: UnsafeMutablePointer<UInt64>?
    ) -> Int32 {
        guard let cPath, let outFH, let outSize, let volume else { return -EIO }
        let pathStr = String(cString: cPath)
        if pathStr == "/" { return -EISDIR }
        let hp = humanPath(from: pathStr)
        do {
            let data = try volume.readFile(path: hp)
            lock.lock()
            let fh = nextFH
            nextFH += 1
            openFiles[fh] = data
            lock.unlock()
            outFH.pointee = fh
            outSize.pointee = UInt64(data.count)
            return 0
        } catch {
            return -ENOENT
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
        let data = openFiles[fh]
        lock.unlock()
        guard let data else { return -EBADF }
        if offset >= data.count { return 0 }
        let start = Int(offset)
        let count = min(size, data.count - start)
        data.copyBytes(
            to: UnsafeMutableRawPointer(buf).assumingMemoryBound(to: UInt8.self),
            from: start..<(start + count)
        )
        return Int32(count)
    }

    fileprivate func releaseFile(_ fh: UInt64) -> Int32 {
        lock.lock()
        openFiles.removeValue(forKey: fh)
        lock.unlock()
        return 0
    }
}
