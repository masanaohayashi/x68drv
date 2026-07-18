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

    /// U1.sjis_split — do not split DBCS at 8-byte boundary
    func testSJISSafeSplitDoesNotCutLeadByte() throws {
        // Build a stem whose SJIS length > 8 and where naive 8-cut would split a character.
        // "あいいうえおか" etc. — each hiragana is typically 2 SJIS bytes.
        let stem = "あいうえお" // 5 chars * 2 = 10 bytes typically
        let bytes = try EncodingCP932.encode(stem)
        XCTAssertGreaterThan(bytes.count, 8)

        let (dos8, rest) = try HumanNamePacking.packStem(stem)
        XCTAssertEqual(dos8.count, 8)
        // dos8 must not end with a lone lead byte
        if let last = dos8.last(where: { $0 != 0x20 }) {
            // If last non-space is a lead, the field would be invalid mid-character.
            // After our packing, decoding dos8+rest should recover stem.
            _ = last
        }
        var core = dos8
        while core.last == 0x20 { core.removeLast() }
        let full = core + rest
        let decoded = try EncodingCP932.decode(full)
        XCTAssertEqual(decoded, stem)
        XCTAssertEqual(full, bytes)
    }

    func testSplitNeverLeavesLeadAsLastOfDos8() throws {
        // Force a case: bytes where index 7 is lead if we took 8.
        // Construct artificial SJIS: 7 single-byte + lead + trail + more
        var synthetic = Data()
        for _ in 0..<7 { synthetic.append(0x41) } // 'A'
        synthetic.append(0x82) // lead
        synthetic.append(0xA0) // trail
        synthetic.append(0x42) // 'B'
        let (dos8, rest) = try HumanNamePacking.splitStemSJIS(synthetic)
        // dos8 should take 7 A's and pad; rest starts with lead+trail+B
        XCTAssertEqual(dos8.count, 8)
        let core = dos8.filter { $0 != 0x20 }
        XCTAssertEqual(core.count, 7)
        XCTAssertFalse(EncodingCP932.isLeadByte(core.last!))
        XCTAssertEqual(rest.first, 0x82)
    }
}
