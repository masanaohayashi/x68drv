import SwiftUI
import AppKit
import X68Core

/// Minimal preferences / about window (PRD-3).
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("x68drv")
                .font(.title2.bold())

            LabeledContent("App") {
                Text(appVersion)
            }
            LabeledContent("X68Core") {
                Text(X68Core.version)
                    .textSelection(.enabled)
            }

            Text("Open X68000 disk images (.xdf / .hds / .hdf) in Finder after FUSE-T is available. v0.1 is read-only.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Login-item toggle lands in Phase 5 (SMAppService).
            Toggle("Open at Login", isOn: .constant(false))
                .disabled(true)
                .help("Implemented in Phase 5")

            HStack {
                Spacer()
                Button("OK") {
                    // PRD: OK closes the window; it does not quit the app.
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
}
