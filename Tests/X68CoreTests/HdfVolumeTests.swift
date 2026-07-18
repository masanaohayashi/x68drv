import XCTest
@testable import X68Core

final class HdfVolumeTests: XCTestCase {
    func testClassifyAndOpenSynthetic() throws {
        let payload = Data("hdf-sasi".utf8)
        let image = try SyntheticHDF.makeWithFile(
            fileName: HumanFileName(stem: "HELLO", ext: "TXT"),
            contents: payload
        )
        XCTAssertEqual(HdfImage.classify(data: image), .sasiX68k256)
        let det = ImageDetector.detect(data: image)
        XCTAssertEqual(det.kind, .hdf)

        let hdf = try HdfImage(data: image)
        XCTAssertEqual(hdf.layoutClass, .sasiX68k256)
        XCTAssertEqual(hdf.partitions[0].startRecord, 33)
        XCTAssertEqual(hdf.partitions[0].unitBytes, 256)
        XCTAssertEqual(hdf.partitions[0].bootOffset, 0x2100)

        let vol = try hdf.openVolume()
        XCTAssertEqual(vol.bpb.bytesPerSector, 1024)
        let list = try vol.list()
        XCTAssertTrue(list.contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }))
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "HELLO.TXT")), payload)
    }

    func testDiskImageOpenHDF() throws {
        let image = try SyntheticHDF.makeWithFile(
            fileName: HumanFileName(stem: "Z", ext: "BIN"),
            contents: Data([0x7F])
        )
        let disk = DiskImage.open(data: image)
        XCTAssertEqual(disk.hdfLayoutClass(), .sasiX68k256)
        let vol = try disk.openDefaultVolume()
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "Z.BIN")), Data([0x7F]))
        XCTAssertTrue(try vol.fsck().isClean)
    }

    func testMountServiceHDF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("x68-hdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let image = try SyntheticHDF.makeWithFile(
            fileName: HumanFileName(stem: "M", ext: "DAT"),
            contents: Data("mount".utf8)
        )
        let url = tmp.appendingPathComponent("t.hdf")
        try image.write(to: url)
        let service = MountService(mountsRoot: tmp.appendingPathComponent("Mounts"))
        let record = try service.mount(url: url, preferFuse: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: record.mountURL.appendingPathComponent("M.DAT").path)
        )
        try service.eject(id: record.id)
    }

    /// Local golden HD.hdf
    func testLocalHDHdfIfPresent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("disk/HD.hdf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("disk/HD.hdf not available")
        }
        let hdf = try HdfImage(url: url)
        XCTAssertEqual(hdf.layoutClass, .sasiX68k256)
        XCTAssertEqual(hdf.partitions[0].bootOffset, 0x2100)
        let vol = try hdf.openVolume()
        XCTAssertEqual(vol.bpb.bytesPerSector, 1024)
        let list = try vol.list()
        XCTAssertFalse(list.isEmpty, "expected files on HD.hdf")
    }

    func testHDSNotClassifiedAsHDF() throws {
        let hds = try SyntheticHDS.makeMinimal()
        XCTAssertEqual(HdfImage.classify(data: hds), .unknown)
        XCTAssertEqual(ImageDetector.detect(data: hds).kind, .hds)
    }
}
