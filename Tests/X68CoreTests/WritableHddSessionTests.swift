import XCTest
@testable import X68Core

final class WritableHddSessionTests: XCTestCase {
    /// Stage D core: create → write → read → delete via session; fsck clean.
    func testCreateWriteDeleteRoundTrip() throws {
        let base = try SyntheticHDS.makeMinimal()
        let session = try WritableHddSession(imageData: base)

        try session.createFile(path: HumanPath(display: "HELLO.TXT"))
        let payload = Data("stage-d-fuse-write".utf8)
        try session.writeFile(path: HumanPath(display: "HELLO.TXT"), contents: payload)

        let list = try session.listEntries()
        XCTAssertTrue(list.contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }))
        XCTAssertEqual(try session.readFile(path: HumanPath(display: "HELLO.TXT")), payload)
        XCTAssertTrue(try session.fsck().isClean)

        try session.deleteFile(path: HumanPath(display: "HELLO.TXT"))
        let after = try session.listEntries()
        XCTAssertFalse(after.contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }))
        XCTAssertTrue(try session.fsck().isClean)
    }

    func testMkdirThenInject() throws {
        let base = try SyntheticHDS.makeMinimal()
        let session = try WritableHddSession(imageData: base)

        try session.mkdir(path: HumanPath(display: "GAME"))
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        try session.writeFile(path: HumanPath(display: "GAME/ROM.BIN"), contents: payload)

        let sub = try session.listEntries(path: HumanPath(display: "GAME"))
        XCTAssertTrue(sub.contains(where: { $0.name.display.uppercased() == "ROM.BIN" }))
        XCTAssertEqual(try session.readFile(path: HumanPath(display: "GAME/ROM.BIN")), payload)
        XCTAssertTrue(try session.fsck().isClean)
    }

    func testTruncateShrinkAndGrow() throws {
        let base = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "DATA", ext: "BIN"),
            contents: Data(repeating: 0xAB, count: 40)
        )
        let session = try WritableHddSession(imageData: base)

        try session.truncate(path: HumanPath(display: "DATA.BIN"), size: 10)
        XCTAssertEqual(try session.readFile(path: HumanPath(display: "DATA.BIN")).count, 10)

        try session.truncate(path: HumanPath(display: "DATA.BIN"), size: 25)
        let grown = try session.readFile(path: HumanPath(display: "DATA.BIN"))
        XCTAssertEqual(grown.count, 25)
        XCTAssertEqual(grown.prefix(10), Data(repeating: 0xAB, count: 10))
        XCTAssertEqual(Data(grown.suffix(15)), Data(repeating: 0, count: 15))
        XCTAssertTrue(try session.fsck().isClean)
    }

    func testPersistToURLCreatesBackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68drv-wsession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("test.hds")
        try SyntheticHDS.makeMinimal().write(to: imageURL)

        let session = try WritableHddSession.open(
            url: imageURL,
            requireCleanFsck: true,
            createBackup: true,
            lockImage: true
        )
        try session.writeFile(
            path: HumanPath(display: "NEW.TXT"),
            contents: Data("persisted".utf8)
        )

        let bak = URL(fileURLWithPath: imageURL.path + ".x68drv-bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))

        let reopened = try DiskImage.open(url: imageURL)
        let vol = try reopened.openVolume(partitionIndex: 0)
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "NEW.TXT")), Data("persisted".utf8))
        XCTAssertTrue(try vol.fsck().isClean)
    }

    func testRejectsFloppy() throws {
        let xdf = try SyntheticXDF.makeEmpty2HD()
        XCTAssertThrowsError(try WritableHddSession(imageData: xdf))
    }

    /// Finder copy-in needs non-zero free space via FAT free-cluster count.
    func testSpaceInfoReportsFreeClusters() throws {
        let base = try SyntheticHDS.makeMinimal()
        let session = try WritableHddSession(imageData: base)
        let space = try session.spaceInfo()
        XCTAssertGreaterThan(space.blockSize, 0)
        XCTAssertGreaterThan(space.totalBlocks, 0)
        XCTAssertGreaterThan(space.freeBlocks, 0)
        XCTAssertGreaterThan(space.freeBytes, 0)

        // Use some space; free should drop (or stay if empty file).
        let payload = Data(repeating: 0x55, count: Int(space.blockSize) * 2)
        try session.writeFile(path: HumanPath(display: "BIG.BIN"), contents: payload)
        let after = try session.spaceInfo()
        XCTAssertLessThan(after.freeBlocks, space.freeBlocks)
    }
}
