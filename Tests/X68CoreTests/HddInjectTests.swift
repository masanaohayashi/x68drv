import XCTest
@testable import X68Core

final class HddInjectTests: XCTestCase {
    /// Stage A: inject new root file into synthetic HDS; read back + fsck clean.
    func testInjectNewRootFile() throws {
        let base = try SyntheticHDS.makeMinimal()
        let hds = try HdsImage(data: base)
        let part = hds.partitions[0]
        let payload = Data("inject-stage-a".utf8)

        let (mutated, result) = try HddInject.injectRootFile(
            imageData: base,
            partition: part,
            fileName: HumanFileName(stem: "INJECT", ext: "TXT"),
            contents: payload,
            overwrite: false
        )
        XCTAssertEqual(result.bytesWritten, payload.count)
        XCTAssertFalse(result.overwritten)
        XCTAssertGreaterThanOrEqual(result.firstCluster, 2)

        let vol = try HdsImage(data: mutated).openVolume()
        let list = try vol.list()
        XCTAssertTrue(list.contains(where: { $0.name.display.uppercased() == "INJECT.TXT" }))
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "INJECT.TXT")), payload)
        XCTAssertTrue(try vol.fsck().isClean)
    }

    /// Overwrite requires flag; with flag, content replaced and fsck clean.
    func testInjectOverwrite() throws {
        let payload1 = Data("first".utf8)
        let base = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "SAME", ext: "BIN"),
            contents: payload1
        )
        let part = try HdsImage(data: base).partitions[0]

        XCTAssertThrowsError(
            try HddInject.injectRootFile(
                imageData: base,
                partition: part,
                fileName: HumanFileName(stem: "SAME", ext: "BIN"),
                contents: Data("second".utf8),
                overwrite: false
            )
        )

        let payload2 = Data("second-longer-payload!!!".utf8)
        let (mutated, result) = try HddInject.injectRootFile(
            imageData: base,
            partition: part,
            fileName: HumanFileName(stem: "SAME", ext: "BIN"),
            contents: payload2,
            overwrite: true
        )
        XCTAssertTrue(result.overwritten)
        let vol = try HdsImage(data: mutated).openVolume()
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "SAME.BIN")), payload2)
        XCTAssertTrue(try vol.fsck().isClean)
    }

    /// Empty file: size 0, cluster 0.
    func testInjectEmptyFile() throws {
        let base = try SyntheticHDS.makeMinimal()
        let part = try HdsImage(data: base).partitions[0]
        let (mutated, result) = try HddInject.injectRootFile(
            imageData: base,
            partition: part,
            fileName: HumanFileName(stem: "EMPTY", ext: "DAT"),
            contents: Data(),
            overwrite: false
        )
        XCTAssertEqual(result.clusterCount, 0)
        XCTAssertEqual(result.firstCluster, 0)
        let vol = try HdsImage(data: mutated).openVolume()
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "EMPTY.DAT")), Data())
        XCTAssertTrue(try vol.fsck().isClean)
    }

    func testFAT16AllocateChain() throws {
        // Minimal table: clusters 0..5
        var table = Data(count: 12)
        table[0] = 0xFF
        table[1] = 0xF7
        table[2] = 0xFF
        table[3] = 0xFF
        // 2..5 free
        var fat = FAT16BE(table: table, maxClusters: 5)
        let chain = try fat.allocateChain(count: 2)
        XCTAssertEqual(chain, [2, 3])
        XCTAssertEqual(try fat.entry(cluster: 2), 3)
        XCTAssertEqual(try fat.entry(cluster: 3), FAT16BE.endOfChain)
        try fat.freeChain(chain)
        XCTAssertEqual(try fat.entry(cluster: 2), 0)
        XCTAssertEqual(try fat.entry(cluster: 3), 0)
    }
}
