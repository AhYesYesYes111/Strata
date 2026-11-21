import AppKit
import SwiftUI

private enum PrivacyPane: String {
    case disk = "Privacy_AllFiles"
    case folders = "Privacy_FilesAndFolders"
    case automation = "Privacy_Automation"

    var title: String {
        switch self {
        case .disk: return tr("完全磁盘访问权限", "Full Disk Access")
        case .folders: return tr("文件与文件夹", "Files & Folders")
        case .automation: return tr("自动化", "Automation")
        }
    }

    var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + rawValue)!
    }
}

struct PermissionsView: View {
    var openSettingsOnAppear = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @State private var didStartSetup = false
    @State private var failedPane: PrivacyPane?

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 27, weight: .medium)).foregroundStyle(StrataColor.mint)
                    .frame(width: 50, height: 50)
                    .background(StrataColor.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("权限设置", "Permissions"))
                        .font(.system(size: 24, weight: .semibold))
                    Text(tr("查看系统状态和应用列表可直接使用普通权限。", "Status and Apps work with standard access."))
                        .font(.callout).foregroundStyle(StrataColor.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 12) {
                Text(PrivacyPane.disk.title).font(.headline)
                Text(tr("磁盘分析会跳过桌面、文稿和照片图库等位置。要测量某个位置，请在「磁盘分析」里选择该文件夹。如果 macOS 要求更高权限，可在此管理。", "Disk analysis skips locations such as Desktop, Documents and Photos libraries. To measure one, choose that folder in Analyze. If macOS requires more access, you can manage it here."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: "app.dashed").accessibilityHidden(true)
                    Text(verbatim: Bundle.main.bundleURL.path).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(Bundle.main.bundleURL.path)
                    Spacer(minLength: 0)
                    Button { reveal(Bundle.main.bundleURL) } label: {
                        Image(systemName: "folder").frame(width: 24, height: 23)
                    }
                    .buttonStyle(.plain)
                    .help(tr("在访达中显示 Strata", "Show Strata in Finder"))
                    .accessibilityLabel(tr("在访达中显示 Strata", "Show Strata in Finder"))
                }
                .foregroundStyle(StrataColor.muted)
                .padding(.leading, 9).padding(.trailing, 2)
                .background(StrataColor.paper.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))

                Button { open(.disk) } label: {
                    HStack(spacing: 7) {
                        Text(tr("打开系统设置", "Open System Settings"))
                        Image(systemName: "arrow.up.forward").imageScale(.small)
                    }
                }
                .buttonStyle(ActionStyle(isPrimary: true))
                .accessibilityIdentifier("access-full-disk-settings")
            }
            .padding(16)
            .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrataColor.border))

            VStack(alignment: .leading, spacing: 0) {
                paneRow(.folders, icon: "folder", detail: tr("单独管理桌面、文稿和下载文件夹的访问权限。", "Manage access to Desktop, Documents and Downloads individually."))
                Divider().opacity(0.6)
                paneRow(.automation, icon: "app.connected.to.app.below.fill", detail: tr("清理时，macOS 可能询问是否允许查询正在运行的应用。", "During cleanup, macOS may ask to let Strata identify running apps."))
            }
            .padding(.vertical, 5)

            if let failedPane {
                Text(tr("请手动打开「系统设置」→「隐私与安全性」→「\(failedPane.title)」。", "Open System Settings → Privacy & Security → \(failedPane.title) manually."))
                    .font(.callout).foregroundStyle(StrataColor.ink)
                    .padding(.bottom, 8)
            }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                Text(tr("权限由系统显示和确认。更改后重新扫描；若 macOS 提示，请重新打开 Strata。", "Review the switches in System Settings, then scan again. Reopen Strata if macOS prompts you."))
                    .font(.caption).foregroundStyle(StrataColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(tr("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ActionStyle())
            }
            .padding(.top, 12)
        }
        .padding(24).frame(width: 548)
        .foregroundStyle(StrataColor.ink)
        .background(StrataColor.paper)
        .onAppear {
            guard openSettingsOnAppear, !didStartSetup else { return }
            didStartSetup = true
            open(.disk)
        }
    }

    private func paneRow(_ pane: PrivacyPane, icon: String, detail: String) -> some View {
        Button { open(pane) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 24).foregroundStyle(StrataColor.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(StrataColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(StrataColor.muted)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityHint(detail)
        .accessibilityIdentifier("access-" + pane.rawValue)
    }

    private func open(_ pane: PrivacyPane) {
        failedPane = nil
        openURL(pane.url) { accepted in
            if !accepted { failedPane = pane }
        }
    }
}
