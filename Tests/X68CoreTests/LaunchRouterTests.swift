import XCTest
@testable import X68Core

final class LaunchRouterTests: XCTestCase {
    /// U5.launch_mode
    func testInteractiveWhenNothingSpecial() {
        let mode = LaunchRouter.mode(launchedAsLoginItem: false, documentURLs: [])
        XCTAssertEqual(mode, .interactive)
    }

    func testSilentLoginWinsOverDocuments() {
        let urls = [URL(fileURLWithPath: "/tmp/a.xdf")]
        let mode = LaunchRouter.mode(launchedAsLoginItem: true, documentURLs: urls)
        XCTAssertEqual(mode, .silent)
    }

    func testDocumentWhenFilesOpened() {
        let urls = [URL(fileURLWithPath: "/tmp/a.xdf")]
        let mode = LaunchRouter.mode(launchedAsLoginItem: false, documentURLs: urls)
        XCTAssertEqual(mode, .document)
    }

    func testExplicitLoginFlags() {
        XCTAssertTrue(LaunchRouter.isExplicitLoginLaunch(
            arguments: ["/app", "--launched-at-login"],
            environment: [:]
        ))
        XCTAssertTrue(LaunchRouter.isExplicitLoginLaunch(
            arguments: ["/app"],
            environment: ["X68DRV_LAUNCHED_AT_LOGIN": "1"]
        ))
        XCTAssertFalse(LaunchRouter.isExplicitLoginLaunch(
            arguments: ["/app"],
            environment: [:]
        ))
    }
}
