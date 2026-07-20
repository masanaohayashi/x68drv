import Foundation

/// Builds a copyright-free classic 2HD XDF image (1,261,568 bytes) with LE FAT12.
public enum SyntheticXDF {
    public static let byteSize = 1_261_568
    public static let bytesPerSector = 1024
    public static let sectorsPerTrack = 8
    public static let heads = 2
    public static let cylinders = 77

    /// Full 1232KB 2HD image: LE BPB, dual FAT12, 192 root entries, empty data area (0xE5).
    public static func makeEmpty2HD() throws -> Data {
        var image = Data(repeating: 0xE5, count: byteSize)

        // Boot sector / LE BPB (DOS-compatible layout used by Human68k floppies).
        image[0] = 0x60
        image[1] = 0x3C
        // OEM-ish
        let oem = Array("X68IPL30".utf8)
        for (i, b) in oem.enumerated() where 2 + i < 11 {
            image[2 + i] = b
        }

        try Endian.writeUInt16LE(UInt16(bytesPerSector), to: &image, at: 0x0B) // bps
        image[0x0D] = 1 // SPC
        try Endian.writeUInt16LE(1, to: &image, at: 0x0E) // reserved sectors
        image[0x10] = 2 // FAT count
        try Endian.writeUInt16LE(192, to: &image, at: 0x11) // root entries
        try Endian.writeUInt16LE(1232, to: &image, at: 0x13) // total sectors
        image[0x15] = 0xFE // media
        try Endian.writeUInt16LE(2, to: &image, at: 0x16) // FAT size in sectors
        try Endian.writeUInt16LE(UInt16(sectorsPerTrack), to: &image, at: 0x18)
        try Endian.writeUInt16LE(UInt16(heads), to: &image, at: 0x1A)

        // FAT #1 and #2 at sector 1 and 3 (after 1 reserved).
        let fat1 = bytesPerSector * 1
        let fat2 = bytesPerSector * 3
        writeEmptyFAT12(to: &image, at: fat1, media: 0xFE)
        writeEmptyFAT12(to: &image, at: fat2, media: 0xFE)

        // Root directory starts at sector 5 → offset 0x1400; leave 0xE5 (empty).
        // Data region follows root (192 * 32 = 6144 = 6 sectors) → sector 11.

        return image
    }

    /// Full image with a single file in the root (contents written into first data cluster).
    public static func make2HD(fileName: HumanFileName, contents: Data) throws -> Data {
        var image = try makeEmpty2HD()
        let (stem18, ext3) = try fileName.packDiskFields()

        // Root entry 0 at 0x1400
        let root = 0x1400
        // Classic 8.3 at 0..10, Human68k also uses extra name space — store first 8 of stem + 3 ext for DOS field.
        let stemSJIS = try EncodingCP932.encode(fileName.stem)
        let (dos8, _) = try HumanNamePacking.splitStemSJIS(stemSJIS)
        for i in 0..<8 { image[root + i] = dos8[i] }
        for i in 0..<3 { image[root + 8 + i] = ext3[i] }
        image[root + 11] = 0x20 // ATTR_ARCHIVE
        // 1993-09-15 12:00:00 local (matches classic Human68k sample dates)
        try Endian.writeUInt16LE(0x6000, to: &image, at: root + 22) // wtime
        try Endian.writeUInt16LE(0x1B2F, to: &image, at: root + 24) // wdate
        // cluster LE at 26, size LE at 28
        try Endian.writeUInt16LE(2, to: &image, at: root + 26) // first cluster
        try Endian.writeUInt32LE(UInt32(contents.count), to: &image, at: root + 28)

        // Also write 18-byte stem into name2 area if we use extended layout later;
        // for classic FAT tools, 8.3 is enough for Phase 1.

        // Mark cluster 2 as EOF in both FATs
        let fat1 = bytesPerSector
        setFAT12(image: &image, fatOffset: fat1, cluster: 2, value: 0xFFF)
        setFAT12(image: &image, fatOffset: fat1 + bytesPerSector * 2, cluster: 2, value: 0xFFF)

        // Data starts after reserved(1)+fat(2*2)+root(6) = 11 sectors
        let dataStart = bytesPerSector * 11
        let limit = min(contents.count, bytesPerSector) // 1 cluster = 1 sector when SPC=1
        for i in 0..<limit {
            image[dataStart + i] = contents[i]
        }

        // Keep stem18 available for tests that inspect packing only.
        _ = stem18
        return image
    }

    private static func writeEmptyFAT12(to image: inout Data, at offset: Int, media: UInt8) {
        // Zero the whole FAT (2 sectors) so free clusters read as 0, not 0xE5 fill.
        let fatBytes = bytesPerSector * 2
        for i in 0..<fatBytes {
            image[offset + i] = 0
        }
        // Media + 0xFFF for cluster 0/1
        image[offset] = media
        image[offset + 1] = 0xFF
        image[offset + 2] = 0xFF
    }

    private static func setFAT12(image: inout Data, fatOffset: Int, cluster: Int, value: Int) {
        // FAT12 entry packing
        let v = value & 0xFFF
        let index = fatOffset + (cluster * 3) / 2
        if cluster & 1 == 0 {
            image[index] = UInt8(v & 0xFF)
            image[index + 1] = (image[index + 1] & 0xF0) | UInt8((v >> 8) & 0x0F)
        } else {
            image[index] = (image[index] & 0x0F) | UInt8((v << 4) & 0xF0)
            image[index + 1] = UInt8((v >> 4) & 0xFF)
        }
    }
}
