import Foundation

/// 32-byte directory entry (DOS layout; Human68k floppies use LE fields).
///
/// On Human68k HDD (BE FAT) the FAT table is big-endian, but directory
/// `wtime`/`wdate`/`cluster`/`size` remain little-endian DOS fields.
public struct DirEntry: Equatable, Sendable {
    public var name: HumanFileName
    public var attributes: UInt8
    public var firstCluster: UInt16
    public var size: UInt32
    /// MS-DOS write time (LE on disk): hour<<11 | min<<5 | sec/2
    public var wtime: UInt16
    /// MS-DOS write date (LE on disk): (year-1980)<<9 | month<<5 | day
    public var wdate: UInt16
    public var isDeleted: Bool
    public var isEnd: Bool

    public var isDirectory: Bool { attributes & 0x10 != 0 }
    public var isVolumeLabel: Bool { attributes & 0x08 != 0 }
    public var isFile: Bool { !isDirectory && !isVolumeLabel && !isDeleted && !isEnd }

    /// Host `Date` from DOS `wtime`/`wdate`, or `nil` if unset/invalid.
    public var modificationDate: Date? {
        DosDateTime.date(wtime: wtime, wdate: wdate)
    }

    /// Unix epoch seconds for FUSE `stat`, or `nil` if unset/invalid.
    public var modificationUnixSeconds: Int64? {
        DosDateTime.unixSeconds(wtime: wtime, wdate: wdate)
    }

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
                wtime: 0,
                wdate: 0,
                isDeleted: false,
                isEnd: true
            )
        }
        let deleted = first == 0xE5
        let nameBytes = Data(data[(offset)..<(offset + 8)])
        let extBytes = Data(data[(offset + 8)..<(offset + 11)])
        let attr = data[offset + 11]
        let wtime = try Endian.readUInt16LE(data, at: offset + 22)
        let wdate = try Endian.readUInt16LE(data, at: offset + 24)
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
            wtime: wtime,
            wdate: wdate,
            isDeleted: deleted,
            isEnd: false
        )
    }

    /// Pack a 32-byte Human68k/MS-DOS-compatible directory entry.
    ///
    /// Layout (Human68k 32-byte dir / synthetic HDS):
    /// name[8] + ext[3] + attr + name2[10] + wtime(LE) + wdate(LE) + cluster(LE) + size(LE).
    public static func pack(
        name: HumanFileName,
        attributes: UInt8 = 0x20,
        firstCluster: UInt16,
        size: UInt32,
        wtime: UInt16? = nil,
        wdate: UInt16? = nil
    ) throws -> Data {
        let now = DosDateTime.pack(date: Date())
        let time = wtime ?? now.wtime
        let date = wdate ?? now.wdate

        let stemSJIS = try EncodingCP932.encode(name.stem)
        let (dos8, rest) = try HumanNamePacking.splitStemSJIS(stemSJIS)
        let (_, ext3) = try name.packDiskFields()
        var name2 = rest
        while name2.count < 10 { name2.append(0x20) }
        if name2.count > 10 { name2 = name2.prefix(10) }

        var out = Data(count: Self.size)
        for i in 0..<8 { out[i] = dos8[i] }
        for i in 0..<3 { out[8 + i] = ext3[i] }
        out[11] = attributes
        for i in 0..<10 { out[12 + i] = name2[i] }
        try Endian.writeUInt16LE(time, to: &out, at: 22)
        try Endian.writeUInt16LE(date, to: &out, at: 24)
        try Endian.writeUInt16LE(firstCluster, to: &out, at: 26)
        try Endian.writeUInt32LE(size, to: &out, at: 28)
        return out
    }

    /// Mark slot deleted (first byte 0xE5); preserves rest of the 32 bytes.
    public static func markDeleted(_ entry: Data) -> Data {
        var d = entry
        if d.count >= 1 { d[0] = 0xE5 }
        return d
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

/// MS-DOS directory date/time packing used by Human68k and FAT.
public enum DosDateTime: Sendable {
    /// Encode a host date into DOS `wtime`/`wdate` (local calendar components).
    public static func pack(date: Date, timeZone: TimeZone = .current) -> (wtime: UInt16, wdate: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let month = max(1, min(12, c.month ?? 1))
        let day = max(1, min(31, c.day ?? 1))
        let hour = max(0, min(23, c.hour ?? 0))
        let minute = max(0, min(59, c.minute ?? 0))
        let second = max(0, min(59, c.second ?? 0))
        let wdate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let wtime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (wtime, wdate)
    }

    /// Decode DOS fields to a host `Date` in the given time zone, or `nil` if unset/invalid.
    public static func date(wtime: UInt16, wdate: UInt16, timeZone: TimeZone = .current) -> Date? {
        guard let secs = unixSeconds(wtime: wtime, wdate: wdate, timeZone: timeZone) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    /// Decode to Unix epoch seconds, or `nil` if unset/invalid.
    public static func unixSeconds(wtime: UInt16, wdate: UInt16, timeZone: TimeZone = .current) -> Int64? {
        if wtime == 0, wdate == 0 { return nil }
        let year = 1980 + Int((wdate >> 9) & 0x7F)
        let month = Int((wdate >> 5) & 0x0F)
        let day = Int(wdate & 0x1F)
        let hour = Int((wtime >> 11) & 0x1F)
        let minute = Int((wtime >> 5) & 0x3F)
        let second = Int(wtime & 0x1F) * 2
        guard month >= 1, month <= 12, day >= 1, day <= 31,
              hour <= 23, minute <= 59, second <= 58 else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard let date = cal.date(from: comps) else { return nil }
        return Int64(date.timeIntervalSince1970.rounded())
    }
}
