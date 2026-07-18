import Foundation

/// 32-byte directory entry (DOS layout; Human68k floppies use LE fields).
public struct DirEntry: Equatable, Sendable {
    public var name: HumanFileName
    public var attributes: UInt8
    public var firstCluster: UInt16
    public var size: UInt32
    public var isDeleted: Bool
    public var isEnd: Bool

    public var isDirectory: Bool { attributes & 0x10 != 0 }
    public var isVolumeLabel: Bool { attributes & 0x08 != 0 }
    public var isFile: Bool { !isDirectory && !isVolumeLabel && !isDeleted && !isEnd }

    public static let size = 32

    public static func parse(_ data: Data, at offset: Int) throws -> DirEntry {
        try require(data, offset: offset, count: size)
        let first = data[offset]
        if first == 0x00 {
            return DirEntry(
                name: HumanFileName(stem: "", ext: ""),
                attributes: 0,
                firstCluster: 0,
                size: 0,
                isDeleted: false,
                isEnd: true
            )
        }
        let deleted = first == 0xE5
        let nameBytes = Data(data[(offset)..<(offset + 8)])
        let extBytes = Data(data[(offset + 8)..<(offset + 11)])
        let attr = data[offset + 11]
        let cluster = try Endian.readUInt16LE(data, at: offset + 26)
        let fileSize = try Endian.readUInt32LE(data, at: offset + 28)

        let stemRaw = stripPad(nameBytes)
        let extRaw = stripPad(extBytes)
        // First byte 0x05 means 0xE5 in Japanese short names (rare); treat as data.
        var stemData = stemRaw
        if !deleted, first == 0x05 {
            var d = stemRaw
            if !d.isEmpty { d[0] = 0xE5 }
            stemData = d
        }
        let stem = stemData.isEmpty ? "" : EncodingCP932.decodeLossy(stemData)
        let ext = extRaw.isEmpty ? "" : EncodingCP932.decodeLossy(extRaw)

        return DirEntry(
            name: HumanFileName(stem: stem.trimmingCharacters(in: .whitespaces), ext: ext.trimmingCharacters(in: .whitespaces)),
            attributes: attr,
            firstCluster: cluster,
            size: fileSize,
            isDeleted: deleted,
            isEnd: false
        )
    }

    private static func stripPad(_ data: Data) -> Data {
        var end = data.count
        while end > 0, data[end - 1] == 0x20 { end -= 1 }
        return Data(data.prefix(end))
    }

    private static func require(_ data: Data, offset: Int, count: Int) throws {
        guard offset >= 0, offset + count <= data.count else {
            throw X68Error.outOfBounds(offset: offset, size: count, available: data.count)
        }
    }
}
