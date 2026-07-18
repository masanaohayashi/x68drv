import Foundation

/// X68SCSI1 / SxSI container header (record 0).
public struct SxSIHeader: Equatable, Sendable {
    public var bytesPerRecordField: UInt16
    public var lastRecordNumber: UInt32
    public var flags: UInt16
    public var description: String
    public var hasSxSIMarkerInDescription: Bool

    public static let magic = Data("X68SCSI1".utf8)
    public static let logicalRecord = 1024

    public static func parse(_ data: Data) throws -> SxSIHeader {
        guard data.count >= 0x10 else {
            throw X68Error.format("Image too small for SCSI header")
        }
        guard Data(data[0..<8]) == magic else {
            throw X68Error.format("Missing X68SCSI1 signature")
        }
        let bpr = try Endian.readUInt16BE(data, at: 0x08)
        let last = try Endian.readUInt32BE(data, at: 0x0A)
        let flags = try Endian.readUInt16BE(data, at: 0x0E)
        let descData = data.count >= 0x40 ? Data(data[0x10..<0x40]) : Data(data[0x10...])
        let desc = EncodingCP932.decodeLossy(descData)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .trimmingCharacters(in: .whitespaces)
        let sxsi: Bool
        if data.count >= 0x2E {
            sxsi = Data(data[0x2A..<0x2E]) == Data("SxSI".utf8)
        } else {
            sxsi = desc.contains("SxSI")
        }
        return SxSIHeader(
            bytesPerRecordField: bpr,
            lastRecordNumber: last,
            flags: flags,
            description: desc,
            hasSxSIMarkerInDescription: sxsi
        )
    }
}

/// One X68K partition table entry (16 bytes).
public struct PartitionEntry: Equatable, Sendable {
    public var name: String
    /// Start in **1024-byte logical records** from image start.
    public var startRecord: UInt32
    public var recordCount: UInt32

    public var bootOffset: Int { Int(startRecord) * SxSIHeader.logicalRecord }
}

public enum PartitionTable {
    public static let magic = Data("X68K".utf8)
    /// Default location for 512-byte physical LBA4 → 0x800.
    public static let defaultOffset = 0x800
    public static let maxEntries = 15

    public static func parse(data: Data, at offset: Int = defaultOffset) throws -> [PartitionEntry] {
        guard data.count >= offset + 4 else {
            throw X68Error.format("Partition table out of range")
        }
        guard Data(data[offset..<(offset + 4)]) == magic else {
            throw X68Error.format("Missing X68K at 0x\(String(offset, radix: 16))")
        }
        var entries: [PartitionEntry] = []
        // Entries start at +0x10; scan 15 slots of 16 bytes.
        var o = offset + 0x10
        for _ in 0..<maxEntries {
            guard o + 16 <= data.count else { break }
            let nameBytes = Data(data[o..<(o + 8)])
            if nameBytes.allSatisfy({ $0 == 0 }) { break }
            let name = EncodingCP932.decodeLossy(nameBytes)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            let start = try Endian.readUInt32BE(data, at: o + 8)
            let count = try Endian.readUInt32BE(data, at: o + 12)
            if start == 0 && count == 0 { break }
            if !name.isEmpty {
                entries.append(PartitionEntry(name: name, startRecord: start, recordCount: count))
            }
            o += 16
        }
        return entries
    }
}
