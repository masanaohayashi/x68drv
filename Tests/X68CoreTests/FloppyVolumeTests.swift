import XCTest
@testable import X68Core

final class FloppyVolumeTests: XCTestCase {
    /// U2.detect_xdf
    func testDetectXDF() throws {
        let image = try SyntheticXDF.makeEmpty2HD()
        let d = ImageDetector.detect(data: image)
        XCTAssertEqual(d.kind, .xdf)
        XCTAssertEqual(d.confidence, .high)
        XCTAssertEqual(d.volumeOffset, 0)
    }

    /// U2.detect_dim
    func testDetectDIM() throws {
        let image = try SyntheticDIM.makeEmpty2HD()
        let d = ImageDetector.detect(data: image)
        XCTAssertEqual(d.kind, .dim)
        XCTAssertEqual(d.volumeOffset, 256)
        XCTAssertTrue(d.evidence.contains(where: { $0.contains("DIFC") }))
    }

    /// U2.list_synth / U2.read_synth
    func testListAndReadSyntheticXDF() throws {
        let payload = Data("hello-x68-phase2".utf8)
        let image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "HELLO", ext: "TXT"),
            contents: payload
        )
        let vol = try FloppyVolume(imageData: image)
        let list = try vol.list()
        XCTAssertTrue(list.contains(where: { $0.name.display.uppercased() == "HELLO.TXT" }))
        let data = try vol.readFile(path: HumanPath(display: "HELLO.TXT"))
        XCTAssertEqual(data, payload)
    }

    /// U2.export_synth
    func testExportSynthetic() throws {
        let payload = Data("export-me".utf8)
        let image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "OUT", ext: "BIN"),
            contents: payload
        )
        let vol = try FloppyVolume(imageData: image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x68drv-export-test.bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try vol.export(path: HumanPath(display: "OUT.BIN"), to: url)
        let readBack = try Data(contentsOf: url)
        XCTAssertEqual(readBack, payload)
    }

    /// U2.fallback_bpb — trash BPB bytes but keep 2HD size + standard root layout
    func testFallbackBPB() throws {
        var image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "FALL", ext: "DAT"),
            contents: Data("fb".utf8)
        )
        // Corrupt DOS BPB fields so parse fails without fallback.
        for i in 0x0B..<0x18 { image[i] = 0x00 }
        image[0] = 0x60
        image[1] = 0x1C
        // Root still at 0x1400 from factory
        let vol = try FloppyVolume(imageData: image)
        XCTAssertTrue(vol.bpb.usedFallback)
        let list = try vol.list()
        XCTAssertTrue(list.contains(where: { $0.name.stem.uppercased() == "FALL" }))
    }

    /// U2.reject_size
    func testRejectWrongXDFSize() throws {
        var image = try SyntheticXDF.makeEmpty2HD()
        image.append(0x00) // 1261569
        // Detection may say unknown; open as forced xdf path via wrong size
        let det = ImageDetector.detect(data: image)
        XCTAssertNotEqual(det.kind, .xdf)
        // Construct detection as xdf manually shouldn't happen; opening wrong size:
        // If we strip to smaller
        let small = Data(repeating: 0, count: 1000)
        XCTAssertThrowsError(try FloppyVolume(imageData: small))
    }

    /// U2.fat_cycle
    func testFAT12CycleDetected() throws {
        var image = try SyntheticXDF.make2HD(
            fileName: HumanFileName(stem: "LOOP", ext: "BIN"),
            contents: Data([1, 2, 3])
        )
        // Poison FAT: cluster 2 -> 3, 3 -> 2
        let fat1 = 1024
        setFAT12(&image, fatOffset: fat1, cluster: 2, value: 3)
        setFAT12(&image, fatOffset: fat1, cluster: 3, value: 2)
        setFAT12(&image, fatOffset: fat1 + 2048, cluster: 2, value: 3)
        setFAT12(&image, fatOffset: fat1 + 2048, cluster: 3, value: 2)
        // Also need cluster field on dir entry already 2
        let vol = try FloppyVolume(imageData: image)
        XCTAssertThrowsError(try vol.readFile(path: HumanPath(display: "LOOP.BIN"))) { err in
            guard let e = err as? X68Error else {
                return XCTFail("wrong error type")
            }
            if case let .filesystem(msg) = e {
                XCTAssertTrue(msg.lowercased().contains("cycle"), msg)
            } else {
                XCTFail("expected filesystem cycle error")
            }
        }
    }

    func testDIMListRead() throws {
        let payload = Data("dim-payload".utf8)
        let image = try SyntheticDIM.make2HD(
            fileName: HumanFileName(stem: "DIMF", ext: "TXT"),
            contents: payload
        )
        let vol = try FloppyVolume(imageData: image)
        XCTAssertEqual(vol.detection.kind, .dim)
        XCTAssertEqual(try vol.readFile(path: HumanPath(display: "DIMF.TXT")), payload)
    }

    /// I2.local_osr2 — skipped unless disk/ present
    func testLocalOSR2IfPresent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/X68CoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("disk/OSR2.xdf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("disk/OSR2.xdf not available (local-only golden)")
        }
        let vol = try FloppyVolume(url: url)
        let list = try vol.list()
        XCTAssertFalse(list.isEmpty)
        let names = list.map { $0.name.display.uppercased() }
        XCTAssertTrue(
            names.contains(where: { $0.contains("HUMAN") || $0.contains("OSR2") }),
            "unexpected listing: \(names)"
        )
    }

    // FAT12 poke helper (same packing as SyntheticXDF)
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
