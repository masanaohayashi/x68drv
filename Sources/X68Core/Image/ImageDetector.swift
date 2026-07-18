import Foundation

/// Magic-first image classification (design.md detector flowchart).
public enum ImageDetector {
    public static let xdf2HDSize = 1_261_568
    public static let dimHeaderSize = 256
    private static let difcHeader = Data("DIFC HEADER".utf8)

    public static func detect(data: Data) -> DetectionResult {
        let size = data.count
        var evidence: [String] = []

        // DIM: exact "DIFC HEADER" at 0xAB
        if size >= 0xAB + 11 {
            let slice = data[0xAB..<(0xAB + 11)]
            if Data(slice) == difcHeader {
                evidence.append("magic:DIFC HEADER@0xAB")
                return DetectionResult(
                    kind: .dim,
                    confidence: .high,
                    evidence: evidence,
                    volumeOffset: dimHeaderSize,
                    size: size
                )
            }
        }

        // HDS / SxSI
        if size >= 8, Data(data[0..<8]) == Data("X68SCSI1".utf8) {
            evidence.append("magic:X68SCSI1@0")
            return DetectionResult(
                kind: .hds,
                confidence: .high,
                evidence: evidence,
                volumeOffset: 0,
                size: size
            )
        }

        // XDF classic 2HD size
        if size == xdf2HDSize {
            evidence.append("size:1261568")
            return DetectionResult(
                kind: .xdf,
                confidence: .high,
                evidence: evidence,
                volumeOffset: 0,
                size: size
            )
        }

        // HDF: headerless SASI with X68K partition table at 0x400 (256-byte LBA4)
        if size >= 0x404, Data(data[0x400..<0x404]) == Data("X68K".utf8) {
            evidence.append("magic:X68K@0x400")
            evidence.append("class:hdf-sasi-x68k-256")
            if HdfImage.xm6FixedSizes.contains(size) {
                evidence.append("size:xm6-fixed")
            }
            let confidence: DetectionResult.Confidence =
                HdfImage.xm6FixedSizes.contains(size) ? .high : .medium
            return DetectionResult(
                kind: .hdf,
                confidence: confidence,
                evidence: evidence,
                volumeOffset: 0,
                size: size
            )
        }

        return DetectionResult(
            kind: .unknown,
            confidence: .none,
            evidence: evidence,
            volumeOffset: 0,
            size: size
        )
    }

    public static func detect(url: URL) throws -> DetectionResult {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return detect(data: data)
    }
}
