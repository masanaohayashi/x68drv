import Foundation

/// Detects whether a FUSE-compatible stack (FUSE-T or compatible libfuse) is present.
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
            // FUSE-T 1.x (FSKit / framework installer — current default)
            "/Library/Frameworks/fuse_t.framework",
            "/Library/Frameworks/fuse_t.framework/fuse_t",
            "/Applications/fuse-t.app",
            "/Library/Application Support/fuse-t",
            "/Library/Application Support/fuse-t/lib/libfuse-t-1.2.7.dylib",
            "/Library/Application Support/fuse-t/lib/libfuse-t.dylib",
            "/Library/Application Support/fuse-t/bin/go-nfsv4",
            // Classic dylib / Homebrew / compatible installs
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
            "/usr/local/bin/go-nfsv4",
        ]
        for path in candidates {
            if fileManager.fileExists(atPath: path) {
                return .available(detail: path)
            }
        }
        return .unavailable(
            reason: "Install FUSE-T from https://www.fuse-t.org/ (or brew install macos-fuse-t/cask/fuse-t) for volumes under /Volumes. Without it, x68drv uses temporary folders."
        )
    }
}
