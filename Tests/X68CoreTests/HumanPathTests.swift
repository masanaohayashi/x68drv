import XCTest
@testable import X68Core

final class HumanPathTests: XCTestCase {
    /// U1.path
    func testDisplayPathParse() {
        let path = HumanPath(display: "FOO/BAR.TXT")
        XCTAssertEqual(path.components.count, 2)
        XCTAssertEqual(path.components[0].display, "FOO")
        XCTAssertEqual(path.components[1].display, "BAR.TXT")
        XCTAssertEqual(path.display, "FOO/BAR.TXT")
    }

    func testPackUnpack18_3() throws {
        let name = HumanFileName(stem: "HELLO", ext: "TXT")
        let (s, e) = try name.packDiskFields()
        XCTAssertEqual(s.count, 18)
        XCTAssertEqual(e.count, 3)
        let back = try HumanFileName.unpack(stem18: s, ext3: e)
        XCTAssertEqual(back.display, "HELLO.TXT")
    }

    func testJapaneseFileNamePack() throws {
        let name = HumanFileName(display: "テスト.DAT")
        let (s, e) = try name.packDiskFields()
        let back = try HumanFileName.unpack(stem18: s, ext3: e)
        XCTAssertEqual(back.display, "テスト.DAT")
    }

    func testJapaneseStemFieldsRecombine() throws {
        let stem = "あいうえお"
        let bytes = try EncodingCP932.encode(stem)
        let (dos8, rest) = try HumanNamePacking.packStem(stem)
        XCTAssertEqual(dos8.count, 8)
        XCTAssertEqual(dos8 + rest, bytes)
        XCTAssertEqual(try EncodingCP932.decode(dos8 + rest), stem)
    }

    func testSplitPreservesCharacterAcrossFields() throws {
        let bytes = try EncodingCP932.encode("AAAAAAAあBBBBBBBBB")
        XCTAssertEqual(bytes.count, 18)
        let (dos8, rest) = try HumanNamePacking.splitStemSJIS(bytes)
        XCTAssertEqual(dos8.count, 8)
        XCTAssertEqual(rest.count, 10)
        XCTAssertEqual(dos8 + rest, bytes)
    }
}
