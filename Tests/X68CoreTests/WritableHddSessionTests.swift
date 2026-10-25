import XCTest
@testable import X68Core

final class WritableHddSessionTests: XCTestCase {
    func testLongNamesAndDirectoryRemovalPersist() throws {
        let session = try WritableHddSession(imageData: SyntheticHDS.makeMinimal())
        let directory = HumanPath(display: "ABCDEFGHIJKLMNOPQR")
        let file = HumanPath(display: "ABCDEFGHIJKLMNOPQR/AAAAAAAあBBBBBBBBB.XYZ")
        try session.mkdir(path: directory)
        let payload = Data(repeating: 0x6A, count: 5000)
        try session.writeFile(path: file, contents: payload)
        XCTAssertEqual(try session.readFile(path: file), payload)
        let before = session.imageData
        XCTAssertThrowsError(try session.removeDirectory(path: directory))
        XCTAssertEqual(session.imageData, before)
        let reopened = try WritableHddSession(imageData: session.imageData)
        XCTAssertEqual(try reopened.readFile(path: file), payload)
        try reopened.writeFile(path: file, contents: Data([1, 2]))
        XCTAssertEqual(try reopened.readFile(path: file), Data([1, 2]))
        try reopened.deleteFile(path: file)
        try reopened.removeDirectory(path: directory)
        XCTAssertFalse(try reopened.listEntries().contains { $0.name.display == directory.display })
        XCTAssertThrowsError(try reopened.removeDirectory(path: HumanPath()))
        XCTAssertThrowsError(try reopened.removeDirectory(path: HumanPath(display: "..")))
        XCTAssertTrue(try reopened.fsck().isClean)
    }

    func testLongNamesWithSamePrefixRemainDistinct() throws {
        let session = try WritableHddSession(imageData: SyntheticHDS.makeMinimal())
        let first = HumanPath(display: "ABCDEFGH1234567890.TXT")
        let second = HumanPath(display: "ABCDEFGH0987654321.TXT")
        try session.writeFile(path: first, contents: Data([1]))
        try session.writeFile(path: second, contents: Data([2]))
        XCTAssertEqual(try session.readFile(path: first), Data([1]))
        XCTAssertEqual(try session.readFile(path: second), Data([2]))
        try session.deleteFile(path: first)
        XCTAssertEqual(try session.readFile(path: second), Data([2]))
        let renamed = HumanPath(display: "LONGRENAMED1234567.TXT")
        try session.rename(from: second, to: renamed)
        let reopened = try WritableHddSession(imageData: session.imageData)
        XCTAssertEqual(try reopened.readFile(path: renamed), Data([2]))
        XCTAssertTrue(try reopened.fsck().isClean)
    }

    func testDirectoryRemovalFreesClustersAndPreservesOtherPartition() throws {
        let original = try SyntheticHDS.makeDualPartition(
            fileName: HumanFileName(display: "KEEP.TXT"), contents: Data([7])
        )
        let session = try WritableHddSession(imageData: original, partitionIndex: 1)
        let free = try session.spaceInfo().freeBlocks
        let parent = HumanPath(display: "PARENT123456789012")
        let child = HumanPath(display: "PARENT123456789012/CHILD")
        try session.mkdir(path: parent)
        try session.mkdir(path: child)
        XCTAssertThrowsError(try session.removeDirectory(path: parent))
        try session.removeDirectory(path: child)
        try session.removeDirectory(path: parent)
        XCTAssertEqual(try session.spaceInfo().freeBlocks, free)
        let parts = try HdsImage(data: original).partitions
        let p0 = parts[0]
        XCTAssertEqual(session.imageData.subdata(in: p0.bootOffset..<(p0.bootOffset + p0.byteLength)),
                       original.subdata(in: p0.bootOffset..<(p0.bootOffset + p0.byteLength)))
        XCTAssertTrue(try session.fsck().isClean)
    }

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

    func testRenameSameDirectory() throws {
        let base = try SyntheticHDS.makeMinimal()
        let session = try WritableHddSession(imageData: base)
        try session.writeFile(path: HumanPath(display: "TEMP.BIN"), contents: Data("x".utf8))
        try session.rename(
            from: HumanPath(display: "TEMP.BIN"),
            to: HumanPath(display: "FINAL.BIN")
        )
        let list = try session.listEntries()
        XCTAssertFalse(list.contains(where: { $0.name.display.uppercased() == "TEMP.BIN" }))
        XCTAssertTrue(list.contains(where: { $0.name.display.uppercased() == "FINAL.BIN" }))
        XCTAssertEqual(try session.readFile(path: HumanPath(display: "FINAL.BIN")), Data("x".utf8))
        XCTAssertTrue(try session.fsck().isClean)
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
