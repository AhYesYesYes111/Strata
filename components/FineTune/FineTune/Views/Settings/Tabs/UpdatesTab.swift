// FineTune/Views/Settings/Tabs/UpdatesTab.swift
import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var updateManager: UpdateManager

    #if STRATA_COMPANION
    var body: some View {
        SettingsSection("Software Updates") {
            Text("This copy of FineTune is included with Strata. Update Strata to get the latest mixer.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    #else
    private var lastCheckDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let date = updateManager.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Version \(version) · \(formatter.localizedString(for: date, relativeTo: .now))"
        }
        return "Version \(version) · Never checked"
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyChecksForUpdates },
            set: { updateManager.automaticallyChecksForUpdates = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Software Updates") {
                    SettingsRow(
                        "Automatic updates",
                        description: "Check for new versions automatically"
                    ) {
                        Toggle("", isOn: automaticallyChecksBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    SettingsRowDivider()
                    SettingsRow(
                        "Last checked",
                        description: lastCheckDescription
                    ) {
                        Button("Check Now") {
                            updateManager.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
    #endif
}
