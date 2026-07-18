import Foundation

/// Detected on-disk image kind (host file, not partition).
public enum ImageKind: String, Equatable, Sendable {
    case xdf
    case dim
    case hds
    case hdf
    case unknown
}

public struct DetectionResult: Equatable, Sendable {
    public var kind: ImageKind
    public var confidence: Confidence
    public var evidence: [String]
    /// Byte offset where the filesystem volume starts (0 for raw XDF, 256 for DIM).
    public var volumeOffset: Int
    public var size: Int

    public enum Confidence: String, Equatable, Sendable {
        case high
        case medium
        case none
    }

    public init(
        kind: ImageKind,
        confidence: Confidence,
        evidence: [String],
        volumeOffset: Int,
        size: Int
    ) {
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
        self.volumeOffset = volumeOffset
        self.size = size
    }
}
