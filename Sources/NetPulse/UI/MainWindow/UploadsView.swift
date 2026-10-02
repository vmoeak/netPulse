import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UploadFindingKind {
    var color: Color {
        switch self {
        case .gitRemote: return Color(hex: 0xFF3B30)
        case .gitStatus: return Color(hex: 0xFF9500)
        case .gitCommit: return Color(hex: 0xAF52DE)
        case .gitIdentity: return Color(hex: 0xFF2D55)
        case .gitFiles: return Color(hex: 0xA2845E)
        case .localPath: return Color(hex: 0x0A84FF)
        }
    }
}

/// 上传检查: what apps sent through the inspecting proxy, request by
/// request, with git information picked out. Full width to the right of the
/// sidebar: a request list, and the selected request's headers and body.
struct UploadsView: View {
    @ObservedObject var inspector: UploadInspector

    var body: some View {
        VStack(spacing: 0) {
            header
            if inspector.uploads.isEmpty {
                SetupGuide(inspector: inspector)
            } else {
                HStack(spacing: 0) {
                    UploadList(inspector: inspector)
                        .frame(width: 360)
                        .overlay(Rectangle().fill(Theme.hairline).frame(width: 0.5), alignment: .trailing)
                    if let upload = inspector.selectedUpload {
                        UploadDetail(upload: upload)
                    } else {
                        EmptyPaneMessage(text: "选择一条请求查看上传内容")
                    }
                }
                if inspector.isRunning { SetupStrip(inspector: inspector) }
            }
        }
        .frame(minWidth: PaneWidth.detailMin - 10, maxWidth: .infinity, maxHeight: .infinity)
        .contentCard()
        .paneDivider()
    }

