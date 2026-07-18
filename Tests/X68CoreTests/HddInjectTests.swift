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

    /// Stage B: delete root file; name gone, fsck clean, free space reusable.
    func testDeleteRootFile() throws {
        let payload = Data("to-be-deleted".utf8)
        let base = try SyntheticHDS.makeWithFile(
            fileName: HumanFileName(stem: "VICTIM", ext: "TXT"),
            contents: payload
        )
        let part = try HdsImage(data: base).partitions[0]

        let (afterDel, del) = try HddInject.deleteRootFile(
            imageData: base,
            partition: part,
            fileName: HumanFileName(stem: "VICTIM", ext: "TXT")
        )
        XCTAssertEqual(del.remoteName.uppercased(), "VICTIM.TXT")
        XCTAssertGreaterThanOrEqual(del.freedClusters, 1)

        let vol = try HdsImage(data: afterDel).openVolume()
        XCTAssertFalse(try vol.list().contains(where: { $0.name.display.uppercased() == "VICTIM.TXT" }))
        XCTAssertTrue(try vol.fsck().isClean)

        // Reuse freed space with inject
        let (afterInj, inj) = try HddInject.injectRootFile(
            imageData: afterDel,
            partition: part,
            fileName: HumanFileName(stem: "NEW", ext: "BIN"),
            contents: Data("reuse".utf8),
            overwrite: false
        )
        XCTAssertEqual(inj.bytesWritten, 5)
        let vol2 = try HdsImage(data: afterInj).openVolume()
        XCTAssertEqual(try vol2.readFile(path: HumanPath(display: "NEW.BIN")), Data("reuse".utf8))
        XCTAssertTrue(try vol2.fsck().isClean)
    }

    func testDeleteMissingFileThrows() throws {
        let base = try SyntheticHDS.makeMinimal()
        let part = try HdsImage(data: base).partitions[0]
        XCTAssertThrowsError(
            try HddInject.deleteRootFile(
                imageData: base,
                partition: part,
                fileName: HumanFileName(stem: "NOPE", ext: "TXT")
            )
        )
    }

    /// Stage C: mkdir then inject into subdirectory; list/read/fsck.
    func testMkdirAndInjectIntoSubdir() throws {
        let base = try SyntheticHDS.makeMinimal()
        let part = try HdsImage(data: base).partitions[0]

        let (withDir, mk) = try HddInject.mkdir(
            imageData: base,
            partition: part,
            parentPath: HumanPath(),
            name: HumanFileName(stem: "SUB", ext: "")
        )
        XCTAssertEqual(mk.remoteName.uppercased(), "SUB")
        XCTAssertGreaterThanOrEqual(mk.firstCluster, 2)

        let payload = Data("in-subdir".utf8)
        let (withFile, inj) = try HddInject.injectFile(
            imageData: withDir,
            partition: part,
            path: HumanPath(display: "SUB/NEST.TXT"),
            contents: payload,
            overwrite: false
        )
        XCTAssertEqual(inj.remoteName.uppercased(), "SUB/NEST.TXT")

        let vol = try HdsImage(data: withFile).openVolume()
        let root = try vol.list()
        XCTAssertTrue(root.contains(where: { $0.isDirectory && $0.name.stem.uppercased() == "SUB" }))
        let nested = try vol.list(path: HumanPath(display: "SUB"))
        XCTAssertTrue(nested.contains(where: { $0.name.display.uppercased() == "NEST.TXT" }))
        XCTAssertEqual(
            try vol.readFile(path: HumanPath(display: "SUB/NEST.TXT")),
            payload
        )
        XCTAssertTrue(try vol.fsck().isClean)

        let (afterDel, _) = try HddInject.deleteFile(
            imageData: withFile,
            partition: part,
            path: HumanPath(display: "SUB/NEST.TXT")
        )
        let vol2 = try HdsImage(data: afterDel).openVolume()
        XCTAssertTrue(try vol2.list(path: HumanPath(display: "SUB")).isEmpty)
        XCTAssertTrue(try vol2.fsck().isClean)
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
