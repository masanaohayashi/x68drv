import XCTest
@testable import X68Core

final class EncodingTests: XCTestCase {
    /// U1.enc
    func testJapaneseRoundTrip() throws {
        let original = "テスト.DAT"
        let bytes = try EncodingCP932.encode(original)
        let decoded = try EncodingCP932.decode(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testASCII() throws {
        let s = "HELLO.TXT"
        XCTAssertEqual(try EncodingCP932.decode(try EncodingCP932.encode(s)), s)
    }

    func testLeadByteDetection() {
        XCTAssertTrue(EncodingCP932.isLeadByte(0x82)) // common SJIS lead
        XCTAssertFalse(EncodingCP932.isLeadByte(0x41)) // 'A'
        XCTAssertFalse(EncodingCP932.isLeadByte(0x20))
    }
}
