import Foundation

/// Human68k HDD big-endian BPB (not MS-DOS compatible).
///
/// Field layout from design.md / scsitools `write_boot_sector`.
public struct HddBPB: Equatable, Sendable {
    public var bytesPerSector: Int
    public var sectorsPerCluster: Int
    public var fatCount: Int
    public var reservedSectors: Int
    public var rootEntryCount: Int
    public var media: UInt8
    public var fatSizeSectors: Int
    public var partitionRecordCount: UInt32
    public var partitionStartRecord: UInt32

    public var rootDirSectors: Int {
        (rootEntryCount * 32 + bytesPerSector - 1) / bytesPerSector
    }

    public var firstRootSector: Int {
        reservedSectors + fatCount * fatSizeSectors
    }

    public var firstDataSector: Int {
        firstRootSector + rootDirSectors
    }

    public var rootDirOffsetInVolume: Int {
        firstRootSector * bytesPerSector
    }

    public var bytesPerCluster: Int {
        bytesPerSector * sectorsPerCluster
    }

    /// Parse BE BPB at the start of a partition volume (`boot` sector).
    public static func parse(volume: Data) throws -> HddBPB {
        guard volume.count >= 0x26 else {
            throw X68Error.format("HDD volume too small for BE BPB")
        }
        // Prefer scsitools offsets at +0x12.
        let bps = Int(try Endian.readUInt16BE(volume, at: 0x12))
        let spc = Int(volume[0x14])
        let fats = Int(volume[0x15])
        let reserved = Int(try Endian.readUInt16BE(volume, at: 0x16))
        let root = Int(try Endian.readUInt16BE(volume, at: 0x18))
        let media = volume[0x1C]
        let fatSec = Int(volume[0x1D])
        let partCount = try Endian.readUInt32BE(volume, at: 0x1E)
        let partStart = try Endian.readUInt32BE(volume, at: 0x22)

        guard [256, 512, 1024, 2048].contains(bps) else {
            throw X68Error.format("Invalid HDD bps BE: \(bps)")
        }
        guard spc >= 1, fats >= 1, reserved >= 1, root > 0, fatSec >= 1 else {
            throw X68Error.format(
                "Invalid HDD BPB (spc=\(spc) fats=\(fats) res=\(reserved) root=\(root) fat=\(fatSec))"
            )
        }

        return HddBPB(
            bytesPerSector: bps,
            sectorsPerCluster: spc,
            fatCount: fats,
            reservedSectors: reserved,
            rootEntryCount: root,
            media: media,
            fatSizeSectors: fatSec,
            partitionRecordCount: partCount,
            partitionStartRecord: partStart
        )
    }
}
