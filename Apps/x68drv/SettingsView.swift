import SwiftUI
import AppKit
import X68Core

/// Preferences / about window (PRD-3).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

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

            Text("Open X68000 disk images (.xdf / .hds / .hdf / .dim) from Finder. v0.1 is read-only; FUSE-T is required for mounting (Phase 6).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Open at Login", isOn: $model.openAtLogin)

            Text(model.loginItemStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let err = model.loginItemError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let msg = model.lastDocumentMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("OK") {
                    // PRD: close window only; do not quit.
                    model.closeSettings()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .onAppear {
            model.refreshLoginItemState()
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppModel.shared)
}
