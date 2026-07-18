import Foundation

/// Experimental write helpers for Human68k HDD volumes (HDS/HDF, BE FAT16).
///
/// **Not** product FUSE write. Mutates a full image buffer and returns it.
///
/// - **Inject**: data clusters → FAT copies → directory entry → host write
/// - **Delete**: directory 0xE5 → free FAT chain → host write (design.md order)
///
/// Stage A: root inject. Stage B: root delete (+ inject overwrite uses free-then-slot).
public enum HddInject {
    public struct Result: Equatable, Sendable {
        public var remoteName: String
        public var bytesWritten: Int
        public var firstCluster: Int
        public var clusterCount: Int
        public var overwritten: Bool
    }

    public struct DeleteResult: Equatable, Sendable {
        public var remoteName: String
        public var freedClusters: Int
    }

    /// Inject `contents` as `fileName` into the **root directory** of `partition`.
    ///
    /// - Parameters:
    ///   - imageData: Full host image (HDS/HDF).
    ///   - partition: Target partition from `HdsImage` / `HdfImage`.
    ///   - fileName: Root-only name (Stage A does not create subdirectories).
    ///   - contents: File payload (empty allowed).
    ///   - overwrite: If true, replace existing file with same name (ASCII case-insensitive).
    public static func injectRootFile(
        imageData: Data,
        partition: PartitionEntry,
        fileName: HumanFileName,
        contents: Data,
        overwrite: Bool = false
    ) throws -> (image: Data, result: Result) {
        var image = imageData
        let boot = partition.bootOffset
        let volEnd: Int
        if partition.recordCount > 0 {
            volEnd = min(image.count, boot + partition.byteLength)
        } else {
            volEnd = image.count
        }
        guard boot >= 0, boot < volEnd else {
            throw X68Error.format("Invalid partition boot offset")
        }

        let volumeSlice = image.subdata(in: boot..<volEnd)
        let bpb = try HddBPB.parse(volume: volumeSlice)

        let fatBytes = bpb.fatSizeSectors * bpb.bytesPerSector
        let fat1Abs = boot + bpb.reservedSectors * bpb.bytesPerSector
        let fat2Abs = fat1Abs + fatBytes
        guard fat1Abs + fatBytes <= volEnd, fat2Abs + fatBytes <= volEnd else {
            throw X68Error.format("FAT region out of partition")
        }

        var fat = FAT16BE(
            table: image.subdata(in: fat1Abs..<(fat1Abs + fatBytes)),
            maxClusters: max(2, fatBytes / 2 - 1)
        )

        let rootAbs = boot + bpb.rootDirOffsetInVolume
        let rootBytes = bpb.rootEntryCount * DirEntry.size
        guard rootAbs + rootBytes <= volEnd else {
            throw X68Error.format("Root directory out of partition")
        }

        // Scan root for free/deleted slot or existing file.
        var slotOffset: Int?
        var existing: (offset: Int, entry: DirEntry)?
        var o = 0
        while o + DirEntry.size <= rootBytes {
            let abs = rootAbs + o
            let entry = try DirEntry.parse(image, at: abs)
            if entry.isEnd {
                // First never-used slot.
                if slotOffset == nil { slotOffset = abs }
                break
            }
            if entry.isDeleted {
                if slotOffset == nil { slotOffset = abs }
            } else if entry.isFile, namesEqual(entry.name, fileName) {
                existing = (abs, entry)
            } else if entry.isDirectory, namesEqual(entry.name, fileName) {
                throw X68Error.filesystem("Path is a directory: \(fileName.display)")
            }
            o += DirEntry.size
        }

        var overwritten = false
        if let existing {
            guard overwrite else {
                throw X68Error.filesystem(
                    "File exists: \(fileName.display) (pass overwrite to replace)"
                )
            }
            // Free old chain (design: mark dir deleted first would be better on-disk;
            // in full-image buffer we free then reuse same slot).
            if existing.entry.firstCluster >= 2 {
                let oldChain = try fat.chain(from: Int(existing.entry.firstCluster))
                try fat.freeChain(oldChain)
            }
            slotOffset = existing.offset
            overwritten = true
        }

        guard let slot = slotOffset else {
            throw X68Error.limit("Root directory full")
        }

        // Cluster count: empty file still needs no cluster on some systems;
        // Human68k/MS-DOS typically use cluster 0 for size 0.
        let bpc = bpb.bytesPerCluster
        let clusterCount: Int
        if contents.isEmpty {
            clusterCount = 0
        } else {
            clusterCount = (contents.count + bpc - 1) / bpc
        }

        let chain: [Int]
        if clusterCount == 0 {
            chain = []
        } else {
            chain = try fat.allocateChain(count: clusterCount)
        }

        // 1) Data clusters
        for (i, cluster) in chain.enumerated() {
            let sector = bpb.firstDataSector + (cluster - 2) * bpb.sectorsPerCluster
            let offset = boot + sector * bpb.bytesPerSector
            guard offset + bpc <= volEnd else {
                throw X68Error.outOfBounds(offset: offset, size: bpc, available: volEnd)
            }
            let start = i * bpc
            let end = min(start + bpc, contents.count)
            var chunk = Data(count: bpc)
            if start < end {
                chunk.replaceSubrange(0..<(end - start), with: contents[start..<end])
            }
            image.replaceSubrange(offset..<(offset + bpc), with: chunk)
        }

        // 2) FAT #1 then 3) FAT #2
        image.replaceSubrange(fat1Abs..<(fat1Abs + fatBytes), with: fat.table)
        if bpb.fatCount >= 2 {
            image.replaceSubrange(fat2Abs..<(fat2Abs + fatBytes), with: fat.table)
        }

        // 4) Directory entry
        let first: UInt16 = chain.first.map { UInt16($0) } ?? 0
        let packed = try DirEntry.pack(
            name: fileName,
            attributes: 0x20,
            firstCluster: first,
            size: UInt32(contents.count)
        )
        image.replaceSubrange(slot..<(slot + DirEntry.size), with: packed)

        let result = Result(
            remoteName: fileName.display,
            bytesWritten: contents.count,
            firstCluster: Int(first),
            clusterCount: chain.count,
            overwritten: overwritten
        )
        return (image, result)
    }

