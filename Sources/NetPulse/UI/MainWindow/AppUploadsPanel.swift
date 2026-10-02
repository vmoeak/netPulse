import AppKit
import SwiftUI

/// 检查上传内容 in an app's detail: one switch that routes just this app
/// through the upload inspector (see `InspectorRouting`), and the requests
/// it sent, without leaving the app's page.
struct AppInspectSwitch: View {
    @ObservedObject var inspector: UploadInspector
    let app: AppUsage
    var onSwitch: (Bool) -> Void = { _ in }

    var body: some View {
        let busy = inspector.busyAppIDs.contains(app.id)
        let on = inspector.isInspecting(bundleID: app.bundleID)
        if InspectorRouting.canRelaunch(bundleID: app.bundleID) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                if on && !busy {
                    Text("检查中").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentBlue)
                }
                Toggle("检查上传内容", isOn: Binding(
                    get: { on },
                    set: { on in
                        guard confirmRelaunch(on: on) else { return }
                        inspector.setInspecting(on, appID: app.id, bundleID: app.bundleID)
                        onSwitch(on)
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(busy)
                    .help("重启这个 App，只让它经过 NetPulse 的本机代理联网，显示它上传的每条请求；关闭后再重启一次恢复原样。不改系统代理。")
            }
            .font(.system(size: 11.5))
        }
    }

    /// Reopening an app can lose unsaved work, so it asks first.
    private func confirmRelaunch(on: Bool) -> Bool {
        guard InspectorRouting.runningApp(bundleID: app.bundleID) != nil else { return true }
        let alert = NSAlert()
        alert.messageText = on ? "重启「\(app.name)」并检查它上传的内容？" : "重启「\(app.name)」恢复直接联网？"
        alert.informativeText = on
            ? "NetPulse 会退出这个 App，再让它经过本机检查代理重新打开。不改系统代理、不改证书信任。未保存的内容请先保存。"
            : "NetPulse 会退出这个 App 再正常打开。"
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The app's captured requests, under the detail's 上传内容 tab.
struct AppUploadsList: View {
    @ObservedObject var inspector: UploadInspector
    let app: AppUsage
    @State private var opened: CapturedUpload?

    var body: some View {
        let rows = inspector.uploads(forApp: app.id)
        let inspecting = inspector.isInspecting(bundleID: app.bundleID)
        VStack(alignment: .leading, spacing: 0) {
            if let message = inspector.appMessages[app.id] {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(emptyText(inspecting: inspecting))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !InspectorRouting.canRelaunch(bundleID: app.bundleID), let port = inspector.port {
                        SnippetBox(text: inspector.shellSetup(port: port))
                    }
                }
                .padding(.horizontal, 10).padding(.top, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { upload in
                            UploadRow(upload: upload, selected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { opened = upload }
                        }
                    }
                }
            }
        }
        .sheet(item: $opened) { upload in
            VStack(spacing: 0) {
                UploadDetail(upload: upload)
                HStack {
                    Spacer()
                    Button("关闭") { opened = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
            .frame(minWidth: 760, minHeight: 560)
        }
    }

    private func emptyText(inspecting: Bool) -> String {
        if !InspectorRouting.canRelaunch(bundleID: app.bundleID) {
            return inspector.port == nil
                ? "这是命令行进程，NetPulse 没法替它重启。到「上传检查」里点「开始检查」，再按那里的终端命令重新启动它。"
                : "这是命令行进程：在终端运行下面几行，再从同一个终端重新启动它，它的请求就会出现在这里。"
        }
        if inspecting {
            return "已开启，还没有收到请求。在 App 里操作一下；一直没有的话，它可能是只认系统代理的原生 App，或者固定了证书。"
        }
        return "打开右上角「检查上传内容」，NetPulse 会重启这个 App 并列出它上传的每条请求。"
    }
}
