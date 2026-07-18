import XCTest
@testable import X68Core

final class DiskImageTests: XCTestCase {
    /// U4.open_matrix
    func testOpenMatrixXDF_DIM_HDS() throws {
        let xdf = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "A", ext: "TXT"),
            contents: Data("a".utf8)
        )
        let dim = try SyntheticDIM.make2HD(
            fileName: HumanFileName(stem: "B", ext: "TXT"),
            contents: Data("b".utf8)
        )
        let hds = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "C", ext: "TXT"),
            contents: Data("c".utf8)
        )

        let dx = DiskImage.open(data: xdf)
        XCTAssertEqual(dx.detection.kind, .xdf)
        XCTAssertEqual(try dx.openDefaultVolume().readFile(path: HumanPath(display: "A.TXT")), Data("a".utf8))

        let dd = DiskImage.open(data: dim)
        XCTAssertEqual(dd.detection.kind, .dim)
        XCTAssertEqual(try dd.openDefaultVolume().readFile(path: HumanPath(display: "B.TXT")), Data("b".utf8))

        let dh = DiskImage.open(data: hds)
        XCTAssertEqual(dh.detection.kind, .hds)
        XCTAssertEqual(try dh.partitionCount(), 1)
        XCTAssertEqual(try dh.openDefaultVolume().readFile(path: HumanPath(display: "C.TXT")), Data("c".utf8))
    }

    /// U4.unknown
    func testUnknownRejected() {
        let junk = Data(repeating: 0x5A, count: 1024)
        let disk = DiskImage.open(data: junk)
        XCTAssertEqual(disk.detection.kind, .unknown)
        XCTAssertThrowsError(try disk.openDefaultVolume())
    }

    /// U4.fsck_clean
    func testFsckCleanXDFAndHDS() throws {
        let xdf = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "OK", ext: "BIN"),
            contents: Data("ok".utf8)
        )
        let reportX = try DiskImage.open(data: xdf).openDefaultVolume().fsck()
        XCTAssertTrue(reportX.isClean, "\(reportX.issues)")

        let hds = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "OK", ext: "BIN"),
            contents: Data("ok".utf8)
        )
        let reportH = try DiskImage.open(data: hds).openDefaultVolume().fsck()
        XCTAssertTrue(reportH.isClean, "\(reportH.issues)")
    }

    /// U4.fsck_dirty — FAT cycle
    func testFsckDirtyCycle() throws {
        var image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "LOOP", ext: "BIN"),
            contents: Data([1, 2, 3])
        )
        let fat1 = 1024
        setFAT12(&image, fatOffset: fat1, cluster: 2, value: 3)
        setFAT12(&image, fatOffset: fat1, cluster: 3, value: 2)
        setFAT12(&image, fatOffset: fat1 + 2048, cluster: 2, value: 3)
        setFAT12(&image, fatOffset: fat1 + 2048, cluster: 3, value: 2)

        let report = try DiskImage.open(data: image).openDefaultVolume().fsck()
        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.issues.contains(where: { $0.kind == .cycle }))
    }

    /// U4.fsck_dirty — short chain (size claims more than one cluster)
    func testFsckShortChain() throws {
        var image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "BIG", ext: "BIN"),
            contents: Data([0x11])
        )
        // Claim size 5000 but only one cluster (1024)
        try Endian.writeUInt32LE(5000, to: &image, at: 0x1400 + 28)
        let report = try DiskImage.open(data: image).openDefaultVolume().fsck()
        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.issues.contains(where: { $0.kind == .shortChain }))
    }

    private func setFAT12(_ image: inout Data, fatOffset: Int, cluster: Int, value: Int) {
        let v = value & 0xFFF
        let index = fatOffset + (cluster * 3) / 2
        if cluster & 1 == 0 {
            image[index] = UInt8(v & 0xFF)
            image[index + 1] = (image[index + 1] & 0xF0) | UInt8((v >> 8) & 0x0F)
        } else {
            image[index] = (image[index] & 0x0F) | UInt8((v << 4) & 0xF0)
            image[index + 1] = UInt8((v >> 4) & 0xFF)
        }
    }
}
