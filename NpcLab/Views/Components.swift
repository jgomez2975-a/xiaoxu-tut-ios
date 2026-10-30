import SwiftUI
import UIKit

// MARK: - 基础组件

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(T.txt3)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    var content: Content

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
    }
}

/// 设置项一行：图标 + 标题 + 副标题 + 右侧箭头（纯展示，点击由外层包装）
struct NavRow: View {
    var color: Color = T.accent
    var glyph: String = "•"
    /// 给了 symbol 就画 SF Symbol，否则画 glyph 文字（老调用处不用改）
    var symbol: String = ""
    var title: String
    var sub: String = ""
    var value: String = ""

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.9))
                if symbol.isEmpty {
                    Text(glyph).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
            }
            .frame(width: 27, height: 27)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5)).foregroundColor(T.txt)
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 6)
            if !value.isEmpty {
                Text(value).font(T.mono(11.5)).foregroundColor(T.txt2).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(T.txt3)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 圆形图标 + 标题 + 副标题 + 右侧开关。
/// 对齐 AzTuT「深度分析 / 辅助工具」那种行：图标是圆形色块，跟上面的导航行
/// （圆角方块）在视觉上区分开。
struct IconToggleRow: View {
    var color: Color
    var glyph: String = ""
    var symbol: String = ""
    var title: String
    var sub: String = ""
    @Binding var on: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(color.opacity(0.9))
                if symbol.isEmpty {
                    Text(glyph).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                }
            }
            .frame(width: 27, height: 27)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5)).foregroundColor(T.txt)
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $on).labelsHidden().tint(T.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// 区块下方的灰色说明文字（AzTuT 每个区块下面都有一段）
struct SectionFootnote: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(T.txt3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, -6)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(T.line).frame(height: 0.6).padding(.leading, 50)
    }
}

/// 开关行
struct ToggleRow: View {
    var title: String
    var sub: String = ""
    @Binding var on: Bool
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5)).foregroundColor(T.txt)
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $on).labelsHidden().tint(T.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct Pill: View {
    var text: String
    var color: Color = T.accent
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// 代码块：等宽 + 复制
struct CodeBox: View {
    var code: String
    var lang: String = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang)
                    .font(T.mono(10)).foregroundColor(T.txt3)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(copied ? T.green : T.txt3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(T.mono(11.5))
                    .foregroundColor(Color(red: 0.80, green: 0.88, blue: 0.95))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line, lineWidth: 1))
    }
}

/// 简易 Markdown 渲染：标题 / 列表 / 代码围栏 / 引用 / 粗体
struct MDText: View {
    var raw: String
    var size: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in
                blockView(blocks[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ b: Block) -> some View {
        switch b {
        case .text(let t):
            Text(inline(t))
                .font(.system(size: size))
                .foregroundColor(T.txt)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let c, let lang):
            CodeBox(code: c, lang: lang)
        case .head(let t, let lv):
            Text(inline(t))
                .font(.system(size: lv <= 1 ? size + 3 : (lv == 2 ? size + 1.5 : size + 0.5),
                              weight: .semibold))
                .foregroundColor(T.txt)
                .padding(.top, 2)
        case .bullet(let t):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.system(size: size)).foregroundColor(T.accent)
                Text(inline(t)).font(.system(size: size)).foregroundColor(T.txt)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let t):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(T.accent.opacity(0.6)).frame(width: 2)
                Text(inline(t)).font(.system(size: size - 0.5)).foregroundColor(T.txt2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum Block {
        case text(String)
        case code(String, String)
        case head(String, Int)
        case bullet(String)
        case quote(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var buf: [String] = []
        var code: [String] = []
        var inCode = false
        var lang = ""

        func flush() {
            let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
            buf.removeAll()
        }

        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("```") {
                if inCode {
                    out.append(.code(code.joined(separator: "\n"), lang))
                    code.removeAll(); lang = ""; inCode = false
                } else {
                    flush()
                    lang = String(trim.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }
            if trim.isEmpty { flush(); continue }
            if trim.hasPrefix("#") {
                flush()
                let lv = trim.prefix { $0 == "#" }.count
                out.append(.head(String(trim.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces), lv))
                continue
            }
            if trim.hasPrefix("- ") || trim.hasPrefix("* ") || trim.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(trim.dropFirst(2))))
                continue
            }
            if trim.hasPrefix("> ") {
                flush()
                out.append(.quote(String(trim.dropFirst(2))))
                continue
            }
            buf.append(line)
        }
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"), lang)) }
        flush()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString(s)
    }
}

/// 空状态
struct EmptyHint: View {
    var icon: String = "tray"
    var title: String
    var sub: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundColor(T.txt3)
            Text(title).font(.system(size: 13.5)).foregroundColor(T.txt2)
            if !sub.isEmpty {
                Text(sub).font(.system(size: 11.5)).foregroundColor(T.txt3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

/// 统一的页面外壳
struct PanelShell<Content: View>: View {
    var title: String
    var sub: String = ""
    var content: Content

    init(title: String, sub: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.sub = sub
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 11.5)).foregroundColor(T.txt3)
                }
                content
            }
            .padding(14)
            .padding(.bottom, 24)
        }
        .background(Backdrop())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 简易搜索框
struct SearchBar: View {
    @Binding var text: String
    var placeholder: String = "搜索"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(T.txt3)
            TextField(placeholder, text: $text)
                .font(.system(size: 13.5))
                .foregroundColor(T.txt)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundColor(T.txt3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glass(10)
    }
}

/// 自定义输入弹窗（避免依赖 Alert 的文本输入）
struct PromptSheet: View {
    var title: String
    var hint: String = ""
    var placeholder: String = ""
    var initial: String = ""
    var onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 11.5)).foregroundColor(T.txt3)
                }
                TextField(placeholder, text: $text)
                    .font(T.mono(13))
                    .foregroundColor(T.txt)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .glass(10)
                Spacer()
            }
            .padding(16)
            .background(Backdrop())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onDone(text)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { text = initial }
    }
}
