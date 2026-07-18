import Foundation

/// Product launch modes (design.md PRD-2).
public enum LaunchMode: String, Equatable, Sendable {
    /// User opened the .app → show settings.
    case interactive
    /// Login item / silent launch → menu bar only.
    case silent
    /// Finder opened one or more disk images → mount path (Phase 6).
    case document
}

/// Pure launch-mode decision for unit tests and the app shell.
public enum LaunchRouter {
    /// Decide mode from explicit launch facts.
    ///
    /// Priority: login-item silent > document open > interactive.
    public static func mode(
        launchedAsLoginItem: Bool,
        documentURLs: [URL]
    ) -> LaunchMode {
        if launchedAsLoginItem {
            return .silent
        }
        if !documentURLs.isEmpty {
            return .document
        }
        return .interactive
    }

    /// Detect explicit test/login hooks in process environment and argv.
    public static func isExplicitLoginLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if arguments.contains("--launched-at-login") {
            return true
        }
        if environment["X68DRV_LAUNCHED_AT_LOGIN"] == "1" {
            return true
        }
        return false
    }
}
