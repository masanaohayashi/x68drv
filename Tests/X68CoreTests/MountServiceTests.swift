import XCTest
@testable import X68Core

final class MountServiceTests: XCTestCase {
    /// U6.mount_point
    func testSanitizeAndAllocate() throws {
        XCTAssertEqual(MountPointNamer.sanitizeBaseName("My Disk!!.xdf"), "My-Disk")
        XCTAssertFalse(MountPointNamer.sanitizeBaseName("...").isEmpty)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68-mount-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let u1 = try MountPointNamer.allocate(
            baseDirectory: tmp,
            imageFileName: "OSR2.xdf",
            partitionIndex: 0,
            existing: []
        )
        XCTAssertEqual(u1.lastPathComponent, "x68drv-OSR2")
        try FileManager.default.createDirectory(at: u1, withIntermediateDirectories: true)

        let u2 = try MountPointNamer.allocate(
            baseDirectory: tmp,
            imageFileName: "OSR2.xdf",
            partitionIndex: 0,
            existing: []
        )
        XCTAssertEqual(u2.lastPathComponent, "x68drv-OSR2-1")

        let u3 = try MountPointNamer.allocate(
            baseDirectory: tmp,
            imageFileName: "game.hds",
            partitionIndex: 2,
            existing: []
        )
        XCTAssertTrue(u3.lastPathComponent.contains("-p2"))
    }

    /// U6.ro_policy (snapshot is a static export; service reuses mount)
    func testMountExportAndReuse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68-msvc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload = Data("mount-me".utf8)
        let image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "HELLO", ext: "TXT"),
            contents: payload
        )
        let imageURL = tmp.appendingPathComponent("t.xdf")
        try image.write(to: imageURL)

        let mountsRoot = tmp.appendingPathComponent("Mounts", isDirectory: true)
        let service = MountService(mountsRoot: mountsRoot)
        let r1 = try service.mount(url: imageURL)
        XCTAssertEqual(r1.backend, .snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r1.mountURL.appendingPathComponent("HELLO.TXT").path))
        let data = try Data(contentsOf: r1.mountURL.appendingPathComponent("HELLO.TXT"))
        XCTAssertEqual(data, payload)

        let r2 = try service.mount(url: imageURL)
        XCTAssertEqual(r1.id, r2.id)

        try service.eject(id: r1.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r1.mountURL.path))
        XCTAssertTrue(service.mounts.isEmpty)
    }

    func testMaxMounts() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68-max-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = MountService(mountsRoot: tmp.appendingPathComponent("M"))
        service.maxMounts = 2
        for i in 0..<2 {
            let image = try SyntheticXDF.make2HD(
                fileName: HumanFileName(stem: "F\(i)", ext: "TXT"),
                contents: Data([UInt8(i)])
            )
            let url = tmp.appendingPathComponent("f\(i).xdf")
            try image.write(to: url)
            _ = try service.mount(url: url)
        }
        let image = try SyntheticXDF.makeEmpty2HD()
        let url = tmp.appendingPathComponent("overflow.xdf")
        try image.write(to: url)
        XCTAssertThrowsError(try service.mount(url: url))
        try service.ejectAll()
    }

    func testSanitizeHostFileName() {
        XCTAssertEqual(SnapshotExporter.sanitizeHostFileName("a/b:c"), "a_b_c")
    }
}
