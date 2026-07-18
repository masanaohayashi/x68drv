import XCTest
@testable import X68Core

final class X68CoreTests: XCTestCase {
    func testLibraryVersionIsSemver() {
        let parts = X68Core.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(X68Core.version.isEmpty)
    }

    func testErrorMessages() {
        let err = X68Error.format("bad magic")
        XCTAssertEqual(err.localizedDescription, "bad magic")
    }
}
