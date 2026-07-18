import XCTest
@testable import X68Core

final class HdsVolumeTests: XCTestCase {
    /// U3.header / U3.part0
    func testHeaderAndPartition0() throws {
        let image = try SyntheticHDS.makeMinimal()
        let hds = try HdsImage(data: image)
        XCTAssertEqual(hds.header.bytesPerRecordField, 0x0200)
        XCTAssertEqual(hds.partitions.count, 1)
        XCTAssertEqual(hds.partitions[0].startRecord, 32)
        XCTAssertEqual(hds.partitions[0].bootOffset, 0x8000)
        XCTAssertTrue(hds.partitions[0].name.hasPrefix("Human68k") || hds.partitions[0].name.contains("Human"))
        let vol = try hds.openVolume(index: 0)
        XCTAssertEqual(vol.bpb.bytesPerSector, 1024)
        XCTAssertEqual(vol.bpb.media, 0xF7)
    }

    /// U3.list_be / U3.read_export
    func testListReadExport() throws {
        let payload = Data("hdd-hello-be".utf8)
        let image = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "HELLO", ext: "TXT"),
            contents: payload
        )
        let hds = try HdsImage(data: image)
        let vol = try hds.openVolume()
        let list = try vol.list()
        XCTAssertTrue(list.contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }), "\(list.map(\.name.display))")
        let data = try vol.readFile(path: HumanPath(display: "HELLO.TXT"))
        XCTAssertEqual(data, payload)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x68-hds-export.bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try vol.export(path: HumanPath(display: "HELLO.TXT"), to: url)
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    /// U3.multi_part
    func testMultiPartition() throws {
        let payload = Data("p0-data".utf8)
        let image = try SyntheticHDS.makeDualPartition(
            fileName: HumanFileName(stem: "P0FILE", ext: "BIN"),
            contents: payload
        )
        let hds = try HdsImage(data: image)
        XCTAssertEqual(hds.partitions.count, 2)
        let v0 = try hds.openVolume(index: 0)
        XCTAssertEqual(try v0.readFile(path: HumanPath(display: "P0FILE.BIN")), payload)
        let v1 = try hds.openVolume(index: 1)
        XCTAssertEqual(try v1.list().count, 0)
        XCTAssertEqual(hds.partitions[1].name.trimmingCharacters(in: .whitespaces).uppercased(), "DATA")
    }

    /// U3.wrong_endian — BE FAT entry must not match LE interpretation for non-symmetric values
    func testFAT16IsBigEndian() throws {
        let image = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "X", ext: "Y"),
            contents: Data([0xAA])
        )
        let vol = try HdsImage(data: image).openVolume()
        // Cluster 2 is 0xFFFF in BE → bytes FF FF; LE read same.
        // Set a asymmetric value 0x1234 at cluster 5 in the table for unit check via FAT16BE.
        var table = vol.fatTableForTesting
        // Write 0x1234 BE at cluster 5
        let idx = 5 * 2
        table[idx] = 0x12
        table[idx + 1] = 0x34
        let fat = FAT16BE(table: table, maxClusters: 100)
        XCTAssertEqual(try fat.entry(cluster: 5), 0x1234)
        XCTAssertEqual(try fat.entryLE(cluster: 5), 0x3412)
        XCTAssertNotEqual(try fat.entry(cluster: 5), try fat.entryLE(cluster: 5))
    }

    /// I3.local_system_hds
    func testLocalSystemHDSIfPresent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("disk/System.HDS")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("disk/System.HDS not available")
        }
        let hds = try HdsImage(url: url)
        XCTAssertFalse(hds.partitions.isEmpty)
        XCTAssertEqual(hds.partitions[0].startRecord, 32)
        let vol = try hds.openVolume(index: 0)
        XCTAssertEqual(vol.bpb.bytesPerSector, 1024)
        // Listing may be large; ensure it does not throw and returns something or empty root is ok
        let list = try vol.list()
        // Real system disk should have files
        XCTAssertFalse(list.isEmpty, "expected files on System.HDS root")
    }

    func testDetectHDS() throws {
        let image = try SyntheticHDS.makeMinimal()
        let d = ImageDetector.detect(data: image)
        XCTAssertEqual(d.kind, .hds)
    }
}
