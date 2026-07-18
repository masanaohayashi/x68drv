import Foundation

/// Minimal DIM wrapper: 256-byte header + full 2HD XDF payload.
public enum SyntheticDIM {
    public static let headerSize = 256

    public static func wrap(xdfPayload: Data) throws -> Data {
        var header = Data(repeating: 0, count: headerSize)
        // Media type byte often at 0; leave 0.
        // "DIFC HEADER" at exactly 0xAB
        let magic = Array("DIFC HEADER".utf8)
        for (i, b) in magic.enumerated() {
            header[0xAB + i] = b
        }
        return header + xdfPayload
    }

    public static func makeEmpty2HD() throws -> Data {
        try wrap(xdfPayload: SyntheticXDF.makeEmpty2HD())
    }

    public static func make2HD(fileName: HumanFileName, contents: Data) throws -> Data {
        try wrap(xdfPayload: SyntheticXDF.make2HD(fileName: fileName, contents: contents))
    }
}
