import Foundation

/// Detects whether a FUSE-compatible stack (FUSE-T / macFUSE) is present.
public enum FuseAvailability: Equatable, Sendable {
    case available(detail: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public static let fuseTInstallURL = URL(string: "https://www.fuse-t.org/")!

    /// Probe common install locations (no link dependency).
    public static func probe(fileManager: FileManager = .default) -> FuseAvailability {
        let candidates = [
            "/usr/local/lib/libfuse-t.dylib",
            "/usr/local/lib/libfuse.2.dylib",
            "/usr/local/lib/libfuse.dylib",
            "/opt/homebrew/lib/libfuse-t.dylib",
            "/opt/homebrew/lib/libfuse.2.dylib",
            "/opt/homebrew/lib/libfuse.dylib",
            "/Library/Frameworks/macFUSE.framework",
            "/Library/Filesystems/macfuse.fs",
            "/Library/Filesystems/fuse-t.fs",
            "/Library/Filesystems/fusefs.fs",
            "/usr/local/lib/libfuse-t.2.dylib",
        ]
        for path in candidates {
            if fileManager.fileExists(atPath: path) {
                return .available(detail: path)
            }
        }
        // Also look for installer app support / CLI markers
        let markers = [
            "/Library/Application Support/fuse-t",
            "/usr/local/bin/go-nfsv4",
        ]
        for path in markers {
            if fileManager.fileExists(atPath: path) {
                return .available(detail: path)
            }
        }
        return .unavailable(
            reason: "Install FUSE-T from https://www.fuse-t.org/ (or brew install macos-fuse-t/cask/fuse-t) for volumes under /Volumes. Without it, x68drv uses temporary folders."
        )
    }
}
