import Foundation
import X68Core

/// Developer CLI for list / export / fsck / detect (not the product UI).
@main
enum X68drvTool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs(
                """
                usage:
                  x68drv-tool detect <image>
                  x68drv-tool list <image> [partition]
                  x68drv-tool export <image> <path-in-image> <host-out> [partition]
                  x68drv-tool fsck <image> [partition]

                """,
                stderr
            )
            exit(2)
        }

        let cmd = args[1]
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

        default:
            fputs("unknown command: \(cmd)\n", stderr)
            exit(2)
        }
    }
}
