import Foundation

/// Errors produced by X68Core (format / filesystem / I/O / limits).
public enum X68Error: Error, Equatable, Sendable {
    case outOfBounds(offset: Int, size: Int, available: Int)
    case format(String)
    case unsupported(String)
    case filesystem(String)
    case io(String)
    case limit(String)
    case encoding(String)

    public var localizedDescription: String {
        switch self {
        case let .outOfBounds(offset, size, available):
            return "Out of bounds: offset=\(offset) size=\(size) available=\(available)"
        case let .format(msg),
             let .unsupported(msg),
             let .filesystem(msg),
             let .io(msg),
             let .limit(msg),
             let .encoding(msg):
            return msg
        }
    }
}
