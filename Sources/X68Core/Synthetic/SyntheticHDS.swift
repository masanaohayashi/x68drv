import Foundation

/// Builds copyright-free SxSI/HDS images with X68SCSI1 + X68K + BE FAT16 volumes.
public enum SyntheticHDS {
    public static let logicalRecord = 1024
    public static let partition0StartRecord: UInt32 = 32

    /// Empty single-partition image (BPB only, empty root).
    public static func makeMinimal(imageSize: Int = 0x8000 + 128 * logicalRecord) throws -> Data {
        try make(
            imageSize: imageSize,
            partitions: [
                PartitionSpec(
                    name: "Human68k",
                    startRecord: partition0StartRecord,
                    file: nil
                ),
            ]
        )
    }

    /// Single partition with one root file (ASCII 8.3).
    public static func makeWithFile(
        fileName: HumanFileName,
        contents: Data,
        imageSize: Int = 0x8000 + 256 * logicalRecord
    ) throws -> Data {
        try make(
            imageSize: imageSize,
            partitions: [
                PartitionSpec(
                    name: "Human68k",
                    startRecord: partition0StartRecord,
                    file: (fileName, contents)
                ),
            ]
        )
    }

    /// Two partitions (second empty) for multi-partition tests.
    public static func makeDualPartition(
        fileName: HumanFileName,
        contents: Data,
        imageSize: Int = 0x8000 + 400 * logicalRecord
    ) throws -> Data {
        let p0Start: UInt32 = 32
        let p0Count: UInt32 = 200
        let p1Start = p0Start + p0Count
        return try make(
            imageSize: imageSize,
            partitions: [
                PartitionSpec(name: "Human68k", startRecord: p0Start, recordCount: p0Count, file: (fileName, contents)),
                PartitionSpec(name: "DATA    ", startRecord: p1Start, recordCount: 100, file: nil),
            ]
        )
    }

    public struct PartitionSpec {
        var name: String
        var startRecord: UInt32
        var recordCount: UInt32?
        var file: (HumanFileName, Data)?

        init(name: String, startRecord: UInt32, recordCount: UInt32? = nil, file: (HumanFileName, Data)?) {
            self.name = name
            self.startRecord = startRecord
            self.recordCount = recordCount
            self.file = file
        }
    }

    public static func make(imageSize: Int, partitions: [PartitionSpec]) throws -> Data {
        guard imageSize >= 0x8000 + logicalRecord else {
            throw X68Error.limit("HDS synthetic image too small")
        }
        var image = Data(repeating: 0x00, count: imageSize)

        // Header
        let magic = Array("X68SCSI1".utf8)
        for (i, b) in magic.enumerated() { image[i] = b }
        try Endian.writeUInt16BE(0x0200, to: &image, at: 0x08)
        let lastRecord = UInt32(imageSize / logicalRecord - 1)
        try Endian.writeUInt32BE(lastRecord, to: &image, at: 0x0A)
        try Endian.writeUInt16BE(0x0100, to: &image, at: 0x0E)
        let desc = Array("Human68K SCSI-DISK by x68drv synth".utf8)
        for (i, b) in desc.enumerated() where 0x10 + i < 0x40 {
            image[0x10 + i] = b
        }

        image[0x400] = 0x60
        image[0x401] = 0x00

        // Partition table
        let pt = 0x800
        image[pt] = 0x58
        image[pt + 1] = 0x36
        image[pt + 2] = 0x38
        image[pt + 3] = 0x4B

        for (i, spec) in partitions.enumerated() {
            let ent = pt + 0x10 + i * 16
            var nameBytes = Array(spec.name.utf8.prefix(8))
            while nameBytes.count < 8 { nameBytes.append(0x20) }
            for (j, b) in nameBytes.enumerated() { image[ent + j] = b }
            try Endian.writeUInt32BE(spec.startRecord, to: &image, at: ent + 8)
            let count: UInt32
            if let c = spec.recordCount {
                count = c
            } else {
                count = UInt32((imageSize / logicalRecord) - Int(spec.startRecord))
            }
            try Endian.writeUInt32BE(count, to: &image, at: ent + 12)

            try writeVolume(
                into: &image,
                startRecord: Int(spec.startRecord),
                recordCount: Int(count),
                file: spec.file
            )
        }

        return image
    }

