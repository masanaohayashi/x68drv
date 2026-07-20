import XCTest
@testable import X68Core

final class DirEntryDateTests: XCTestCase {
    /// HUMAN.SYS sample fields from disk/OSR2.xdf and System.HDS: 1993-09-15 12:00:00
    func testDosDateTimeRoundTrip() {
        let tz = TimeZone(secondsFromGMT: 9 * 3600)! // JST — classic X68 samples
        let packed = DosDateTime.pack(
            date: date(y: 1993, m: 9, d: 15, h: 12, mi: 0, s: 0, tz: tz),
            timeZone: tz
        )
        XCTAssertEqual(packed.wtime, 0x6000)
        XCTAssertEqual(packed.wdate, 0x1B2F)

        let decoded = DosDateTime.date(wtime: 0x6000, wdate: 0x1B2F, timeZone: tz)
        XCTAssertNotNil(decoded)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: decoded!)
        XCTAssertEqual(c.year, 1993)
        XCTAssertEqual(c.month, 9)
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 12)
        XCTAssertEqual(c.minute, 0)
        XCTAssertEqual(c.second, 0)
    }

    func testUnsetDosDateIsNil() {
        XCTAssertNil(DosDateTime.date(wtime: 0, wdate: 0))
        XCTAssertNil(DosDateTime.unixSeconds(wtime: 0, wdate: 0))
    }

    func testParseReadsWtimeWdate() throws {
        var slot = Data(repeating: 0x20, count: 32)
        // "HELLO   TXT"
        let name = Array("HELLO   TXT".utf8)
        for i in 0..<11 { slot[i] = name[i] }
        slot[11] = 0x20
        try Endian.writeUInt16LE(0x6000, to: &slot, at: 22)
        try Endian.writeUInt16LE(0x1B2F, to: &slot, at: 24)
        try Endian.writeUInt16LE(2, to: &slot, at: 26)
        try Endian.writeUInt32LE(100, to: &slot, at: 28)

        let entry = try DirEntry.parse(slot, at: 0)
        XCTAssertEqual(entry.wtime, 0x6000)
        XCTAssertEqual(entry.wdate, 0x1B2F)
        XCTAssertEqual(entry.size, 100)
        XCTAssertNotNil(entry.modificationDate)
    }

    func testPackDefaultUsesNonZeroDate() throws {
        let packed = try DirEntry.pack(
            name: HumanFileName(stem: "NEW", ext: "BIN"),
            firstCluster: 2,
            size: 1
        )
        let entry = try DirEntry.parse(packed, at: 0)
        XCTAssertNotEqual(entry.wdate, 0)
        XCTAssertNotNil(entry.modificationDate)
    }

    func testPackPreservesExplicitZero() throws {
        let packed = try DirEntry.pack(
            name: HumanFileName(stem: "OLD", ext: "BIN"),
            firstCluster: 2,
            size: 1,
            wtime: 0,
            wdate: 0
        )
        let entry = try DirEntry.parse(packed, at: 0)
        XCTAssertEqual(entry.wtime, 0)
        XCTAssertEqual(entry.wdate, 0)
        XCTAssertNil(entry.modificationDate)
    }

    func testSyntheticXDFListExposesModificationDate() throws {
        let image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "HELLO", ext: "TXT"),
            contents: Data("hi".utf8)
        )
        let vol = try FloppyVolume(imageData: image)
        let list = try vol.listEntries()
        let hello = try XCTUnwrap(list.first { $0.name.display.uppercased() == "HELLO.TXT" })
        XCTAssertNotNil(hello.modificationDate)
        XCTAssertEqual(hello.modificationUnixSeconds, DosDateTime.unixSeconds(wtime: 0x6000, wdate: 0x1B2F))
    }

    func testExportSetsHostModificationDate() throws {
        let image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "OUT", ext: "BIN"),
            contents: Data("export-me".utf8)
        )
        let vol = try FloppyVolume(imageData: image)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68drv-export-mtime-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try vol.export(path: HumanPath(display: "OUT.BIN"), to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        let expected = try XCTUnwrap(DosDateTime.date(wtime: 0x6000, wdate: 0x1B2F))
        XCTAssertEqual(mtime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    private func date(y: Int, m: Int, d: Int, h: Int, mi: Int, s: Int, tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = h
        c.minute = mi
        c.second = s
        return cal.date(from: c)!
    }
}
