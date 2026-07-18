import Foundation

/// Read-only filesystem consistency report.
public struct FsckIssue: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case cycle
        case crossLink
        case shortChain
        case invalidCluster
        case unreadableDirectory
    }

    public var kind: Kind
    public var path: String
    public var message: String

    public init(kind: Kind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }
}

public struct FsckReport: Equatable, Sendable {
    public var issues: [FsckIssue]

    public var isClean: Bool { issues.isEmpty }

    public init(issues: [FsckIssue] = []) {
        self.issues = issues
    }
}

/// Shared RO checks over a volume's directory tree and FAT chain provider.
enum FsckRunner {
    struct FileRef {
        var path: String
        var firstCluster: Int
        var size: Int
        var isDirectory: Bool
    }

    static func run(
        files: [FileRef],
        chain: (_ start: Int) throws -> [Int],
        bytesPerCluster: Int
    ) -> FsckReport {
        var issues: [FsckIssue] = []
        var owner: [Int: String] = [:]

        for file in files {
            if file.firstCluster == 0 {
                if file.size > 0 && !file.isDirectory {
                    issues.append(FsckIssue(
                        kind: .invalidCluster,
                        path: file.path,
                        message: "Non-empty file has first cluster 0"
                    ))
                }
                continue
            }
            if file.firstCluster == 1 || file.firstCluster < 0 {
                issues.append(FsckIssue(
                    kind: .invalidCluster,
                    path: file.path,
                    message: "Invalid first cluster \(file.firstCluster)"
                ))
                continue
            }

            let clusters: [Int]
            do {
                clusters = try chain(file.firstCluster)
            } catch {
                let msg = (error as? X68Error).map(\.localizedDescription) ?? "\(error)"
                let kind: FsckIssue.Kind = msg.lowercased().contains("cycle") ? .cycle : .invalidCluster
                issues.append(FsckIssue(kind: kind, path: file.path, message: msg))
                continue
            }

            for c in clusters {
                if let prev = owner[c] {
                    issues.append(FsckIssue(
                        kind: .crossLink,
                        path: file.path,
                        message: "Cluster \(c) also used by \(prev)"
                    ))
                } else {
                    owner[c] = file.path
                }
            }

            if !file.isDirectory, file.size > 0 {
                let capacity = clusters.count * bytesPerCluster
                if capacity < file.size {
                    issues.append(FsckIssue(
                        kind: .shortChain,
                        path: file.path,
                        message: "Chain holds \(capacity) bytes but size is \(file.size)"
                    ))
                }
            }
        }

        return FsckReport(issues: issues)
    }
}
