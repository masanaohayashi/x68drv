import Foundation
import X68Core

/// Developer CLI for list / export / fsck / detect / experimental inject (not the product UI).
@main
enum X68drvTool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(2)
        }

        let cmd = args[1]
        if cmd == "inject" {
            try runInject(Array(args.dropFirst(2)))
            return
        }

        guard args.count >= 3 else {
            printUsage()
            exit(2)
        }

        let imageURL = URL(fileURLWithPath: args[2])
        let disk = try DiskImage.open(url: imageURL)

        switch cmd {
        case "detect":
            print("kind=\(disk.detection.kind.rawValue) confidence=\(disk.detection.confidence.rawValue)")
            print("volumeOffset=\(disk.detection.volumeOffset) size=\(disk.detection.size)")
            for e in disk.detection.evidence {
                print("evidence: \(e)")
            }

        case "list":
            let part = args.count >= 4 ? (Int(args[3]) ?? 0) : 0
            let vol = try disk.openVolume(partitionIndex: part)
            for entry in try vol.listEntries() {
                let kind = entry.isDirectory ? "DIR" : "FILE"
                print("\(kind)\t\(entry.size)\t\(entry.name.display)")
            }

        case "export":
            guard args.count >= 5 else {
                fputs("export requires <path-in-image> <host-out>\n", stderr)
                exit(2)
            }
            let remote = HumanPath(display: args[3])
            let out = URL(fileURLWithPath: args[4])
            let part = args.count >= 6 ? (Int(args[5]) ?? 0) : 0
            let vol = try disk.openVolume(partitionIndex: part)
            try vol.export(path: remote, to: out)
            print("wrote \(out.path)")

        case "fsck":
            let part = args.count >= 4 ? (Int(args[3]) ?? 0) : 0
            let vol = try disk.openVolume(partitionIndex: part)
            let report = try vol.fsck()
            if report.isClean {
                print("fsck: clean")
                exit(0)
            }
            for issue in report.issues {
                print("\(issue.kind.rawValue)\t\(issue.path)\t\(issue.message)")
            }
            exit(1)

        case "mount":
            // Snapshot-mount for CLI testing (opens folder under Application Support).
            let part = args.count >= 4 ? (Int(args[3]) ?? 0) : 0
            let service = MountService.shared
            let record = try service.mount(url: imageURL, partitionIndex: part)
            print("mounted \(record.mountURL.path) backend=\(record.backend.rawValue)")

        case "eject-all":
            try MountService.shared.ejectAll()
            print("ejected all")

        default:
            fputs("unknown command: \(cmd)\n", stderr)
            printUsage()
            exit(2)
        }
    }

    /// Stage A: experimental root-file inject into HDS/HDF.
    ///
    ///     x68drv-tool inject --write [--overwrite] <image> <host-file> <NAME.EXT> [partition]
    private static func runInject(_ args: [String]) throws {
        var write = false
        var overwrite = false
        var positional: [String] = []
        for a in args {
            switch a {
            case "--write": write = true
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") {
                    fputs("unknown inject flag: \(a)\n", stderr)
                    exit(2)
                }
                positional.append(a)
            }
        }
        guard write else {
            fputs(
                "inject refuses to run without --write (experimental; may destroy the image)\n",
                stderr
            )
            exit(2)
        }
        guard positional.count >= 3 else {
            fputs(
                "usage: x68drv-tool inject --write [--overwrite] <image> <host-file> <NAME.EXT> [partition]\n",
                stderr
            )
            exit(2)
        }
        let imageURL = URL(fileURLWithPath: positional[0])
        let hostURL = URL(fileURLWithPath: positional[1])
        let remote = HumanFileName(display: positional[2])
        let part = positional.count >= 4 ? (Int(positional[3]) ?? 0) : 0

        // Preflight fsck (clean required).
        let disk = try DiskImage.open(url: imageURL)
        let vol = try disk.openVolume(partitionIndex: part)
        let report = try vol.fsck()
        if !report.isClean {
            fputs("fsck not clean; refusing inject:\n", stderr)
            for issue in report.issues {
                fputs("  \(issue.kind.rawValue)\t\(issue.path)\t\(issue.message)\n", stderr)
            }
            exit(1)
        }

        let result = try HddInject.injectRootFileToURL(
            imageURL: imageURL,
            partitionIndex: part,
            hostFileURL: hostURL,
            remoteName: remote,
            overwrite: overwrite
        )
        print(
            "injected \(result.remoteName) bytes=\(result.bytesWritten) cluster0=\(result.firstCluster) clusters=\(result.clusterCount) overwrite=\(result.overwritten)"
        )

        // Postflight
        let disk2 = try DiskImage.open(url: imageURL)
        let vol2 = try disk2.openVolume(partitionIndex: part)
        let report2 = try vol2.fsck()
        if report2.isClean {
            print("fsck: clean")
        } else {
            fputs("warning: fsck dirty after inject\n", stderr)
            for issue in report2.issues {
                fputs("  \(issue.kind.rawValue)\t\(issue.path)\t\(issue.message)\n", stderr)
            }
            exit(1)
        }
    }

    private static func printUsage() {
        fputs(
            """
            usage:
              x68drv-tool detect <image>
              x68drv-tool list <image> [partition]
              x68drv-tool export <image> <path-in-image> <host-out> [partition]
              x68drv-tool fsck <image> [partition]
              x68drv-tool mount <image> [partition]
              x68drv-tool eject-all
              x68drv-tool inject --write [--overwrite] <image> <host-file> <NAME.EXT> [partition]
                (experimental Stage A: HDS/HDF root inject only; backs up nothing — copy image first)

            """,
            stderr
        )
    }
}
