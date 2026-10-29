import SwiftUI

struct ThoughtView: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var editPersona = false
    @State private var editTail = false
    @State private var presetDetail: Preset?

    private var parts: PromptBuilder.Parts {
        PromptBuilder.assemble(st, bridge: hub.state)
    }

    var body: some View {
        PanelShell(title: "思维 / 人设", sub: "注入的每一层都能在这里改；改完立刻生效，不用重启") {
            Card {
                HStack {
                    Text("SYSTEM 合计").font(.system(size: 12)).foregroundColor(T.txt2)
                    Spacer()
                    Text("\(humanBytes(parts.bytes)) · ≈\(parts.bytes / 1700)k token")
                        .font(T.mono(11.5)).foregroundColor(T.accent)
                }
                HStack(spacing: 6) {
                    Pill(text: "人设 \(humanBytes(parts.soul.utf8.count))")
                    Pill(text: "技能 \(humanBytes(parts.skills.utf8.count))", color: T.purple)
                    Pill(text: "工具 \(humanBytes(parts.tools.utf8.count))", color: T.teal)
                    Pill(text: "运行时 \(humanBytes(parts.runtime.utf8.count))", color: T.orange)
                }
            }

            SectionTitle(text: "人设 · SOUL.md")
            Card {
                let f = Soul.parse(st.persona)
                let w = Soul.weight(f.body)
                HStack(spacing: 10) {
                    Text(f.meta.emoji.isEmpty ? "🧪" : f.meta.emoji)
                        .font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.meta.name.isEmpty ? "Npc" : f.meta.name)
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(T.txt)
                        Text("lang \(f.meta.lang) · 中文 \(w.cn)/\(Soul.limitCN) 字 · 英文 \(w.en)/\(Soul.limitEN) 词")
                            .font(T.mono(10))
                            .foregroundColor(w.over ? T.red : T.txt3)
                    }
                    Spacer()
                }
                Text(f.meta.style.isEmpty ? "（style 为空）" : f.meta.style)
                    .font(.system(size: 11.5)).foregroundColor(T.txt2)
                if w.over {
                    Text("已超上限 —— 注入时只会保留身份句，人设不生效。")
                        .font(.system(size: 11)).foregroundColor(T.red)
                }
                HStack(spacing: 8) {
                    Button {
                        editPersona = true
                    } label: {
                        Label("编辑", systemImage: "square.and.pencil")
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(T.accent.opacity(0.16))
                            .foregroundColor(T.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        st.persona = AppSettings.defaultPersona()
                    } label: {
                        Label("恢复内置", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(T.card)
                            .foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }

            SectionTitle(text: "思维模板 · ops-notes")
            Card {
                HStack {
                    Text("启用").font(.system(size: 14)).foregroundColor(T.txt)
                    Spacer()
                    Toggle("", isOn: $st.injectOn).labelsHidden().tint(T.accent)
                }
                ForEach(PackData.shared.presets) { p in
                    Button {
                        presetDetail = p
                    } label: {
                        HStack(spacing: 9) {
                            ZStack {
                                Circle()
                                    .stroke(st.presetId == p.id ? T.accent : T.line,
                                            lineWidth: st.presetId == p.id ? 6 : 1)
                            }
                            .frame(width: 15, height: 15)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(p.name).font(.system(size: 13.5)).foregroundColor(T.txt)
                                    if !p.tag.isEmpty { Pill(text: p.tag, color: T.accent) }
                                    Pill(text: p.code, color: T.txt3)
                                }
                                Text(p.desc).font(.system(size: 11)).foregroundColor(T.txt3)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Text(humanBytes(p.bytes)).font(T.mono(9.5)).foregroundColor(T.txt3)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SectionTitle(text: "拼装顺序")
            Card {
                ForEach(["append", "prepend", "replace"], id: \.self) { m in
                    Button {
                        st.injectMode = m
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: st.injectMode == m ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(st.injectMode == m ? T.accent : T.txt3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(modeTitle(m)).font(.system(size: 13.5)).foregroundColor(T.txt)
                                Text(modeOrder(m)).font(T.mono(9.5)).foregroundColor(T.txt3)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SectionTitle(text: "技能 / 工具注入")
            Card {
                Picker("技能", selection: $st.skillMode) {
                    Text("索引 20 条").tag("index")
                    Text("全文").tag("full")
                    Text("关闭").tag("off")
                }
                .pickerStyle(.segmented)
                Text("索引只发 name / description / path，正文按需读；全文把置顶技能的 SKILL.md 整段塞进 system。")
                    .font(.system(size: 10.5)).foregroundColor(T.txt3)

                Divider().overlay(T.line)

                Picker("工具链", selection: $st.toolMode) {
                    Text("随包").tag("bundled")
                    Text("全量").tag("full")
                    Text("关闭").tag("off")
                }
                .pickerStyle(.segmented)

                if st.skillMode == "full" && st.pinned.isEmpty {
                    Text("全文模式需要至少置顶一条技能（技能库 → 长按 → 置顶）。")
                        .font(.system(size: 10.5)).foregroundColor(T.orange)
                }
            }

            SectionTitle(text: "回复前缀 / 尾注")
            Card {
                HStack {
                    Text("前缀").font(.system(size: 14)).foregroundColor(T.txt)
                    Spacer()
                    TextField("留空即不用", text: $st.prefix)
                        .font(T.mono(12))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 160)
                }
                if !st.prefix.isEmpty {
                    Text("模型每条回复必须以「\(st.prefix)」开头。")
                        .font(.system(size: 10.5)).foregroundColor(T.txt3)
                }
                Divider().overlay(T.line)
                HStack {
                    Text("尾注").font(.system(size: 14)).foregroundColor(T.txt)
                    Spacer()
                    Text(humanBytes(st.tailText.utf8.count))
                        .font(T.mono(10.5)).foregroundColor(T.txt3)
                    Toggle("", isOn: $st.tailOn).labelsHidden().tint(T.accent)
                }
                Button {
                    editTail = true
                } label: {
                    Text("编辑尾注").font(.system(size: 12.5)).foregroundColor(T.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $editPersona) {
            TextEditorSheet(title: "SOUL.md", text: st.persona, mono: true) { t in
                st.persona = t
            }
        }
        .sheet(isPresented: $editTail) {
            TextEditorSheet(title: "尾注", text: st.tailText) { t in
                st.tailText = t
            }
        }
        .sheet(item: $presetDetail) { p in
            PresetDetail(preset: p, selected: st.presetId == p.id) {
                st.presetId = p.id
                presetDetail = nil
            }
        }
    }

    private func modeTitle(_ m: String) -> String {
        switch m {
        case "prepend": return "模板前置"
        case "replace": return "只留模板"
        default: return "模板后置（默认）"
        }
    }

    private func modeOrder(_ m: String) -> String {
        switch m {
        case "prepend": return "ops-notes → 人设 → 技能 → 工具 → 运行时"
        case "replace": return "技能 → 工具 → 运行时 → ops-notes"
        default: return "人设 → 技能 → 工具 → 运行时 → ops-notes"
        }
    }
}

// MARK: - 模板详情

struct PresetDetail: View {
    var preset: Preset
    var selected: Bool
    var onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        Text(preset.name).font(.system(size: 17, weight: .semibold))
                            .foregroundColor(T.txt)
                        Text(preset.desc).font(.system(size: 12)).foregroundColor(T.txt2)
                        HStack(spacing: 6) {
                            Pill(text: preset.code)
                            if !preset.tag.isEmpty { Pill(text: preset.tag, color: T.purple) }
                            Pill(text: humanBytes(preset.bytes), color: T.txt3)
                        }
                    }
                    Card {
                        Text(preset.body).font(T.mono(11))
                            .foregroundColor(T.txt2).textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("思维模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected ? "已选用" : "用这个") { onUse() }
                        .disabled(selected)
                }
            }
        }
    }
}

// MARK: - 全屏文本编辑

struct TextEditorSheet: View {
    var title: String
    @State var text: String
    var mono: Bool = false
    var onSave: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(title: String, text: String, mono: Bool = false, onSave: ((String) -> Void)? = nil) {
        self.title = title
        _text = State(initialValue: text)
        self.mono = mono
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(mono ? T.mono(11.5) : .system(size: 13.5))
                    .foregroundColor(T.txt)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.25))
                    .padding(10)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .background(Backdrop())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave?(text)
                        dismiss()
                    }
                }
            }
        }
    }
}
