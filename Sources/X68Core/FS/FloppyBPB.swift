import Foundation

/// Little-endian DOS-compatible BPB used by Human68k floppies (XDF/DIM).
public struct FloppyBPB: Equatable, Sendable {
    public var bytesPerSector: Int
    public var sectorsPerCluster: Int
    public var reservedSectors: Int
    public var fatCount: Int
    public var rootEntryCount: Int
    public var totalSectors: Int
    public var media: UInt8
    public var fatSizeSectors: Int
    public var usedFallback: Bool

    public var rootDirSectors: Int {
        (rootEntryCount * 32 + bytesPerSector - 1) / bytesPerSector
    }

    public var fatRegionSectors: Int { fatCount * fatSizeSectors }

    public var firstRootSector: Int { reservedSectors + fatRegionSectors }

    public var firstDataSector: Int { firstRootSector + rootDirSectors }

    public var rootDirOffset: Int { firstRootSector * bytesPerSector }

    public var bytesPerCluster: Int { bytesPerSector * sectorsPerCluster }

    /// Parse LE BPB at volume start, or apply classic 2HD defaults if invalid.
    public static func parse(volume: Data, allow2HDFallback: Bool = true) throws -> FloppyBPB {
        guard volume.count >= 0x18 else {
            throw X68Error.format("Volume too small for BPB")
        }

        let bps = Int(try Endian.readUInt16LE(volume, at: 0x0B))
        let spc = Int(volume[0x0D])
        let reserved = Int(try Endian.readUInt16LE(volume, at: 0x0E))
        let fats = Int(volume[0x10])
        let root = Int(try Endian.readUInt16LE(volume, at: 0x11))
        let total = Int(try Endian.readUInt16LE(volume, at: 0x13))
        let media = volume[0x15]
        let fatSec = Int(try Endian.readUInt16LE(volume, at: 0x16))

        if isPlausible(bps: bps, spc: spc, reserved: reserved, fats: fats, root: root, fatSec: fatSec, total: total) {
            return FloppyBPB(
                bytesPerSector: bps,
                sectorsPerCluster: spc,
                reservedSectors: reserved,
                fatCount: fats,
                rootEntryCount: root,
                totalSectors: total == 0 ? volume.count / max(bps, 1) : total,
                media: media,
                fatSizeSectors: fatSec,
                usedFallback: false
            )
        }

        if allow2HDFallback, volume.count == ImageDetector.xdf2HDSize || volume.count >= ImageDetector.xdf2HDSize {
            // Classic Human68k 2HD layout (OSR2 / Disk2).
            return FloppyBPB(
                bytesPerSector: 1024,
                sectorsPerCluster: 1,
                reservedSectors: 1,
                fatCount: 2,
                rootEntryCount: 192,
                totalSectors: 1232,
                media: 0xFE,
                fatSizeSectors: 2,
                usedFallback: true
            )
        }

        throw X68Error.format(
            "Invalid floppy BPB (bps=\(bps) spc=\(spc) fats=\(fats) root=\(root) fatSec=\(fatSec))"
        )
    }

    private static func isPlausible(
        bps: Int,
        spc: Int,
        reserved: Int,
        fats: Int,
        root: Int,
        fatSec: Int,
        total: Int
    ) -> Bool {
        let validBPS = [128, 256, 512, 1024, 2048, 4096].contains(bps)
        return validBPS
            && spc >= 1 && spc <= 64
            && reserved >= 1 && reserved < 64
            && fats >= 1 && fats <= 4
            && root > 0 && root <= 1024
            && fatSec >= 1 && fatSec < 256
            && (total == 0 || total >= 16)
    }
}
