import Foundation
import ServiceManagement

/// Thin wrapper around SMAppService.mainApp (macOS 13+).
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Open at Login: On"
        case .notRegistered:
            return "Open at Login: Off"
        case .notFound:
            return "Open at Login: unavailable"
        case .requiresApproval:
            return "Open at Login: needs approval in System Settings"
        @unknown default:
            return "Open at Login: unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
