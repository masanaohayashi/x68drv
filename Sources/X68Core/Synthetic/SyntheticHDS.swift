import Foundation

/// Builds a minimal SxSI/HDS-like image with X68SCSI1 + X68K partition table + empty BE volume.
public enum SyntheticHDS {
    public static let logicalRecord = 1024
    /// Partition 0 starts at record 32 → byte 0x8000 (scsitools typical).
    public static let partition0StartRecord: UInt32 = 32
    /// Enough bytes for header + one small volume region.
    public static let defaultImageSize = 0x8000 + 64 * logicalRecord // 0x8000 + 64KiB

    public static func makeMinimal(imageSize: Int = defaultImageSize) throws -> Data {
        guard imageSize >= 0x8000 + logicalRecord else {
            throw X68Error.limit("HDS synthetic image too small")
        }
        var image = Data(repeating: 0, count: imageSize)

        // SCSI header
        let magic = Array("X68SCSI1".utf8)
        for (i, b) in magic.enumerated() { image[i] = b }
        try Endian.writeUInt16BE(0x0200, to: &image, at: 0x08) // bytes/record field (512)
        // last record number (approx)
        let lastRecord = UInt32(imageSize / logicalRecord - 1)
        try Endian.writeUInt32BE(lastRecord, to: &image, at: 0x0A)
        try Endian.writeUInt16BE(0x0100, to: &image, at: 0x0E) // flags (opaque)
        let desc = Array("Human68K SCSI-DISK by x68drv synth".utf8)
        for (i, b) in desc.enumerated() where 0x10 + i < 0x40 {
            image[0x10 + i] = b
        }

        // IPL stub at 0x400
        image[0x400] = 0x60
        image[0x401] = 0x00

        // Partition table at 0x800
        let pt = 0x800
        image[pt] = 0x58 // X
        image[pt + 1] = 0x36 // 6
        image[pt + 2] = 0x38 // 8
        image[pt + 3] = 0x4B // K
        // Human68k entry at +0x10
        let ent = pt + 0x10
        let name = Array("Human68k".utf8)
        for (i, b) in name.enumerated() { image[ent + i] = b }
        try Endian.writeUInt32BE(partition0StartRecord, to: &image, at: ent + 8)
        let partRecords = UInt32((imageSize / logicalRecord) - Int(partition0StartRecord))
        try Endian.writeUInt32BE(partRecords, to: &image, at: ent + 12)

        // Partition boot / BE BPB at 0x8000
        let boot = Int(partition0StartRecord) * logicalRecord
        image[boot] = 0x60
        image[boot + 1] = 0x24
        let oem = Array("SHARP/KG".utf8)
        for (i, b) in oem.enumerated() where boot + 2 + i < boot + 0x12 {
            image[boot + 2 + i] = b
        }
        // BE BPB starting at +0x12 (bytes/sector, etc.)
        try Endian.writeUInt16BE(1024, to: &image, at: boot + 0x12) // bps
        image[boot + 0x14] = 1 // SPC
        image[boot + 0x15] = 2 // FAT count
        try Endian.writeUInt16BE(1, to: &image, at: boot + 0x16) // reserved
        try Endian.writeUInt16BE(192, to: &image, at: boot + 0x18) // root entries
        image[boot + 0x1C] = 0xF7 // media
        image[boot + 0x1D] = 2 // fat records (approx)
        try Endian.writeUInt32BE(partRecords, to: &image, at: boot + 0x1E)
        try Endian.writeUInt32BE(partition0StartRecord, to: &image, at: boot + 0x22)

        return image
    }
}
