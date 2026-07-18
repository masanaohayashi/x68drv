import XCTest
@testable import X68Core

final class FloppyInjectTests: XCTestCase {
    func testInjectDeleteRoundTripXDF() throws {
        let base = try SyntheticXDF.makeEmpty2HD()
        let payload = Data("xdf-write-stage".utf8)
        let (mutated, result) = try FloppyInject.injectFile(
            imageData: base,
            path: HumanPath(display: "HELLO.TXT"),
            contents: payload
        )
        XCTAssertEqual(result.bytesWritten, payload.count)
        XCTAssertFalse(result.overwritten)

        let vol = try FloppyVolume(imageData: mutated)
        XCTAssertTrue(try vol.list().contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }))
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "HELLO.TXT")), payload)
        XCTAssertTrue(try vol.fsck().isClean)

        let (afterDel, del) = try FloppyInject.deleteFile(
            imageData: mutated,
            path: HumanPath(display: "HELLO.TXT")
        )
        XCTAssertEqual(del.freedClusters, result.clusterCount)
        let vol2 = try FloppyVolume(imageData: afterDel)
        XCTAssertFalse(try vol2.list().contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }))
        XCTAssertTrue(try vol2.fsck().isClean)
    }

    func testMkdirAndInjectSubdir() throws {
        let base = try SyntheticXDF.makeEmpty2HD()
        let (withDir, _) = try FloppyInject.mkdir(
            imageData: base,
            name: HumanFileName(stem: "GAME", ext: "")
        )
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let (mutated, _) = try FloppyInject.injectFile(
            imageData: withDir,
            path: HumanPath(display: "GAME/ROM.BIN"),
            contents: payload
        )
        let vol = try FloppyVolume(imageData: mutated)
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "GAME/ROM.BIN")), payload)
        XCTAssertTrue(try vol.fsck().isClean)
    }

    func testWritableSessionXDF() throws {
        let session = try WritableFloppySession(imageData: try SyntheticXDF.makeEmpty2HD())
        try session.writeFile(path: HumanPath(display: "A.TXT"), contents: Data("ok".utf8))
        XCTAssertEqual(try session.readFile(path: HumanPath(display: "A.TXT")), Data("ok".utf8))
        let space = try session.spaceInfo()
        XCTAssertGreaterThan(space.freeBlocks, 0)
        XCTAssertTrue(try session.fsck().isClean)
    }

    func testRenameXDF() throws {
        let session = try WritableFloppySession(imageData: try SyntheticXDF.makeEmpty2HD())
        try session.writeFile(path: HumanPath(display: "TEMP.BIN"), contents: Data("z".utf8))
        try session.rename(
            from: HumanPath(display: "TEMP.BIN"),
            to: HumanPath(display: "DONE.BIN")
        )
        XCTAssertEqual(try session.readFile(path: HumanPath(display: "DONE.BIN")), Data("z".utf8))
    }

    func testFactoryOpensXDF() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68-xdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.xdf")
        try SyntheticXDF.makeEmpty2HD().write(to: url)
        let session = try WritableSession.open(url: url, createBackup: true, lockImage: true)
        try session.writeFile(path: HumanPath(display: "N.TXT"), contents: Data("1".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".x68drv-bak"))
    }
}
