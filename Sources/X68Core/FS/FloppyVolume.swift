import Foundation

/// Read-only Human68k floppy volume (LE FAT12) inside an XDF/DIM image buffer.
public final class FloppyVolume: @unchecked Sendable {
    public let imageData: Data
    public let volumeOffset: Int
    public let bpb: FloppyBPB
    public let detection: DetectionResult

    private let fat: FAT12
    private let volume: Data

    public init(imageData: Data, detection: DetectionResult? = nil) throws {
        let det = detection ?? ImageDetector.detect(data: imageData)
        self.detection = det

        switch det.kind {
        case .xdf:
            guard imageData.count == ImageDetector.xdf2HDSize else {
                throw X68Error.unsupported(
                    "XDF must be exactly \(ImageDetector.xdf2HDSize) bytes (got \(imageData.count))"
                )
            }
        case .dim:
            guard imageData.count > ImageDetector.dimHeaderSize else {
                throw X68Error.format("DIM image too small")
            }
            // Volume after 256-byte header; for v0.1 prefer payload size 1232K.
            let payload = imageData.count - ImageDetector.dimHeaderSize
            if payload != ImageDetector.xdf2HDSize {
                // Still try if BPB is valid; reject only when both size and BPB fail later.
            }
        default:
            throw X68Error.unsupported("Not a floppy image (kind=\(det.kind.rawValue))")
        }

        self.imageData = imageData
        self.volumeOffset = det.volumeOffset
        guard imageData.count >= volumeOffset else {
            throw X68Error.format("volumeOffset beyond image")
        }
        self.volume = imageData.subdata(in: volumeOffset..<imageData.count)
        self.bpb = try FloppyBPB.parse(volume: volume, allow2HDFallback: true)

        let fatStart = bpb.reservedSectors * bpb.bytesPerSector
        let fatBytes = bpb.fatSizeSectors * bpb.bytesPerSector
        guard fatStart + fatBytes <= volume.count else {
            throw X68Error.format("FAT region out of range")
        }
        let fatData = volume.subdata(in: fatStart..<(fatStart + fatBytes))
        // Max data clusters roughly total sectors.
        let maxClusters = max(2, bpb.totalSectors)
        self.fat = FAT12(table: fatData, maxClusters: maxClusters)
    }

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(imageData: data)
    }

    // MARK: - Public API

    public struct ListedEntry: Equatable, Sendable {
        public var name: HumanFileName
        public var isDirectory: Bool
        public var size: UInt32
        public var firstCluster: UInt16
    }

    public func list(path: HumanPath = HumanPath()) throws -> [ListedEntry] {
        let entries = try directoryEntries(path: path)
        return entries.compactMap { e in
            guard e.isFile || e.isDirectory else { return nil }
            if e.name.display == "." || e.name.display == ".." { return nil }
            return ListedEntry(
                name: e.name,
                isDirectory: e.isDirectory,
                size: e.size,
                firstCluster: e.firstCluster
            )
        }
    }

    public func readFile(path: HumanPath) throws -> Data {
        guard !path.components.isEmpty else {
            throw X68Error.filesystem("Empty path")
        }
        let parent = HumanPath(components: Array(path.components.dropLast()))
        let leaf = path.components.last!
        let entries = try directoryEntries(path: parent)
        guard let entry = entries.first(where: {
            $0.isFile && namesEqual($0.name, leaf)
        }) else {
            throw X68Error.filesystem("File not found: \(path.display)")
        }
        return try readClusters(start: Int(entry.firstCluster), size: Int(entry.size))
    }

    public func export(path: HumanPath, to url: URL) throws {
        let data = try readFile(path: path)
        try data.write(to: url, options: .atomic)
    }

    public func listEntries(path: HumanPath = HumanPath()) throws -> [VolumeEntry] {
        try list(path: path).map {
            VolumeEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size)
        }
    }

    public func fsck() throws -> FsckReport {
        let files = try collectFsckFiles(path: HumanPath(), prefix: "")
        return FsckRunner.run(
            files: files,
            chain: { try self.fat.chain(from: $0) },
            bytesPerCluster: bpb.bytesPerCluster
        )
    }

    public func spaceInfo() throws -> VolumeSpaceInfo {
        let free = try fat.countFreeClusters()
        let total = fat.dataClusterCount
        let bpc = UInt64(max(1, bpb.bytesPerCluster))
        return VolumeSpaceInfo(
            blockSize: bpc,
            totalBlocks: UInt64(max(0, total)),
            freeBlocks: UInt64(max(0, free))
        )
    }

    // MARK: - Internals

    private func collectFsckFiles(path: HumanPath, prefix: String) throws -> [FsckRunner.FileRef] {
        var result: [FsckRunner.FileRef] = []
        let entries = try directoryEntries(path: path)
        for e in entries {
            guard e.isFile || e.isDirectory else { continue }
            if e.name.display == "." || e.name.display == ".." { continue }
            let display = prefix.isEmpty ? e.name.display : "\(prefix)/\(e.name.display)"
            result.append(FsckRunner.FileRef(
                path: display,
                firstCluster: Int(e.firstCluster),
                size: Int(e.size),
                isDirectory: e.isDirectory
            ))
            if e.isDirectory {
                let childPath = HumanPath(components: path.components + [e.name])
                result.append(contentsOf: try collectFsckFiles(path: childPath, prefix: display))
            }
        }
        return result
    }

    private func directoryEntries(path: HumanPath) throws -> [DirEntry] {
        if path.components.isEmpty {
            return try readRootDirectory()
        }
        // Walk subdirectories
        var current = try readRootDirectory()
        for (index, component) in path.components.enumerated() {
            guard let entry = current.first(where: {
                $0.isDirectory && namesEqual($0.name, component)
            }) else {
                throw X68Error.filesystem("Directory not found: \(component.display)")
            }
            let isLast = index == path.components.count - 1
            let next = try readDirectoryClusterChain(start: Int(entry.firstCluster))
            if isLast {
                // If path points at a directory itself, return its contents.
                // Caller for list(path) wants children of path.
            }
            current = next
        }
        return current
    }

    private func namesEqual(_ a: HumanFileName, _ b: HumanFileName) -> Bool {
        a.stem.uppercased() == b.stem.uppercased() && a.ext.uppercased() == b.ext.uppercased()
    }

    private func readRootDirectory() throws -> [DirEntry] {
        let offset = bpb.rootDirOffset
        let bytes = bpb.rootEntryCount * DirEntry.size
        guard offset + bytes <= volume.count else {
            throw X68Error.format("Root directory out of range")
        }
        return try parseDirTable(volume.subdata(in: offset..<(offset + bytes)))
    }

    private func readDirectoryClusterChain(start: Int) throws -> [DirEntry] {
        let clusters = try fat.chain(from: start)
        var data = Data()
        for c in clusters {
            data.append(try clusterData(c))
        }
        return try parseDirTable(data)
    }

    private func parseDirTable(_ data: Data) throws -> [DirEntry] {
        var result: [DirEntry] = []
        var o = 0
        while o + DirEntry.size <= data.count {
            let e = try DirEntry.parse(data, at: o)
            if e.isEnd { break }
            if !e.isDeleted {
                result.append(e)
            }
            o += DirEntry.size
        }
        return result
    }

    private func readClusters(start: Int, size: Int) throws -> Data {
        if size == 0 { return Data() }
        let clusters = try fat.chain(from: start)
        var out = Data()
        out.reserveCapacity(size)
        for c in clusters {
            out.append(try clusterData(c))
            if out.count >= size { break }
        }
        if out.count < size {
            throw X68Error.filesystem("Short read: need \(size) got \(out.count)")
        }
        return out.prefix(size)
    }

    private func clusterData(_ cluster: Int) throws -> Data {
        // cluster 2 is first data cluster
        let sector = bpb.firstDataSector + (cluster - 2) * bpb.sectorsPerCluster
        let offset = sector * bpb.bytesPerSector
        let count = bpb.bytesPerCluster
        guard offset >= 0, offset + count <= volume.count else {
            throw X68Error.outOfBounds(offset: offset, size: count, available: volume.count)
        }
        return volume.subdata(in: offset..<(offset + count))
    }
}
