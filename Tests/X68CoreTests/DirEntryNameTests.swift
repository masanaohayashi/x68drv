import XCTest
@testable import X68Core

final class DirEntryNameTests: XCTestCase {
    func testReadsIndependent18Plus3Entry() throws {
        var raw = Data(repeating: 0, count: 32)
        raw.replaceSubrange(0..<11, with: Data("ABCDEFGHTXT".utf8))
        raw[11] = 0x20
        raw.replaceSubrange(12..<22, with: Data("IJKLMNOPQR".utf8))
        XCTAssertEqual(try DirEntry.parse(raw, at: 0).name.display, "ABCDEFGHIJKLMNOPQR.TXT")
    }

    func testNameContinuationIsNullPaddedAndAcceptsLegacySpacePadding() throws {
        let name = HumanFileName(display: "ABCDEFGHI.TXT")
        var raw = try DirEntry.pack(name: name, firstCluster: 2, size: 4)
        XCTAssertEqual(raw.subdata(in: 12..<22), Data([0x49] + Array(repeating: 0, count: 9)))
        XCTAssertEqual(try DirEntry.parse(raw, at: 0).name, name)
        raw.replaceSubrange(13..<22, with: Data(repeating: 0x20, count: 9))
        XCTAssertEqual(try DirEntry.parse(raw, at: 0).name, name)
    }

    func testCP932BoundaryAndDeletedMarkerEscape() throws {
        let escapedStem = try EncodingCP932.decode(Data([0xE5, 0x40]))
        for stem in ["AAAAAAAあBBBBBBBBB", "あいうえおかきくけ", escapedStem, "ABCDEFG HI"] {
            let name = HumanFileName(stem: stem, ext: "DAT")
            let raw = try DirEntry.pack(name: name, firstCluster: 2, size: 4)
            XCTAssertEqual(try DirEntry.parse(raw, at: 0).name, name)
            XCTAssertFalse(try DirEntry.parse(raw, at: 0).isDeleted)
            if stem == escapedStem { XCTAssertEqual(raw[0], 0x05) }
        }
    }

    func testOversizedNamesAreRejectedWithoutTruncation() throws {
        for display in ["ABCDEFGHIJKLMNOPQRS.TXT", "OK.ABCD", "あいうえおかきくけこ.TXT"] {
            XCTAssertThrowsError(try DirEntry.pack(name: HumanFileName(display: display), firstCluster: 0, size: 0))
        }
    }
}