    private var subtitle: String {
        let gitCount = inspector.uploads.filter(\.hasGit).count
        let counts = "\(inspector.uploads.count) 条请求 · \(gitCount) 条含 Git 信息"
        switch inspector.state {
        case .off: return "未开启 · " + counts
        case .starting: return "正在启动…"
        case .running(let port): return "代理 127.0.0.1:\(port) · " + counts
        case .failed(let message): return "启动失败：" + message
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("上传检查").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 10.5))
                    .foregroundStyle(isFailed ? Color.orange : Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Toggle("只看含 Git 信息", isOn: $inspector.gitOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            Button("清空") { inspector.clear() }
                .disabled(inspector.uploads.isEmpty)
            if inspector.isRunning || inspector.state == .starting {
                Button("停止") { inspector.stop() }
            } else {
                Button("开始检查") { inspector.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: Theme.headerHeight)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private var isFailed: Bool {
        if case .failed = inspector.state { return true }
        return false
    }
}

/// What to do before anything shows up: start the proxy, then point an
/// app at it.
private struct SetupGuide: View {
    @ObservedObject var inspector: UploadInspector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("看清楚 App 到底上传了什么")
                    .font(.system(size: 16, weight: .semibold))
                Text("""
                    普通的流量统计只能看到 App 连了哪个网站、传了多少字节，内容是加密的。上传检查在本机开一个代理：\
                    让 App 通过它联网并信任 NetPulse 自己生成的证书，NetPulse 就能解开 HTTPS，逐条列出 App 发出的请求和内容，\
                    并标出其中的 Git 信息（远程仓库地址、分支、提交记录、git 用户名和邮箱、.git 文件内容）以及本机路径。
                    """)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                step(1, "点右上角「开始检查」。第一次会在本机生成一张专用证书，私钥只存在你的 Mac 上。")
                step(2, "在终端里运行下面几行，再从同一个终端启动要检查的工具（Claude Code、Codex、Gemini CLI、git、curl 等）。")
                if case .running(let port) = inspector.state {
                    SnippetBox(text: inspector.shellSetup(port: port))
                } else {
                    Text("开始检查后这里会显示要运行的命令。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 26)
                }
                step(3, "不读这些环境变量的 App（用系统证书库的原生 App、部分 Rust 工具）还需要在钥匙串里信任这张证书。不用时可以随时取消信任。")
                HStack(spacing: 8) {
                    Button("在钥匙串中信任证书") { inspector.trustCertificate() }
                    Button("取消信任") { inspector.untrustCertificate() }
                    if let message = inspector.trustMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .controlSize(.small)
                .disabled(!inspector.ca.exists && !inspector.isRunning)
                .padding(.leading, 26)
                Text("""
                    只有被设置为走这个代理的 App 会被检查，其他流量不受影响；系统设置了代理（如 Shadowrocket）时，\
                    检查后的请求会继续交给它转发。固定了证书的 App 会拒绝连接，列表里会标为「未解密」。\
                    记录只保存在内存里，退出 NetPulse 即清空。
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accentBlue))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The shell setup again, once requests are listed, for the next terminal.
private struct SetupStrip: View {
    @ObservedObject var inspector: UploadInspector
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(expanded ? "收起终端设置" : "在另一个终端里检查…") { expanded.toggle() }
                    .buttonStyle(.link)
                Spacer()
                if let message = inspector.trustMessage {
                    Text(message).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
                Button("在钥匙串中信任证书") { inspector.trustCertificate() }
                    .controlSize(.small)
            }
            if expanded, case .running(let port) = inspector.state {
                SnippetBox(text: inspector.shellSetup(port: port))
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .top)
    }
}

private struct SnippetBox: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
        .padding(.leading, 26)
    }
}

private struct UploadList: View {
    @ObservedObject var inspector: UploadInspector

    var body: some View {
        let rows = inspector.visibleUploads
        if rows.isEmpty {
            EmptyPaneMessage(text: "没有含 Git 信息的请求")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { upload in
                        UploadRow(upload: upload, selected: upload.id == inspector.selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { inspector.selectedID = upload.id }
                    }
                }
            }
        }
    }
}

private struct UploadRow: View {
    let upload: CapturedUpload
    let selected: Bool

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(upload.method)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(upload.failure == nil ? Theme.accentBlue : .orange)
                Text(upload.host)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if upload.failure != nil {
                    Tag(text: "未解密", color: .orange)
                } else if upload.hasGit {
                    Tag(text: "Git ×\(upload.gitMatchCount)", color: UploadFindingKind.gitRemote.color)
                } else if upload.findings.contains(where: { $0.kind == .localPath }) {
                    Tag(text: "路径", color: UploadFindingKind.localPath.color)
                }
            }
            Text(upload.failure ?? upload.path)
                .font(.system(size: 11, design: upload.failure == nil ? .monospaced : .default))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(Self.time.string(from: upload.date))
                Text(upload.processName).lineLimit(1)
                Spacer()
                if upload.failure == nil { Text("↑ " + Format.bytes(upload.bodySize)) }
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Theme.selectionFill : Color.clear)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct UploadDetail: View {
    let upload: CapturedUpload
    @State private var showHeaders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(upload.method) \(upload.url)")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("导出…") { export() }.controlSize(.small)
                }
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            if let failure = upload.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Spacer()
            } else {
                findings
                DisclosureGroup("请求头（\(upload.headers.count)）", isExpanded: $showHeaders) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(upload.headers.enumerated()), id: \.offset) { _, header in
                            Text("\(header.name): \(CapturedUpload.displayValue(of: header))")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11.5))
                HStack {
                    Text("上传内容 · \(Format.bytes(upload.bodySize))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    if let note = upload.bodyNote {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text("⌘F 查找").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
                if upload.bodyText.isEmpty {
                    EmptyPaneMessage(text: "这条请求没有请求体")
                } else {
                    HighlightedText(id: upload.id, text: upload.bodyText, matches: upload.bodyMatches)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var meta: String {
        var parts = ["\(upload.processName)\(upload.pid.map { "（pid \($0)）" } ?? "")",
                     upload.date.formatted(date: .omitted, time: .standard)]
        if let ua = upload.userAgent { parts.append(ua) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var findings: some View {
        if upload.findings.isEmpty {
            Text("没有发现 Git 信息或本机路径")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(upload.findings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(finding.kind.color).frame(width: 7, height: 7)
                        Text("\(finding.kind.label) ×\(finding.count)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(finding.kind.color)
                            .frame(width: 120, alignment: .leading)
                        Text(finding.samples.joined(separator: "   "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2).truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardFill))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(upload.host)-upload-\(upload.id).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? upload.exportText.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The body in a read-only text view with each finding's span shaded in
/// its color. AppKit rather than SwiftUI's Text: bodies run to megabytes,
/// and NSTextView gives selection and ⌘F for free.
private struct HighlightedText: NSViewRepresentable {
    let id: Int
    let text: String
    let matches: [UploadMatch]

    final class Coordinator {
        var shownID: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.backgroundColor = .controlBackgroundColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shownID != id, let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.shownID = id
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        let length = attributed.length
        for match in matches where NSMaxRange(match.range) <= length {
            attributed.addAttributes([
                .backgroundColor: NSColor(match.kind.color).withAlphaComponent(0.22),
                .foregroundColor: NSColor.labelColor,
            ], range: match.range)
        }
        textView.textStorage?.setAttributedString(attributed)
        if let first = matches.first(where: { $0.kind.isGit }) ?? matches.first, NSMaxRange(first.range) <= length {
            textView.scrollRangeToVisible(first.range)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}
