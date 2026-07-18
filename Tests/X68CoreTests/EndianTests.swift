import XCTest
@testable import X68Core

final class EndianTests: XCTestCase {
    /// U1.endian
    func testReadWriteLE_BE() throws {
        var data = Data(repeating: 0, count: 16)
        try Endian.writeUInt16LE(0x1234, to: &data, at: 0)
        try Endian.writeUInt16BE(0x1234, to: &data, at: 2)
        try Endian.writeUInt32LE(0x89ABCDEF, to: &data, at: 4)
        try Endian.writeUInt32BE(0x89ABCDEF, to: &data, at: 8)

        XCTAssertEqual(try Endian.readUInt16LE(data, at: 0), 0x1234)
        XCTAssertEqual(try Endian.readUInt16BE(data, at: 2), 0x1234)
        XCTAssertEqual(try Endian.readUInt32LE(data, at: 4), 0x89ABCDEF)
        XCTAssertEqual(try Endian.readUInt32BE(data, at: 8), 0x89ABCDEF)

        XCTAssertEqual(data[0], 0x34)
        XCTAssertEqual(data[1], 0x12)
        XCTAssertEqual(data[2], 0x12)
        XCTAssertEqual(data[3], 0x34)
    }

    func testOutOfBounds() {
        let data = Data([0, 1])
        XCTAssertThrowsError(try Endian.readUInt32LE(data, at: 0))
    }
}
