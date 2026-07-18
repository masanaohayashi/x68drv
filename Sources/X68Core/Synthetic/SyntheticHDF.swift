import Foundation

/// Minimal `hdf-sasi-x68k-256` image for tests (not XM6 40MB unless requested).
public enum SyntheticHDF {
    public static let physSector = 256
    /// Partition 0 starts at LBA 33 → boot 0x2100 (matches real HD.hdf).
    public static let partition0StartLBA: UInt32 = 33

    /// Compact synthetic image large enough for one small BE FAT16 volume.
    public static func makeWithFile(
        fileName: HumanFileName,
        contents: Data,
        totalSectors: Int = 800
    ) throws -> Data {
        let imageSize = totalSectors * physSector
        var image = Data(repeating: 0, count: imageSize)

        // IPL stub
        image[0] = 0x60
        image[1] = 0x00

        // Partition table at 0x400
        let pt = 0x400
        image[pt] = 0x58
        image[pt + 1] = 0x36
        image[pt + 2] = 0x38
        image[pt + 3] = 0x4B
        let ent = pt + 0x10
        let name = Array("Human68k".utf8)
        for (i, b) in name.enumerated() { image[ent + i] = b }
        try Endian.writeUInt32BE(partition0StartLBA, to: &image, at: ent + 8)
        let count = UInt32(totalSectors - Int(partition0StartLBA))
        try Endian.writeUInt32BE(count, to: &image, at: ent + 12)

        // Volume at start * 256 — reuse HDS-style BE volume writer via raw layout
        try writeBEVolume(
            into: &image,
            bootOffset: Int(partition0StartLBA) * physSector,
            volumeBytes: Int(count) * physSector,
            file: (fileName, contents)
        )
        return image
    }

    private static func writeBEVolume(
        into image: inout Data,
        bootOffset: Int,
        volumeBytes: Int,
        file: (HumanFileName, Data)?
    ) throws {
        let bps = 1024
        let spc = 1
        let reserved = 1
        let fatCount = 2
        let fatSize = 2
        let rootEntries = 192
        let rootSectors = (rootEntries * 32 + bps - 1) / bps
        let boot = bootOffset
        guard boot + volumeBytes <= image.count else {
            throw X68Error.limit("HDF volume exceeds image")
        }
        for i in boot..<(boot + volumeBytes) { image[i] = 0 }

        image[boot] = 0x60
        image[boot + 1] = 0x20
        try Endian.writeUInt16BE(UInt16(bps), to: &image, at: boot + 0x12)
        image[boot + 0x14] = UInt8(spc)
        image[boot + 0x15] = UInt8(fatCount)
        try Endian.writeUInt16BE(UInt16(reserved), to: &image, at: boot + 0x16)
        try Endian.writeUInt16BE(UInt16(rootEntries), to: &image, at: boot + 0x18)
        image[boot + 0x1C] = 0xF8
        image[boot + 0x1D] = UInt8(fatSize)
        let partRecords = UInt32(volumeBytes / bps)
        try Endian.writeUInt32BE(partRecords, to: &image, at: boot + 0x1E)
        try Endian.writeUInt32BE(UInt32(boot / bps), to: &image, at: boot + 0x22)

        let fat1 = boot + reserved * bps
        let fat2 = fat1 + fatSize * bps
        image[fat1] = 0xFF
        image[fat1 + 1] = 0xF8
        image[fat1 + 2] = 0xFF
        image[fat1 + 3] = 0xFF
        image[fat2] = 0xFF
        image[fat2 + 1] = 0xF8
        image[fat2 + 2] = 0xFF
        image[fat2 + 3] = 0xFF

        let root = boot + (reserved + fatCount * fatSize) * bps
        let dataStart = root + rootSectors * bps

        guard let (fname, contents) = file else { return }
        let stemSJIS = try EncodingCP932.encode(fname.stem)
        let (dos8, _) = try HumanNamePacking.splitStemSJIS(stemSJIS)
        let (_, ext3) = try fname.packDiskFields()
        for i in 0..<8 { image[root + i] = dos8[i] }
        for i in 0..<3 { image[root + 8 + i] = ext3[i] }
        image[root + 11] = 0x20
        try Endian.writeUInt16LE(2, to: &image, at: root + 26)
        try Endian.writeUInt32LE(UInt32(contents.count), to: &image, at: root + 28)

        // EOF cluster 2 BE
        let c2 = fat1 + 4
        image[c2] = 0xFF
        image[c2 + 1] = 0xFF
        image[fat2 + 4] = 0xFF
        image[fat2 + 5] = 0xFF

        let limit = min(contents.count, bps)
        for i in 0..<limit {
            image[dataStart + i] = contents[i]
        }
    }
}