    /// Open image, inject into partition, write back atomically (`*.tmp` + replace).
    @discardableResult
    public static func injectRootFileToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        hostFileURL: URL,
        remoteName: HumanFileName,
        overwrite: Bool = false
    ) throws -> Result {
        let contents = try Data(contentsOf: hostFileURL)
        let original = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        let partition = try partitionEntry(data: original, index: partitionIndex)
        let (mutated, result) = try injectRootFile(
            imageData: original,
            partition: partition,
            fileName: remoteName,
            contents: contents,
            overwrite: overwrite
        )
        try atomicWrite(mutated, to: imageURL)
        return result
    }

    // MARK: - Stage B delete

    /// Delete a **file** from the root directory (not a subdirectory).
    ///
    /// Order (design.md): mark directory entry deleted (0xE5), then free FAT chain.
    public static func deleteRootFile(
        imageData: Data,
        partition: PartitionEntry,
        fileName: HumanFileName
    ) throws -> (image: Data, result: DeleteResult) {
        var image = imageData
        let ctx = try volumeContext(image: image, partition: partition)
        var fat = ctx.fat

        var found: (offset: Int, entry: DirEntry)?
        var o = 0
        while o + DirEntry.size <= ctx.rootBytes {
            let abs = ctx.rootAbs + o
            let entry = try DirEntry.parse(image, at: abs)
            if entry.isEnd { break }
            if !entry.isDeleted, entry.isFile, namesEqual(entry.name, fileName) {
                found = (abs, entry)
                break
            }
            if !entry.isDeleted, entry.isDirectory, namesEqual(entry.name, fileName) {
                throw X68Error.filesystem("Refusing to delete directory: \(fileName.display)")
            }
            o += DirEntry.size
        }
        guard let target = found else {
            throw X68Error.filesystem("File not found: \(fileName.display)")
        }

        // 1) Directory first — name disappears before clusters are freed.
        var slot = image.subdata(in: target.offset..<(target.offset + DirEntry.size))
        slot = DirEntry.markDeleted(slot)
        image.replaceSubrange(target.offset..<(target.offset + DirEntry.size), with: slot)

        // 2) Free FAT chain
        var freed = 0
        if target.entry.firstCluster >= 2 {
            let chain = try fat.chain(from: Int(target.entry.firstCluster))
            try fat.freeChain(chain)
            freed = chain.count
        }
        image.replaceSubrange(ctx.fat1Abs..<(ctx.fat1Abs + ctx.fatBytes), with: fat.table)
        if ctx.bpb.fatCount >= 2 {
            image.replaceSubrange(ctx.fat2Abs..<(ctx.fat2Abs + ctx.fatBytes), with: fat.table)
        }

        return (
            image,
            DeleteResult(remoteName: fileName.display, freedClusters: freed)
        )
    }

    @discardableResult
    public static func deleteRootFileToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        remoteName: HumanFileName
    ) throws -> DeleteResult {
        let original = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        let partition = try partitionEntry(data: original, index: partitionIndex)
        let (mutated, result) = try deleteRootFile(
            imageData: original,
            partition: partition,
            fileName: remoteName
        )
        try atomicWrite(mutated, to: imageURL)
        return result
    }

    // MARK: - helpers

    private struct VolumeContext {
        var boot: Int
        var volEnd: Int
        var bpb: HddBPB
        var fatBytes: Int
        var fat1Abs: Int
        var fat2Abs: Int
        var fat: FAT16BE
        var rootAbs: Int
        var rootBytes: Int
    }

    private static func volumeContext(image: Data, partition: PartitionEntry) throws -> VolumeContext {
        let boot = partition.bootOffset
        let volEnd: Int
        if partition.recordCount > 0 {
            volEnd = min(image.count, boot + partition.byteLength)
        } else {
            volEnd = image.count
        }
        guard boot >= 0, boot < volEnd else {
            throw X68Error.format("Invalid partition boot offset")
        }
        let volumeSlice = image.subdata(in: boot..<volEnd)
        let bpb = try HddBPB.parse(volume: volumeSlice)
        let fatBytes = bpb.fatSizeSectors * bpb.bytesPerSector
        let fat1Abs = boot + bpb.reservedSectors * bpb.bytesPerSector
        let fat2Abs = fat1Abs + fatBytes
        guard fat1Abs + fatBytes <= volEnd, fat2Abs + fatBytes <= volEnd else {
            throw X68Error.format("FAT region out of partition")
        }
        let fat = FAT16BE(
            table: image.subdata(in: fat1Abs..<(fat1Abs + fatBytes)),
            maxClusters: max(2, fatBytes / 2 - 1)
        )
        let rootAbs = boot + bpb.rootDirOffsetInVolume
        let rootBytes = bpb.rootEntryCount * DirEntry.size
        guard rootAbs + rootBytes <= volEnd else {
            throw X68Error.format("Root directory out of partition")
        }
        return VolumeContext(
            boot: boot,
            volEnd: volEnd,
            bpb: bpb,
            fatBytes: fatBytes,
            fat1Abs: fat1Abs,
            fat2Abs: fat2Abs,
            fat: fat,
            rootAbs: rootAbs,
            rootBytes: rootBytes
        )
    }

    private static func partitionEntry(data: Data, index: Int) throws -> PartitionEntry {
        let detection = ImageDetector.detect(data: data)
        switch detection.kind {
        case .hds:
            let parts = try HdsImage(data: data).partitions
            guard index >= 0, index < parts.count else {
                throw X68Error.filesystem("Partition index out of range: \(index)")
            }
            return parts[index]
        case .hdf:
            let parts = try HdfImage(data: data).partitions
            guard index >= 0, index < parts.count else {
                throw X68Error.filesystem("Partition index out of range: \(index)")
            }
            return parts[index]
        default:
            throw X68Error.unsupported(
                "HDD write helpers support HDS/HDF only (got \(detection.kind.rawValue))"
            )
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).x68drv-inject-\(UUID().uuidString).tmp"
        )
        try data.write(to: tmp, options: [.atomic])
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        // Best-effort fsync of parent (replaceItemAt already durable enough for Stage A).
    }

    private static func namesEqual(_ a: HumanFileName, _ b: HumanFileName) -> Bool {
        a.stem.uppercased() == b.stem.uppercased() && a.ext.uppercased() == b.ext.uppercased()
    }
}
