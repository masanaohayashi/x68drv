import Foundation

/// Allocates unique mount directory names under a base folder.
public enum MountPointNamer {
    public static let maxMounts = 8

    /// Sanitize image basename for use as a folder name.
    public static func sanitizeBaseName(_ name: String) -> String {
        let stripped = (name as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = stripped.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var result = String(mapped)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty { return "disk" }
        return String(result.prefix(64))
    }

    /// Choose `base/x68drv-<name>` or with numeric suffix if taken.
    public static func allocate(
        baseDirectory: URL,
        imageFileName: String,
        partitionIndex: Int,
        existing: Set<String>,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = sanitizeBaseName(imageFileName)
        let partSuffix = partitionIndex == 0 ? "" : "-p\(partitionIndex)"
        var attempt = 0
        while attempt < 100 {
            let leaf: String
            if attempt == 0 {
                leaf = "x68drv-\(base)\(partSuffix)"
            } else {
                leaf = "x68drv-\(base)\(partSuffix)-\(attempt)"
            }
            if !existing.contains(leaf) {
                let url = baseDirectory.appendingPathComponent(leaf, isDirectory: true)
                if !fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
            attempt += 1
        }
        throw X68Error.limit("Could not allocate unique mount point name")
    }
}
