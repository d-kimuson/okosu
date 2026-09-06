import AppKit
import ServiceManagement
import SwiftUI

/// 設定ウィンドウの中身。LSUIElement アプリには通常のメニューバーがないため、
/// ポップオーバーの歯車ボタンから `openSettings` 通知経由で開く。
struct SettingsView: View {
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("ホットキー") {
                KeyboardShortcuts.Recorder(for: .togglePopover) {
                    Text("録音の開始／終了")
                }
                Text("クリックして新しいキーを押す。Delete でクリア。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("一般") {
                Toggle("ログイン時に起動する", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("モデル") {
                LabeledContent("GGML", value: ModelManager.ggmlURL.lastPathComponent)
                LabeledContent("配置先", value: ModelManager.supportDirectory.path)
                LabeledContent("ANE encoder", value: encoderStatus)
                if let binary = resolvedBinary {
                    LabeledContent("whisper-stream", value: binary)
                }
            }
            Section {
                Button("Okosu を終了する") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
    }

    private var encoderStatus: String {
        var isDir: ObjCBool = false
        let url = ModelManager.encoderURL
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        return exists ? "あり（ANE）" : "なし（Metal）"
    }

    private var resolvedBinary: String? {
        try? WhisperBinary.resolve()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchError = "ログイン項目の変更に失敗: \(error.localizedDescription)"
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

#Preview {
    SettingsView()
}
