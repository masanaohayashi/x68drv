import Foundation
import CoreFoundation

/// Shift_JIS / Windows CP932 helpers for Human68k filenames.
public enum EncodingCP932 {
    /// CFString DOS Japanese (CP932).
    private static var nsEncoding: String.Encoding {
        let cf = CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return String.Encoding(rawValue: ns)
    }

    /// Encode Unicode text to CP932 bytes. Fails if any scalar cannot be represented.
    public static func encode(_ string: String) throws -> Data {
        guard let data = string.data(using: nsEncoding, allowLossyConversion: false) else {
            throw X68Error.encoding("Cannot encode to CP932: \(string)")
        }
        return data
    }

    /// Decode CP932 bytes to Unicode.
    public static func decode(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: nsEncoding) else {
            throw X68Error.encoding("Cannot decode CP932 (\(data.count) bytes)")
        }
        return string
    }

    /// Decode for display; unreadable sequences become `\xNN` escapes.
    public static func decodeLossy(_ data: Data) -> String {
        if let string = String(data: data, encoding: nsEncoding) {
            return string
        }
        return data.map { String(format: "\\x%02X", $0) }.joined()
    }

    /// True if `byte` is a Shift_JIS lead byte (first of a double-byte character).
    public static func isLeadByte(_ byte: UInt8) -> Bool {
        (0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte)
    }
}
