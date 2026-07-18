import XCTest
@testable import X68Core

final class SyntheticImageTests: XCTestCase {
    /// U1.synth_xdf_size
    func testXDFFullSizeAndBPB() throws {
        let image = try SyntheticXDF.makeEmpty2HD()
        XCTAssertEqual(image.count, SyntheticXDF.byteSize)
        XCTAssertEqual(image.count, 1_261_568)

        XCTAssertEqual(try Endian.readUInt16LE(image, at: 0x0B), 1024)
        XCTAssertEqual(image[0x0D], 1)
        XCTAssertEqual(try Endian.readUInt16LE(image, at: 0x0E), 1)
        XCTAssertEqual(image[0x10], 2)
        XCTAssertEqual(try Endian.readUInt16LE(image, at: 0x11), 192)
        XCTAssertEqual(try Endian.readUInt16LE(image, at: 0x13), 1232)
        XCTAssertEqual(image[0x15], 0xFE)
        XCTAssertEqual(try Endian.readUInt16LE(image, at: 0x16), 2)

        // Root directory region offset for 2HD defaults
        XCTAssertEqual(0x1400, 5 * 1024)
    }

    func testXDFWithFileRootEntry() throws {
        let payload = Data("hello-x68".utf8)
        let image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "HELLO", ext: "TXT"),
            contents: payload
        )
        XCTAssertEqual(image.count, SyntheticXDF.byteSize)
        // Root entry name
        let name = String(bytes: image[0x1400..<0x1400 + 8], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(name, "HELLO")
        let size = try Endian.readUInt32LE(image, at: 0x1400 + 28)
        XCTAssertEqual(size, UInt32(payload.count))
        let cluster = try Endian.readUInt16LE(image, at: 0x1400 + 26)
        XCTAssertEqual(cluster, 2)
        let dataStart = 11 * 1024
        XCTAssertEqual(image[dataStart..<(dataStart + payload.count)], payload)
    }

    /// U1.synth_hds_magic
    func testHDSMagicAndPartitionTable() throws {
        let image = try SyntheticHDS.makeMinimal()
        XCTAssertEqual(String(bytes: image[0..<8], encoding: .ascii), "X68SCSI1")
        XCTAssertEqual(try Endian.readUInt16BE(image, at: 0x08), 0x0200)
        XCTAssertEqual(String(bytes: image[0x800..<0x804], encoding: .ascii), "X68K")
        let ent = 0x800 + 0x10
        XCTAssertEqual(String(bytes: image[ent..<(ent + 8)], encoding: .ascii), "Human68k")
        let start = try Endian.readUInt32BE(image, at: ent + 8)
        XCTAssertEqual(start, 32)
        let boot = Int(start) * 1024
        XCTAssertEqual(boot, 0x8000)
        XCTAssertEqual(try Endian.readUInt16BE(image, at: boot + 0x12), 1024)
        XCTAssertEqual(image[boot + 0x1C], 0xF7)
    }
}
