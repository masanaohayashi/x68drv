import Foundation

/// Exports a ReadableVolume tree to a host directory (Finder-browsable RO snapshot).
public enum SnapshotExporter {
    public static func exportTree(
        volume: any ReadableVolume,
        to root: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try exportDirectory(volume: volume, path: HumanPath(), hostDir: root, fileManager: fileManager)
    }

    private static func exportDirectory(
        volume: any ReadableVolume,
        path: HumanPath,
        hostDir: URL,
        fileManager: FileManager
    ) throws {
        let entries = try volume.listEntries(path: path)
        for entry in entries {
            let hostName = sanitizeHostFileName(entry.name.display)
            let dest = hostDir.appendingPathComponent(hostName, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                let child = HumanPath(components: path.components + [entry.name])
                try exportDirectory(volume: volume, path: child, hostDir: dest, fileManager: fileManager)
            } else {
                let data = try volume.readFile(path: HumanPath(components: path.components + [entry.name]))
                try data.write(to: dest, options: .atomic)
            }
        }
    }

    public static func sanitizeHostFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let mapped = name.unicodeScalars.map { illegal.contains($0) ? Character("_") : Character($0) }
        var s = String(mapped)
        if s.isEmpty || s == "." || s == ".." { s = "_unnamed_" }
        return s
    }
}
