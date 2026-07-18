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
        if cmd == "delete" {
            try runDelete(Array(args.dropFirst(2)))
            return
        }
        if cmd == "mkdir" {
            try runMkdir(Array(args.dropFirst(2)))
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
        let remote = HumanPath(display: positional[2])
        let part = positional.count >= 4 ? (Int(positional[3]) ?? 0) : 0

        try requireClean(imageURL: imageURL, partition: part, action: "inject")

        let result = try HddInject.injectFileToURL(
            imageURL: imageURL,
            partitionIndex: part,
            hostFileURL: hostURL,
            remotePath: remote,
            overwrite: overwrite
        )
        print(
            "injected \(result.remoteName) bytes=\(result.bytesWritten) cluster0=\(result.firstCluster) clusters=\(result.clusterCount) overwrite=\(result.overwritten)"
        )
        try postflightFsck(imageURL: imageURL, partition: part)
    }

    /// Stage B: experimental root-file delete on HDS/HDF.
    ///
    ///     x68drv-tool delete --write <image> <NAME.EXT> [partition]
    private static func runDelete(_ args: [String]) throws {
        var write = false
        var positional: [String] = []
        for a in args {
            switch a {
            case "--write": write = true
            default:
                if a.hasPrefix("-") {
                    fputs("unknown delete flag: \(a)\n", stderr)
                    exit(2)
                }
                positional.append(a)
            }
        }
        guard write else {
            fputs(
                "delete refuses to run without --write (experimental; may destroy the image)\n",
                stderr
            )
            exit(2)
        }
        guard positional.count >= 2 else {
            fputs(
                "usage: x68drv-tool delete --write <image> <NAME.EXT> [partition]\n",
                stderr
            )
            exit(2)
        }
        let imageURL = URL(fileURLWithPath: positional[0])
        let remote = HumanPath(display: positional[1])
        let part = positional.count >= 3 ? (Int(positional[2]) ?? 0) : 0

        try requireClean(imageURL: imageURL, partition: part, action: "delete")

        let result = try HddInject.deleteFileToURL(
            imageURL: imageURL,
            partitionIndex: part,
            remotePath: remote
        )
        print("deleted \(result.remoteName) freedClusters=\(result.freedClusters)")
        try postflightFsck(imageURL: imageURL, partition: part)
    }

    /// Stage C: create directory (parent/name or just name under root).
    ///
    ///     x68drv-tool mkdir --write <image> <DIR> [partition]
    ///     x68drv-tool mkdir --write <image> <PARENT/DIR> [partition]
    private static func runMkdir(_ args: [String]) throws {
        var write = false
        var positional: [String] = []
        for a in args {
            switch a {
            case "--write": write = true
            default:
                if a.hasPrefix("-") {
                    fputs("unknown mkdir flag: \(a)\n", stderr)
                    exit(2)
                }
                positional.append(a)
            }
        }
        guard write else {
            fputs(
                "mkdir refuses to run without --write (experimental; may destroy the image)\n",
                stderr
            )
            exit(2)
        }
        guard positional.count >= 2 else {
            fputs(
                "usage: x68drv-tool mkdir --write <image> <DIR|PARENT/DIR> [partition]\n",
                stderr
            )
            exit(2)
        }
        let imageURL = URL(fileURLWithPath: positional[0])
        let path = HumanPath(display: positional[1])
        guard let name = path.components.last else {
            fputs("mkdir: empty directory name\n", stderr)
            exit(2)
        }
        let parent = HumanPath(components: Array(path.components.dropLast()))
        let part = positional.count >= 3 ? (Int(positional[2]) ?? 0) : 0

        try requireClean(imageURL: imageURL, partition: part, action: "mkdir")
        let result = try HddInject.mkdirToURL(
            imageURL: imageURL,
            partitionIndex: part,
            parentPath: parent,
            name: name
        )
        print("mkdir \(result.remoteName) cluster=\(result.firstCluster)")
        try postflightFsck(imageURL: imageURL, partition: part)
    }

    private static func requireClean(imageURL: URL, partition: Int, action: String) throws {
        let disk = try DiskImage.open(url: imageURL)
        let vol = try disk.openVolume(partitionIndex: partition)
        let report = try vol.fsck()
        if !report.isClean {
            fputs("fsck not clean; refusing \(action):\n", stderr)
            for issue in report.issues {
                fputs("  \(issue.kind.rawValue)\t\(issue.path)\t\(issue.message)\n", stderr)
            }
            exit(1)
        }
    }

    private static func postflightFsck(imageURL: URL, partition: Int) throws {
        let disk = try DiskImage.open(url: imageURL)
        let vol = try disk.openVolume(partitionIndex: partition)
        let report = try vol.fsck()
        if report.isClean {
            print("fsck: clean")
        } else {
            fputs("warning: fsck dirty after write\n", stderr)
            for issue in report.issues {
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
              x68drv-tool inject --write [--overwrite] <image> <host-file> <PATH> [partition]
                (experimental HDS/HDF; PATH may be NAME.EXT or DIR/NAME.EXT)
              x68drv-tool delete --write <image> <PATH> [partition]
              x68drv-tool mkdir --write <image> <DIR|PARENT/DIR> [partition]
                (copy the image first — no automatic backup)

            """,
            stderr
        )
    }
}