    /// Layout within partition (sector = 1024):
    /// 0 boot, 1 reserved done (res=1), FAT size 2 records × 2 FATs, root 6 records (192*32/1024), data…
    private static func writeVolume(
        into image: inout Data,
        startRecord: Int,
        recordCount: Int,
        file: (HumanFileName, Data)?
    ) throws {
        let bps = 1024
        let spc = 1
        let reserved = 1
        let fatCount = 2
        let fatSize = 2 // sectors per FAT
        let rootEntries = 192
        let rootSectors = (rootEntries * 32 + bps - 1) / bps // 6
        let boot = startRecord * logicalRecord
        guard boot + recordCount * logicalRecord <= image.count else {
            throw X68Error.limit("Partition exceeds image")
        }

        // Clear volume region with 0x00 (root free marker is 0x00)
        let volEnd = boot + recordCount * logicalRecord
        for i in boot..<volEnd { image[i] = 0x00 }

        // BE BPB
        image[boot] = 0x60
        image[boot + 1] = 0x24
        let oem = Array("SHARP/KG".utf8)
        for (i, b) in oem.enumerated() where boot + 2 + i < boot + 0x12 {
            image[boot + 2 + i] = b
        }
        try Endian.writeUInt16BE(UInt16(bps), to: &image, at: boot + 0x12)
        image[boot + 0x14] = UInt8(spc)
        image[boot + 0x15] = UInt8(fatCount)
        try Endian.writeUInt16BE(UInt16(reserved), to: &image, at: boot + 0x16)
        try Endian.writeUInt16BE(UInt16(rootEntries), to: &image, at: boot + 0x18)
        image[boot + 0x1C] = 0xF7
        image[boot + 0x1D] = UInt8(fatSize)
        try Endian.writeUInt32BE(UInt32(recordCount), to: &image, at: boot + 0x1E)
        try Endian.writeUInt32BE(UInt32(startRecord), to: &image, at: boot + 0x22)

        let fat1 = boot + reserved * bps
        let fat2 = fat1 + fatSize * bps
        // Media + EOF for clusters 0/1 in BE FAT16
        writeFAT16BEMedia(&image, at: fat1, media: 0xF7)
        writeFAT16BEMedia(&image, at: fat2, media: 0xF7)

        let root = boot + (reserved + fatCount * fatSize) * bps
        let dataStart = root + rootSectors * bps

        guard let (name, contents) = file else { return }

        // Root entry
        let stemSJIS = try EncodingCP932.encode(name.stem)
        let (dos8, _) = try HumanNamePacking.splitStemSJIS(stemSJIS)
        let (_, ext3) = try name.packDiskFields()
        for i in 0..<8 { image[root + i] = dos8[i] }
        for i in 0..<3 { image[root + 8 + i] = ext3[i] }
        image[root + 11] = 0x20
        try Endian.writeUInt16LE(2, to: &image, at: root + 26) // cluster LE
        try Endian.writeUInt32LE(UInt32(contents.count), to: &image, at: root + 28)

        // Cluster 2 = EOF in both FATs
        setFAT16BE(&image, fatOffset: fat1, cluster: 2, value: 0xFFFF)
        setFAT16BE(&image, fatOffset: fat2, cluster: 2, value: 0xFFFF)

        let limit = min(contents.count, bps * spc)
        for i in 0..<limit {
            image[dataStart + i] = contents[i]
        }
    }

    private static func writeFAT16BEMedia(_ image: inout Data, at offset: Int, media: UInt8) {
        // cluster 0: 0xFF00 | media (common), cluster 1: 0xFFFF
        image[offset] = 0xFF
        image[offset + 1] = media
        image[offset + 2] = 0xFF
        image[offset + 3] = 0xFF
    }

    private static func setFAT16BE(_ image: inout Data, fatOffset: Int, cluster: Int, value: Int) {
        let index = fatOffset + cluster * 2
        image[index] = UInt8((value >> 8) & 0xFF)
        image[index + 1] = UInt8(value & 0xFF)
    }
}
