import Foundation

/// Big/little-endian integer helpers for binary formats (Human68k / SxSI).
public enum Endian {
    public static func readUInt16LE(_ data: Data, at offset: Int) throws -> UInt16 {
        try require(data, offset: offset, count: 2)
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    public static func readUInt16BE(_ data: Data, at offset: Int) throws -> UInt16 {
        try require(data, offset: offset, count: 2)
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    public static func readUInt32LE(_ data: Data, at offset: Int) throws -> UInt32 {
        try require(data, offset: offset, count: 4)
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    public static func readUInt32BE(_ data: Data, at offset: Int) throws -> UInt32 {
        try require(data, offset: offset, count: 4)
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    public static func writeUInt16LE(_ value: UInt16, to data: inout Data, at offset: Int) throws {
        try require(data, offset: offset, count: 2)
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    public static func writeUInt16BE(_ value: UInt16, to data: inout Data, at offset: Int) throws {
        try require(data, offset: offset, count: 2)
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    public static func writeUInt32LE(_ value: UInt32, to data: inout Data, at offset: Int) throws {
        try require(data, offset: offset, count: 4)
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    public static func writeUInt32BE(_ value: UInt32, to data: inout Data, at offset: Int) throws {
        try require(data, offset: offset, count: 4)
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    /// Append LE/BE values when building synthetic images.
    public static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    public static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    public static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    public static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func require(_ data: Data, offset: Int, count: Int) throws {
        guard offset >= 0, offset + count <= data.count else {
            throw X68Error.outOfBounds(offset: offset, size: count, available: data.count)
        }
    }
}
