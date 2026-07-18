import Foundation

/// Experimental write helpers for Human68k HDD volumes (HDS/HDF, BE FAT16).
///
/// **Not** product FUSE write. Mutates a full image buffer and returns it.
///
/// - **Inject**: data clusters → FAT → directory entry
/// - **Delete**: directory 0xE5 → free FAT
/// - **Mkdir**: dir cluster (`.` / `..`) → FAT → parent entry
///
/// Stage A/B: root. Stage C: subdirectories + path-aware inject/delete.
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

    public struct MkdirResult: Equatable, Sendable {
        public var remoteName: String
        public var firstCluster: Int
    }

    // MARK: - Public inject

    /// Inject into root (Stage A API).
    public static func injectRootFile(
        imageData: Data,
        partition: PartitionEntry,
        fileName: HumanFileName,
        contents: Data,
        overwrite: Bool = false
    ) throws -> (image: Data, result: Result) {
        try injectFile(
            imageData: imageData,
            partition: partition,
            path: HumanPath(components: [fileName]),
            contents: contents,
            overwrite: overwrite
        )
    }

    /// Inject a file at `path` (last component = name). Parents must already exist.
    public static func injectFile(
        imageData: Data,
        partition: PartitionEntry,
        path: HumanPath,
        contents: Data,
        overwrite: Bool = false
    ) throws -> (image: Data, result: Result) {
        guard let leaf = path.components.last else {
            throw X68Error.filesystem("Empty inject path")
        }
        let parentPath = HumanPath(components: Array(path.components.dropLast()))
        var image = imageData
        var ctx = try volumeContext(image: image, partition: partition)
        let parent = try resolveDirectory(image: image, ctx: &ctx, path: parentPath)

        let scan = try scanDirTable(
            image: image,
            ctx: ctx,
            table: parent,
            match: leaf
        )

        var fat = ctx.fat
        var overwritten = false
        var slot = scan.freeSlot

        if let existing = scan.existingFile {
            guard overwrite else {
                throw X68Error.filesystem(
                    "File exists: \(path.display) (pass overwrite to replace)"
                )
            }
            if existing.entry.firstCluster >= 2 {
                let old = try fat.chain(from: Int(existing.entry.firstCluster))
                try fat.freeChain(old)
            }
            slot = existing.offset
            overwritten = true
        } else if scan.existingDir != nil {
            throw X68Error.filesystem("Path is a directory: \(leaf.display)")
        }

        guard let slotOffset = slot else {
            throw X68Error.limit("Directory full: \(parentPath.display.isEmpty ? "/" : parentPath.display)")
        }

        let bpc = ctx.bpb.bytesPerCluster
        let clusterCount = contents.isEmpty ? 0 : (contents.count + bpc - 1) / bpc
        let chain: [Int]
        if clusterCount == 0 {
            chain = []
        } else {
            chain = try fat.allocateChain(count: clusterCount)
        }

        // 1) File data
        try writeClusterPayload(
            image: &image,
            ctx: ctx,
            chain: chain,
            contents: contents
        )

        // 2–3) FAT
        writeFAT(image: &image, ctx: ctx, fat: fat)

        // 4) Dir entry
        let first: UInt16 = chain.first.map { UInt16($0) } ?? 0
        let packed = try DirEntry.pack(
            name: leaf,
            attributes: 0x20,
            firstCluster: first,
            size: UInt32(contents.count)
        )
        image.replaceSubrange(slotOffset..<(slotOffset + DirEntry.size), with: packed)

        return (
            image,
            Result(
                remoteName: path.display,
                bytesWritten: contents.count,
                firstCluster: Int(first),
                clusterCount: chain.count,
                overwritten: overwritten
            )
        )
    }

    @discardableResult
    public static func injectRootFileToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        hostFileURL: URL,
        remoteName: HumanFileName,
        overwrite: Bool = false
    ) throws -> Result {
        try injectFileToURL(
            imageURL: imageURL,
            partitionIndex: partitionIndex,
            hostFileURL: hostFileURL,
            remotePath: HumanPath(components: [remoteName]),
            overwrite: overwrite
        )
    }

    @discardableResult
    public static func injectFileToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        hostFileURL: URL,
        remotePath: HumanPath,
        overwrite: Bool = false
    ) throws -> Result {
        let contents = try Data(contentsOf: hostFileURL)
        let original = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        let partition = try partitionEntry(data: original, index: partitionIndex)
        let (mutated, result) = try injectFile(
            imageData: original,
            partition: partition,
            path: remotePath,
            contents: contents,
            overwrite: overwrite
        )
        try atomicWrite(mutated, to: imageURL)
        return result
    }

    // MARK: - Delete

    public static func deleteRootFile(
        imageData: Data,
        partition: PartitionEntry,
        fileName: HumanFileName
    ) throws -> (image: Data, result: DeleteResult) {
        try deleteFile(
            imageData: imageData,
            partition: partition,
            path: HumanPath(components: [fileName])
        )
    }

    public static func deleteFile(
        imageData: Data,
        partition: PartitionEntry,
        path: HumanPath
    ) throws -> (image: Data, result: DeleteResult) {
        guard let leaf = path.components.last else {
            throw X68Error.filesystem("Empty delete path")
        }
        let parentPath = HumanPath(components: Array(path.components.dropLast()))
        var image = imageData
        var ctx = try volumeContext(image: image, partition: partition)
        let parent = try resolveDirectory(image: image, ctx: &ctx, path: parentPath)
        let scan = try scanDirTable(image: image, ctx: ctx, table: parent, match: leaf)

        guard let target = scan.existingFile else {
            if scan.existingDir != nil {
                throw X68Error.filesystem("Refusing to delete directory: \(path.display)")
            }
            throw X68Error.filesystem("File not found: \(path.display)")
        }

        var fat = ctx.fat
        // 1) Dir first
        var slot = image.subdata(in: target.offset..<(target.offset + DirEntry.size))
        slot = DirEntry.markDeleted(slot)
        image.replaceSubrange(target.offset..<(target.offset + DirEntry.size), with: slot)

        // 2) Free FAT
        var freed = 0
        if target.entry.firstCluster >= 2 {
            let chain = try fat.chain(from: Int(target.entry.firstCluster))
            try fat.freeChain(chain)
            freed = chain.count
        }
        writeFAT(image: &image, ctx: ctx, fat: fat)

        return (image, DeleteResult(remoteName: path.display, freedClusters: freed))
    }

    @discardableResult
    public static func deleteRootFileToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        remoteName: HumanFileName
    ) throws -> DeleteResult {
        try deleteFileToURL(
            imageURL: imageURL,
            partitionIndex: partitionIndex,
            remotePath: HumanPath(components: [remoteName])
        )
    }

    @discardableResult
    public static func deleteFileToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        remotePath: HumanPath
    ) throws -> DeleteResult {
        let original = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        let partition = try partitionEntry(data: original, index: partitionIndex)
        let (mutated, result) = try deleteFile(
            imageData: original,
            partition: partition,
            path: remotePath
        )
        try atomicWrite(mutated, to: imageURL)
        return result
    }

    // MARK: - Mkdir

    /// Create a subdirectory under `parentPath` (empty path = root).
    public static func mkdir(
        imageData: Data,
        partition: PartitionEntry,
        parentPath: HumanPath = HumanPath(),
        name: HumanFileName
    ) throws -> (image: Data, result: MkdirResult) {
        var image = imageData
        var ctx = try volumeContext(image: image, partition: partition)
        let parent = try resolveDirectory(image: image, ctx: &ctx, path: parentPath)
        let parentCluster: UInt16 = {
            switch parent {
            case .root: return 0
            case .clusters(let c, _): return UInt16(c.first ?? 0)
            }
        }()

        let scan = try scanDirTable(image: image, ctx: ctx, table: parent, match: name)
        if scan.existingFile != nil || scan.existingDir != nil {
            throw X68Error.filesystem("Already exists: \(name.display)")
        }
        guard let slot = scan.freeSlot else {
            throw X68Error.limit("Directory full")
        }

        var fat = ctx.fat
        let chain = try fat.allocateChain(count: 1)
        let dirCluster = chain[0]
        let bpc = ctx.bpb.bytesPerCluster

        // Initialize directory cluster: . and .. then zeros
        var dirData = Data(count: bpc)
        let dot = try DirEntry.pack(
            name: HumanFileName(stem: ".", ext: ""),
            attributes: 0x10,
            firstCluster: UInt16(dirCluster),
            size: 0
        )
        let dotdot = try DirEntry.pack(
            name: HumanFileName(stem: "..", ext: ""),
            attributes: 0x10,
            firstCluster: parentCluster,
            size: 0
        )
        dirData.replaceSubrange(0..<DirEntry.size, with: dot)
        dirData.replaceSubrange(DirEntry.size..<(2 * DirEntry.size), with: dotdot)

        let sector = ctx.bpb.firstDataSector + (dirCluster - 2) * ctx.bpb.sectorsPerCluster
        let abs = ctx.boot + sector * ctx.bpb.bytesPerSector
        guard abs + bpc <= ctx.volEnd else {
            throw X68Error.outOfBounds(offset: abs, size: bpc, available: ctx.volEnd)
        }
        image.replaceSubrange(abs..<(abs + bpc), with: dirData)

        writeFAT(image: &image, ctx: ctx, fat: fat)

        let packed = try DirEntry.pack(
            name: name,
            attributes: 0x10,
            firstCluster: UInt16(dirCluster),
            size: 0
        )
        image.replaceSubrange(slot..<(slot + DirEntry.size), with: packed)

        let display = parentPath.components.isEmpty
            ? name.display
            : "\(parentPath.display)/\(name.display)"
        return (image, MkdirResult(remoteName: display, firstCluster: dirCluster))
    }

    @discardableResult
    public static func mkdirToURL(
        imageURL: URL,
        partitionIndex: Int = 0,
        parentPath: HumanPath = HumanPath(),
        name: HumanFileName
    ) throws -> MkdirResult {
        let original = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        let partition = try partitionEntry(data: original, index: partitionIndex)
        let (mutated, result) = try mkdir(
            imageData: original,
            partition: partition,
            parentPath: parentPath,
            name: name
        )
        try atomicWrite(mutated, to: imageURL)
        return result
    }

    // MARK: - Directory table resolution

    private enum DirTable {
        case root
        /// Cluster chain of a subdirectory + entry count capacity.
        case clusters([Int], entryCapacity: Int)
    }

    private struct ScanResult {
        var freeSlot: Int?
        var existingFile: (offset: Int, entry: DirEntry)?
        var existingDir: (offset: Int, entry: DirEntry)?
    }

    private static func resolveDirectory(
        image: Data,
        ctx: inout VolumeContext,
        path: HumanPath
    ) throws -> DirTable {
        if path.components.isEmpty {
            return .root
        }
        var table: DirTable = .root
        for component in path.components {
            let scan = try scanDirTable(image: image, ctx: ctx, table: table, match: component)
            guard let dir = scan.existingDir else {
                throw X68Error.filesystem("Directory not found: \(component.display)")
            }
            let start = Int(dir.entry.firstCluster)
            guard start >= 2 else {
                throw X68Error.filesystem("Invalid directory cluster for \(component.display)")
            }
            let chain = try ctx.fat.chain(from: start)
            let cap = (chain.count * ctx.bpb.bytesPerCluster) / DirEntry.size
            table = .clusters(chain, entryCapacity: cap)
        }
        return table
    }

    private static func scanDirTable(
        image: Data,
        ctx: VolumeContext,
        table: DirTable,
        match: HumanFileName
    ) throws -> ScanResult {
        var freeSlot: Int?
        var existingFile: (offset: Int, entry: DirEntry)?
        var existingDir: (offset: Int, entry: DirEntry)?

        let entryCount: Int
        switch table {
        case .root:
            entryCount = ctx.rootBytes / DirEntry.size
        case .clusters(_, let cap):
            entryCount = cap
        }

        for i in 0..<entryCount {
            let abs = try entryAbsoluteOffset(image: image, ctx: ctx, table: table, index: i)
            let entry = try DirEntry.parse(image, at: abs)
            if entry.isEnd {
                if freeSlot == nil { freeSlot = abs }
                break
            }
            if entry.isDeleted {
                if freeSlot == nil { freeSlot = abs }
                continue
            }
            if namesEqual(entry.name, match) {
                if entry.isFile {
                    existingFile = (abs, entry)
                } else if entry.isDirectory {
                    existingDir = (abs, entry)
                }
            }
        }
        return ScanResult(freeSlot: freeSlot, existingFile: existingFile, existingDir: existingDir)
    }

    private static func entryAbsoluteOffset(
        image: Data,
        ctx: VolumeContext,
        table: DirTable,
        index: Int
    ) throws -> Int {
        switch table {
        case .root:
            return ctx.rootAbs + index * DirEntry.size
        case .clusters(let chain, _):
            let byteOff = index * DirEntry.size
            let bpc = ctx.bpb.bytesPerCluster
            let ci = byteOff / bpc
            let within = byteOff % bpc
            guard ci < chain.count else {
                throw X68Error.filesystem("Directory index out of range")
            }
            let cluster = chain[ci]
            let sector = ctx.bpb.firstDataSector + (cluster - 2) * ctx.bpb.sectorsPerCluster
            return ctx.boot + sector * ctx.bpb.bytesPerSector + within
        }
    }

    private static func writeClusterPayload(
        image: inout Data,
        ctx: VolumeContext,
        chain: [Int],
        contents: Data
    ) throws {
        let bpc = ctx.bpb.bytesPerCluster
        for (i, cluster) in chain.enumerated() {
            let sector = ctx.bpb.firstDataSector + (cluster - 2) * ctx.bpb.sectorsPerCluster
            let offset = ctx.boot + sector * ctx.bpb.bytesPerSector
            guard offset + bpc <= ctx.volEnd else {
                throw X68Error.outOfBounds(offset: offset, size: bpc, available: ctx.volEnd)
            }
            let start = i * bpc
            let end = min(start + bpc, contents.count)
            var chunk = Data(count: bpc)
            if start < end {
                chunk.replaceSubrange(0..<(end - start), with: contents[start..<end])
            }
            image.replaceSubrange(offset..<(offset + bpc), with: chunk)
        }
    }

    private static func writeFAT(image: inout Data, ctx: VolumeContext, fat: FAT16BE) {
        image.replaceSubrange(ctx.fat1Abs..<(ctx.fat1Abs + ctx.fatBytes), with: fat.table)
        if ctx.bpb.fatCount >= 2 {
            image.replaceSubrange(ctx.fat2Abs..<(ctx.fat2Abs + ctx.fatBytes), with: fat.table)
        }
    }

    // MARK: - Volume context

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
    }

    private static func namesEqual(_ a: HumanFileName, _ b: HumanFileName) -> Bool {
        a.stem.uppercased() == b.stem.uppercased() && a.ext.uppercased() == b.ext.uppercased()
    }
}
