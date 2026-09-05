import SwiftUI

/// セッション（開始→停止の区間）単位のカード表示。
/// カードごとに編集・コピーできる。確定チャンクはカード内に機械的な改行区切りで追記される。
struct ContentView: View {
    @EnvironmentObject private var store: TranscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            transcriptList
            Spacer()
            footer
        }
        .padding()
        .frame(width: 360, height: 480)
    }

    private var header: some View {
        HStack {
            Image(systemName: store.isListening ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(store.isListening ? .red : .secondary)
            Text("Okosu")
                .font(.headline)
            Spacer()
            Text(store.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("設定を開く (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    @ViewBuilder
    private var transcriptList: some View {
        switch store.state {
        case let .error(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("再試行") { store.retry() }
            }
        case let .starting(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.downloadProgress > 0, store.downloadProgress < 1 {
                    ProgressView(value: store.downloadProgress)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
        default:
            if store.sessions.isEmpty {
                Text("開始ボタンを押してマイクに向かって話すと、ここに記録されます")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(store.sessions) { session in
                                SessionCard(session: session)
                                    .id(session.id)
                            }
                        }
                    }
                    .onChange(of: store.sessions.last?.text ?? "") { _, _ in
                        if let last = store.sessions.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if store.isListening {
                Button("停止") { store.stop() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("開始") { store.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBooting)
            }
            if case .listening = store.state, !store.usesANE {
                Text("Metal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("クリア") { store.clear() }
                .disabled(!store.canCopy)
            Button("すべてコピー") { store.copyToClipboard() }
                .disabled(!store.canCopy)
                .keyboardShortcut("c", modifiers: .command)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// 1セッションのカード。右上に編集・コピー。
private struct SessionCard: View {
    @EnvironmentObject private var store: TranscriptionStore
    var session: RecordingSession

    @State private var isEditing = false
    @State private var draft = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(timeRange)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if session.isLive {
                    Text("受付中")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
                if isEditing {
                    Button("キャンセル") { isEditing = false }
                    Button("保存") { commit() }
                } else {
                    Button("編集") {
                        draft = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        isEditing = true
                    }
                }
                Button(copied ? "コピー済み" : "コピー") {
                    store.copySession(id: session.id)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copied = false
                    }
                }
                .disabled(copied)
            }
            .font(.caption)
            if isEditing {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 80)
                    .border(Color(nsColor: .separatorColor))
            } else {
                Text(session.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .contextMenu {
            Button("削除") { store.removeSession(id: session.id) }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var timeRange: String {
        let start = Self.timeFormatter.string(from: session.startedAt)
        if let endedAt = session.endedAt {
            return "\(start) – \(Self.timeFormatter.string(from: endedAt))"
        }
        return start
    }

    private func commit() {
        isEditing = false
        store.updateSession(id: session.id, text: draft)
    }
}

#Preview {
    ContentView()
        .environmentObject(TranscriptionStore())
}
