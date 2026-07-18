import Foundation

/// Read-only Human68k HDD volume (BE FAT16) within an HDS image.
public final class HddVolume: @unchecked Sendable {
    public let imageData: Data
    public let partition: PartitionEntry
    public let bpb: HddBPB

    private let volume: Data
    private let fat: FAT16BE

    public init(imageData: Data, partition: PartitionEntry) throws {
        self.imageData = imageData
        self.partition = partition
        let start = partition.bootOffset
        let end: Int
        if partition.recordCount > 0 {
            end = min(imageData.count, start + Int(partition.recordCount) * SxSIHeader.logicalRecord)
        } else {
            end = imageData.count
        }
        guard start >= 0, start < end, end <= imageData.count else {
            throw X68Error.format("Partition bounds invalid start=\(start) end=\(end)")
        }
        self.volume = imageData.subdata(in: start..<end)
        self.bpb = try HddBPB.parse(volume: volume)

        let fatStart = bpb.reservedSectors * bpb.bytesPerSector
        let fatBytes = bpb.fatSizeSectors * bpb.bytesPerSector
        guard fatStart + fatBytes <= volume.count else {
            throw X68Error.format("HDD FAT region out of range")
        }
        let fatData = volume.subdata(in: fatStart..<(fatStart + fatBytes))
        let maxClusters = max(2, fatBytes / 2 - 1)
        self.fat = FAT16BE(table: fatData, maxClusters: maxClusters)
    }

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
        guard let entry = entries.first(where: { $0.isFile && namesEqual($0.name, leaf) }) else {
            throw X68Error.filesystem("File not found: \(path.display)")
        }
        return try readClusters(start: Int(entry.firstCluster), size: Int(entry.size))
    }

    public func export(path: HumanPath, to url: URL) throws {
        let data = try readFile(path: path)
        try data.write(to: url, options: .atomic)
    }

    /// Expose FAT table for endian negative tests.
    public var fatTableForTesting: Data {
        let fatStart = bpb.reservedSectors * bpb.bytesPerSector
        let fatBytes = bpb.fatSizeSectors * bpb.bytesPerSector
        return volume.subdata(in: fatStart..<(fatStart + fatBytes))
    }

    // MARK: - private

    private func directoryEntries(path: HumanPath) throws -> [DirEntry] {
        if path.components.isEmpty {
            return try readRootDirectory()
        }
        var current = try readRootDirectory()
        for component in path.components {
            guard let entry = current.first(where: {
                $0.isDirectory && namesEqual($0.name, component)
            }) else {
                throw X68Error.filesystem("Directory not found: \(component.display)")
            }
            current = try readDirectoryClusterChain(start: Int(entry.firstCluster))
        }
        return current
    }

    private func namesEqual(_ a: HumanFileName, _ b: HumanFileName) -> Bool {
        a.stem.uppercased() == b.stem.uppercased() && a.ext.uppercased() == b.ext.uppercased()
    }

    private func readRootDirectory() throws -> [DirEntry] {
        let offset = bpb.rootDirOffsetInVolume
        let bytes = bpb.rootEntryCount * DirEntry.size
        guard offset + bytes <= volume.count else {
            throw X68Error.format("HDD root directory out of range")
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
        return Data(out.prefix(size))
    }

    private func clusterData(_ cluster: Int) throws -> Data {
        let sector = bpb.firstDataSector + (cluster - 2) * bpb.sectorsPerCluster
        let offset = sector * bpb.bytesPerSector
        let count = bpb.bytesPerCluster
        guard offset + count <= volume.count else {
            throw X68Error.outOfBounds(offset: offset, size: count, available: volume.count)
        }
        return volume.subdata(in: offset..<(offset + count))
    }
}
