import Foundation

/// One Human68k 18.3-style filename component (on-disk SJIS, host-facing Unicode).
public struct HumanFileName: Equatable, Sendable {
    /// Stem, up to 18 SJIS bytes (space-padded on disk).
    public var stem: String
    /// Extension without dot, up to 3 SJIS bytes.
    public var ext: String

    public init(stem: String, ext: String = "") {
        self.stem = stem
        self.ext = ext
    }

    /// Parse `"NAME.EXT"` or `"NAME"` (host Unicode).
    public init(display: String) {
        if let dot = display.lastIndex(of: ".") {
            let s = String(display[..<dot])
            let e = String(display[display.index(after: dot)...])
            self.stem = s
            self.ext = e
        } else {
            self.stem = display
            self.ext = ""
        }
    }

    public var display: String {
        if ext.isEmpty { return stem }
        return "\(stem).\(ext)"
    }

    /// Pack into on-disk fields: 18-byte stem + 3-byte extension (space-padded, CP932).
    public func packDiskFields() throws -> (stem18: Data, ext3: Data) {
        let stemBytes = try EncodingCP932.encode(stem)
        let extBytes = try EncodingCP932.encode(ext)
        guard stemBytes.count <= 18 else {
            throw X68Error.filesystem("Stem too long for 18-byte field: \(stem)")
        }
        guard extBytes.count <= 3 else {
            throw X68Error.filesystem("Extension too long for 3-byte field: \(ext)")
        }
        var s = stemBytes
        while s.count < 18 { s.append(0x20) }
        var e = extBytes
        while e.count < 3 { e.append(0x20) }
        return (s, e)
    }

    /// Unpack space-padded CP932 fields.
    public static func unpack(stem18: Data, ext3: Data) throws -> HumanFileName {
        let s = try EncodingCP932.decode(stripTrailingSpaces(stem18))
        let e = try EncodingCP932.decode(stripTrailingSpaces(ext3))
        return HumanFileName(stem: s, ext: e)
    }

    private static func stripTrailingSpaces(_ data: Data) -> Data {
        var end = data.count
        while end > 0, data[end - 1] == 0x20 { end -= 1 }
        return data.prefix(end)
    }
}

/// Human68k path as a sequence of filename components (not a host `Path`).
public struct HumanPath: Equatable, Sendable {
    public var components: [HumanFileName]

    public init(components: [HumanFileName] = []) {
        self.components = components
    }

    /// Parse a host display path with `/` or `\` separators.
    public init(display: String) {
        let normalized = display
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.isEmpty {
            self.components = []
            return
        }
        self.components = normalized.split(separator: "/").map { HumanFileName(display: String($0)) }
    }

    public var display: String {
        components.map(\.display).joined(separator: "/")
    }
}

/// SJIS-safe packing into classic 8.3 base field + remainder (Human68k style).
///
/// The 8-byte DOS name field must not end on a Shift_JIS lead byte alone.
public enum HumanNamePacking {
    /// Maximum SJIS bytes for the primary name (before extension), Human68k 18.3.
    public static let maxStemBytes = 18
    public static let maxExtBytes = 3
    public static let dosNameBytes = 8

    /// Split stem SJIS bytes into an 8-byte DOS field (space-padded) and optional remainder,
    /// without splitting a double-byte character at the 8-byte boundary.
    public static func splitStemSJIS(_ stemSJIS: Data) throws -> (dos8: Data, rest: Data) {
        guard stemSJIS.count <= maxStemBytes else {
            throw X68Error.filesystem("Stem exceeds \(maxStemBytes) SJIS bytes")
        }
        if stemSJIS.count <= dosNameBytes {
            var dos = stemSJIS
            while dos.count < dosNameBytes { dos.append(0x20) }
            return (dos, Data())
        }

        // Prefer taking 8 bytes; if byte 7 is a lead, take only 7 and pad.
        var take = dosNameBytes
        if take > 0, EncodingCP932.isLeadByte(stemSJIS[take - 1]) {
            // Would leave a lone lead in the 8-byte field — shorten.
            take -= 1
        }
        // Also ensure we don't start the remainder mid-character (if take is lead of pair that continues).
        // If take points into the middle of a DBCS, walk back.
        var i = 0
        while i < take {
            if EncodingCP932.isLeadByte(stemSJIS[i]) {
                if i + 1 >= take {
                    take = i
                    break
                }
                i += 2
            } else {
                i += 1
            }
        }

        var dos = stemSJIS.prefix(take)
        while dos.count < dosNameBytes { dos.append(0x20) }
        let rest = stemSJIS.dropFirst(take)
        return (Data(dos), Data(rest))
    }

    /// Pack a Unicode stem into 8.3-compatible dos8 + rest fields (CP932).
    public static func packStem(_ stem: String) throws -> (dos8: Data, rest: Data) {
        let bytes = try EncodingCP932.encode(stem)
        return try splitStemSJIS(bytes)
    }
}
