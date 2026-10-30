import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var editNode = false
    @State private var editingProvider: ProviderInstance? = nil
    @State private var showAddProvider = false

    var body: some View {
        PanelShell(title: "设置", sub: "改动即时落盘；节点在线才谈得上执行") {

            SectionTitle(text: "模型")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    // 服务商实例列表（对齐 Minis 多 provider）
                    ForEach(st.providers.indices, id: \.self) { i in
                        providerRow(i)
                        if i < st.providers.count - 1 { RowDivider() }
                    }
                    RowDivider()
                    HStack {
                        Button {
                            addProvider()
                        } label: {
                            Label("新增服务商", systemImage: "plus.circle")
                                .font(.system(size: 13)).foregroundColor(T.accent)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("\(st.providers.count) 个 · 点左侧圆点切换")
                            .font(.system(size: 10.5)).foregroundColor(T.txt3)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    RowDivider()
                    HStack {
                        Text("流式").font(.system(size: 14.5)).foregroundColor(T.txt)
                        Spacer()
                        Toggle("", isOn: $st.streamOn).labelsHidden().tint(T.accent)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    RowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("温度").font(.system(size: 13.5)).foregroundColor(T.txt)
                            Spacer()
                            Text(String(format: "%.2f", st.temperature))
                                .font(T.mono(11)).foregroundColor(T.txt2)
                        }
                        Slider(value: $st.temperature, in: 0...1.5, step: 0.05)
                            .tint(T.accent)
                        HStack {
                            Text("max_tokens").font(.system(size: 13.5)).foregroundColor(T.txt)
                            Spacer()
                            Text("\(st.maxTokens)").font(T.mono(11)).foregroundColor(T.txt2)
                        }
                        Slider(value: Binding(
                            get: { Double(st.maxTokens) },
                            set: { st.maxTokens = Int($0) }
                        ), in: 512...32000, step: 512).tint(T.accent)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }

            SectionTitle(text: "算力节点")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ToggleRow(title: "启用节点桥",
                              sub: "终端 / 逆向 / 抓包都跑在这台节点上，iOS 端只发指令收结果",
                              on: $st.bridgeOn)
                    RowDivider()
                    Button {
                        editNode = true
                    } label: {
                        NavRow(color: hub.state.online ? T.green : T.txt3, glyph: "⇄",
                               title: "节点地址",
                               sub: st.bridgeURL,
                               value: hub.state.online ? "在线" : "离线")
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    HStack {
                        Text("Token").font(.system(size: 14.5)).foregroundColor(T.txt)
                        Spacer()
                        TextField("可选", text: $st.bridgeToken)
                            .font(T.mono(11.5))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 170)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    RowDivider()
                    Button {
                        hub.refresh(st)
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(hub.state.online ? "重新探活" : "探活")
                            Spacer()
                            if !hub.state.r2Version.isEmpty {
                                Text(hub.state.r2Version).font(T.mono(10)).foregroundColor(T.txt3)
                            }
                        }
                        .font(.system(size: 13.5))
                        .foregroundColor(T.accent)
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("节点就是 PC 上那个 npclab 服务（server.py）。手机与 PC 同一局域网，填 PC 的 IP:8790。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)

            SectionTitle(text: "权限")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink {
                        PermPanel()
                    } label: {
                        NavRow(color: T.red, glyph: "锁", title: "权限",
                               sub: "文件、终端、抓包的实际授权状态")
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    ToggleRow(title: "Face ID 保护",
                              sub: "启动时校验，防止别人拿手机直接看会话",
                              on: $st.faceIDLock)
                }
            }

            SectionTitle(text: "开发者")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { LocalFilesView() } label: {
                        NavRow(color: T.orange, glyph: "文", title: "本机文件",
                               sub: "浏览 / 编辑 App 沙盒里的文件，「文件」App 里同步可见")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { HostPanel() } label: {
                        NavRow(color: T.purple, glyph: "盘", title: "宿主访问",
                               sub: "授权手机本机文件给 AI 读写；PC 节点的授权根在下一层")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { TermPanel() } label: {
                        NavRow(color: Color(white: 0.55), glyph: "$", title: "终端",
                               sub: "选命令以什么身份、在哪个 shell 里执行")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { GitHubPanel() } label: {
                        NavRow(color: Color(white: 0.3), glyph: "</>", title: "GitHub 连接",
                               sub: "让 AI 直接操作仓库与代码")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { CtxPanel() } label: {
                        NavRow(color: T.accent, glyph: "◱", title: "上下文窗口",
                               sub: "对话可用的上下文上限，超阈值自动压缩")
                    }.buttonStyle(.plain)
                    RowDivider()
                    ToggleRow(title: "对话内工具",
                              sub: "让模型自己调节点：跑命令、反编译、加抓包规则",
                              on: $st.toolLoop)
                }
            }

            SectionTitle(text: "逆向工具")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { RevPanel() } label: {
                        NavRow(color: T.purple, glyph: "◎", title: "逆向分析",
                               sub: "本机 radare2 + binutils + capstone + PC 节点，pdg / pdc / pdf 自动降级")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { ProxyPanel() } label: {
                        NavRow(color: T.green, glyph: "⇄", title: "抓包与改写",
                               sub: "本机真 MITM（URLProtocol 解密 + 改写）+ 节点 MITM 两套")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { InjectPanel() } label: {
                        NavRow(color: T.teal, glyph: "⚡", title: "动态注入",
                               sub: "目标 App 注入 + Frida hook 六类 + 注入日志")
                    }.buttonStyle(.plain)
                }
            }
            Text("逆向/抓包/注入都对齐 AzTuT：逆向用本机 r2+binutils+capstone，抓包用内置 URLProtocol 真 MITM 解密，注入用 frida hook 目标 App。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)

            SectionTitle(text: "日志")
            Card(padding: 0) {
                NavigationLink { LogsPanel() } label: {
                    NavRow(color: Color(white: 0.4), glyph: "▤", title: "日志",
                           sub: "\(st.logs.count) 条 · 终端、抓包、逆向与守卫事件")
                }.buttonStyle(.plain)
            }

            SectionTitle(text: "关于")
            Card {
                HStack {
                    Text("小徐TuT iOS").font(.system(size: 14, weight: .semibold)).foregroundColor(T.txt)
                    Spacer()
                    Text("v1.0").font(T.mono(11)).foregroundColor(T.txt3)
                }
                Text("独立客户端：注入、人设、技能库、文档全部本地；执行能力接节点。")
                    .font(.system(size: 11.5)).foregroundColor(T.txt2)
                Divider().overlay(T.line)
                statLine("技能", "\(PackData.shared.skills.count) 条索引 / \(PackData.shared.bodyCount) 篇正文")
                statLine("工具链", "\(PackData.shared.tools.count) 项")
                statLine("思维模板", "\(PackData.shared.presets.count) 条")
                statLine("注入体积", humanBytes(PromptBuilder.assemble(st, bridge: hub.state).bytes))
            }

            Button(role: .destructive) {
                st.resetChat()
            } label: {
                HStack {
                    Spacer()
                    Text("清空会话记录").font(.system(size: 13.5))
                    Spacer()
                }
                .padding(.vertical, 12)
                .glass(12)
            }
            .buttonStyle(.plain)
            .foregroundColor(T.red)
        }
        .sheet(item: $editingProvider) { p in
            ProviderEditor(provider: p) { updated in
                if let idx = st.providers.firstIndex(where: { $0.id == updated.id }) {
                    st.providers[idx] = updated
                    // 保存后自动拉一次模型列表：填了中转站和 key 但还没列表时
                    autoFetchModels(at: idx)
                }
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderView()
        }
        .sheet(isPresented: $editNode) {
            PromptSheet(title: "节点地址",
                        hint: "PC 的局域网 IP + 端口，例如 http://192.168.1.7:8790",
                        placeholder: "http://192.168.1.7:8790", initial: st.bridgeURL) { st.bridgeURL = $0 }
        }
        .onAppear { if st.bridgeOn { hub.refresh(st) } }
    }

    private func mask(_ s: String) -> String {
        guard s.count > 8 else { return "••••" }
        return String(s.prefix(4)) + "••••" + String(s.suffix(4))
    }

    /// 单个服务商实例行：圆点选启用 / 点整行编辑 / 右滑删除
    @ViewBuilder
    private func providerRow(_ i: Int) -> some View {
        let p = st.providers[i]
        let active = st.activeProviderId == p.id
        HStack(spacing: 10) {
            Button {
                st.activeProviderId = p.id
            } label: {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(active ? T.accent : T.txt3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name.isEmpty ? p.providerLabel : p.name)
                        .font(.system(size: 14.5)).foregroundColor(T.txt)
                        .lineLimit(1)
                    Pill(text: p.providerLabel, color: active ? T.accent : T.txt3)
                    if active {
                        Pill(text: "使用中", color: T.green)
                    }
                }
                Text(p.model + " · " + (p.apiKey.isEmpty ? "未填 Key" : "已填 Key"))
                    .font(.system(size: 11)).foregroundColor(T.txt3)
                    .lineLimit(1)
            }
            Spacer()

            if st.providers.count > 1 {
                Button {
                    removeProvider(p)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                        .foregroundColor(T.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            editingProvider = p
        }
    }

    private func addProvider() {
        showAddProvider = true
    }

    private func removeProvider(_ p: ProviderInstance) {
        st.providers.removeAll { $0.id == p.id }
        if st.activeProviderId == p.id {
            st.activeProviderId = st.providers.first?.id
        }
    }

    /// 保存服务商后后台拉一次 /models，拉回来就把模型变成下拉可选。
    /// 拉不到就静默跳过 —— 用户还能回编辑器手填模型 ID。
    private func autoFetchModels(at idx: Int) {
        guard st.providers.indices.contains(idx) else { return }
        st.autoFetchModels(for: st.providers[idx].id)
    }

    private func statLine(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundColor(T.txt2)
            Spacer()
            Text(v).font(T.mono(11)).foregroundColor(T.txt3)
        }
    }
}

// MARK: - 服务商配置表单（对齐 Minis 的「配置 X」页）

/// 服务商配置表单主体。字段顺序与文案严格对齐 Minis：
///   标签 / API KEY（眼睛 + 钥匙串说明）/ 自定义 API 地址（可选）+ 自动附加 "/v1"
///   / API 格式（仅 OpenAI）/（可选）模型分区 + 启用开关 /（可选）底部添加按钮。
/// 新建（AddProviderView）与编辑（ProviderEditor）共用：
///   - 新建：showModels=false、showStatus=false、onAdd=提交
///   - 编辑：showModels=true、showStatus=true、onAdd=nil（用工具栏保存）
struct ProviderFormFields: View {
    @Binding var p: ProviderInstance
    var isVoice: Bool = false
    var showModels: Bool = false
    var showStatus: Bool = false
    var showsAddButton: Bool = false
    var onAdd: () -> Void = {}

    @State private var showKey = false
    @State private var fetching = false
    @State private var fetchMsg: String?
    @State private var showAddModel = false
    @State private var addModelText = ""

    var body: some View {
        Form {
            // 1. 标签
            Section("标签") {
                TextField("标签", text: $p.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }

            // 2. API KEY
            Section {
                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField(keyPlaceholder, text: $p.apiKey)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField(keyPlaceholder, text: $p.apiKey)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("API KEY")
            } footer: {
                Text("您的密钥安全存储在 iOS 钥匙串中，不会离开设备。")
            }

            // 3. 自定义 API 地址（可选）+ 自动附加 /v1
            Section {
                TextField(basePlaceholder, text: $p.baseURL)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if !isVoice, p.providerType != "gemini" {
                    Toggle("自动附加 \"/v1\"", isOn: $p.appendV1Suffix)
                }
            } header: {
                Text("自定义 API 地址（可选）")
            } footer: {
                Text(isVoice
                     ? "语音服务端点地址。"
                     : (p.appendV1Suffix
                        ? "留空则使用默认端点。\"/v1\" 会自动附加 — 只需输入基础主机地址。"
                        : "该 URL 原样使用。请填完整路径（不含 /chat/completions 等端点）。"))
            }

            // 4. API 格式（仅 OpenAI）
            if p.providerType == "openai" && !isVoice {
                Section {
                    Picker("API 格式", selection: $p.apiFormat) {
                        Text("Chat Completions").tag("chat")
                        Text("Responses API").tag("responses")
                    }
                } footer: {
                    Text(p.apiFormat == "responses"
                         ? "使用 /v1/responses 端点格式。"
                         : "标准 /v1/chat/completions 格式。兼容大多数 OpenAI 兼容服务。")
                }
            }

            // 5. 模型分区（编辑详情页）
            if showModels {
                modelSection
            }

            // 6. 启用开关（编辑详情页）
            if showStatus {
                Section("状态") {
                    Toggle("启用", isOn: $p.isEnabled)
                }
            }

            // 7. 底部「添加 AI 服务商」按钮（新建流程）
            if showsAddButton {
                Section {
                    Button {
                        onAdd()
                    } label: {
                        HStack {
                            Spacer()
                            Text("添加 AI 服务商").font(.body.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .alert("手动添加模型", isPresented: $showAddModel) {
            TextField("模型 ID", text: $addModelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") {
                let t = addModelText.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    if !p.models.contains(t) { p.models.append(t) }
                    p.model = t
                }
                addModelText = ""
            }
            Button("取消", role: .cancel) { addModelText = "" }
        }
    }

    // MARK: 模型分区（对齐 Minis 的 Models + Refresh）

    private var modelSection: some View {
        Section {
            if p.models.isEmpty {
                Text("暂无模型，点右上角刷新从 /models 拉取")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ForEach(p.models, id: \.self) { m in
                    Button {
                        p.model = m
                    } label: {
                        HStack {
                            Text(m)
                                .font(.system(size: 13.5)).foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            if p.model == m {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Button {
                showAddModel = true
            } label: {
                Label("手动添加模型", systemImage: "plus.circle")
                    .font(.system(size: 13)).foregroundColor(.accentColor)
            }
        } header: {
            HStack {
                Text("模型")
                Spacer()
                Button {
                    refreshModels()
                } label: {
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("刷新")
                        }
                        .font(.caption)
                    }
                }
                .disabled(fetching)
            }
        } footer: {
            if let m = fetchMsg {
                Text(m)
                    .font(.system(size: 11))
                    .foregroundColor(m.hasPrefix("已获取") ? .secondary : .red)
            }
        }
    }

    // MARK: 占位符 + 校验

    private var keyPlaceholder: String {
        switch p.providerType {
        case "anthropic": return "sk-ant-..."
        case "openRouter": return "sk-or-..."
        case "xAI": return "xai-..."
        case "gemini": return "Gemini API Key..."
        case "kimiCode", "githubCopilot": return ""
        default: return "sk-..."
        }
    }

    private var basePlaceholder: String {
        ProviderInstance.defaultBaseURL(p.providerType)
    }

    /// 能否提交：填了 key 就能加；OpenAI/Anthropic 兼容第三方端点填了自定义地址可空 key。
    private var canAdd: Bool {
        if !p.apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let base = p.baseURL.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty && (p.providerType == "openai" || p.providerType == "anthropic") {
            return true
        }
        return false
    }

    private func refreshModels() {
        let key = p.apiKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty {
            fetchMsg = "先填 API Key"
            return
        }
        let snapshot = p
        fetching = true
        fetchMsg = nil
        Task { @MainActor in
            do {
                let list = try await ModelCatalog.fetch(snapshot)
                if list.isEmpty {
                    fetchMsg = "接口没返回模型列表，检查地址和 Key"
                } else {
                    p.models = list
                    if !list.contains(p.model) { p.model = list[0] }
                    fetchMsg = "已获取 \(list.count) 个模型"
                }
            } catch {
                fetchMsg = error.localizedDescription
            }
            fetching = false
        }
    }
}

// MARK: - 编辑已有服务商（对齐 Minis 详情页）

/// 编辑一个已存在的服务商实例（点列表行进入）。
/// 展示 Models 分区 + 启用开关，可用工具栏保存。
struct ProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var p: ProviderInstance
    let onSave: (ProviderInstance) -> Void

    init(provider: ProviderInstance, onSave: @escaping (ProviderInstance) -> Void) {
        _p = State(initialValue: provider)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            ProviderFormFields(p: $p, showModels: true, showStatus: true)
                .navigationTitle(p.name.isEmpty ? "服务商" : p.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onSave(p)
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - 添加 AI 服务商（分步向导，对齐 Minis）

/// 点「新增服务商」进入：先选服务商类型（列表 + 副标题引导），再进配置表单。
/// 对齐 Minis 的 AddProviderView —— 类型是带图标和说明的列表，不是下拉。
struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var st: AppSettings

    @State private var started = false
    @State private var draft = ProviderInstance()
    @State private var isVoice = false

    var body: some View {
        NavigationView {
            Group {
                if started {
                    ProviderFormFields(p: $draft, isVoice: isVoice, showsAddButton: true) {
                        commit()
                    }
                } else {
                    typeList
                }
            }
            .navigationTitle(started ? "配置 \(isVoice ? draft.name : draft.providerLabel)" : "添加 AI 服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(started ? "返回" : "取消") {
                        if started {
                            started = false
                            isVoice = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if started {
                        Button {
                            requestExit()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        }
    }

    private func requestExit() {
        dismiss()
    }

    // MARK: 类型列表（第一步）

    private var typeList: some View {
        Form {
            Section {
                ForEach(Self.aiTypes, id: \.type) { item in
                    Button {
                        pick(type: item.type)
                    } label: {
                        typeRow(item)
                    }
                }
            } header: {
                Text("选择 AI 服务商")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("您可以添加同一 AI 服务商的多个实例（例如工作和个人账户）。")
                    Text("OpenAI 和 Anthropic 也支持兼容的第三方端点 —— 选择匹配的协议后设置自定义 API 地址。")
                }
            }

            Section {
                ForEach(Self.voiceTypes, id: \.name) { v in
                    Button {
                        pickVoice(v)
                    } label: {
                        voiceRow(v)
                    }
                }
            } header: {
                Text("语音对话服务商")
            } footer: {
                Text("语音合成与识别服务商。类型和中转站已预填，只需填 API Key；语音实例默认不启用，等语音功能接入后打开。")
            }
        }
    }

    private func typeRow(_ item: ProviderTypeMeta) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.body)
                .foregroundColor(item.color)
                .frame(width: 32, height: 32)
                .background(item.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundColor(Color.primary)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func voiceRow(_ v: VoiceTypeMeta) -> some View {
        HStack(spacing: 12) {
            Image(systemName: v.symbol)
                .font(.body)
                .foregroundColor(v.tint)
                .frame(width: 32, height: 32)
                .background(v.tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(v.name)
                    .font(.body.weight(.medium))
                    .foregroundColor(Color.primary)
                Text(v.capability)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: 选中类型 → 预填 draft，进配置

    private func pick(type: String) {
        var p = ProviderInstance()
        p.providerType = type
        p.baseURL = ProviderInstance.defaultBaseURL(type)
        p.model = ProviderInstance.defaultModel(type)
        let base = p.providerLabel
        let count = st.providers.filter { $0.providerType == type }.count
        p.name = count == 0 ? base : "\(base) \(count + 1)"
        draft = p
        isVoice = false
        started = true
    }

    private func pickVoice(_ v: VoiceTypeMeta) {
        var p = ProviderInstance()
        p.providerType = "openai"
        p.baseURL = v.baseURL
        p.model = ""
        p.name = v.name
        p.appendV1Suffix = false
        p.isEnabled = false
        draft = p
        isVoice = true
        started = true
    }

    private func commit() {
        st.providers.append(draft)
        if st.activeProviderId == nil {
            st.activeProviderId = draft.id
        }
        st.log("模型", "添加服务商 \(draft.name.isEmpty ? draft.providerLabel : draft.name)")
        st.autoFetchModels(for: draft.id)
        dismiss()
    }

    // MARK: 类型元数据

    struct ProviderTypeMeta {
        let type: String
        let title: String
        let subtitle: String
        let symbol: String
        let color: Color
    }

    struct VoiceTypeMeta {
        let name: String
        let capability: String
        let symbol: String
        let tint: Color
        let baseURL: String
    }

    static let aiTypes: [ProviderTypeMeta] = [
        .init(type: "openai", title: "OpenAI / 兼容 API",
              subtitle: "支持 Codex、DeepSeek、Moonshot、Groq 等兼容厂商",
              symbol: "circle.hexagongrid", color: .green),
        .init(type: "anthropic", title: "Anthropic / 兼容 API",
              subtitle: "支持 Claude 及兼容 Anthropic 协议的服务商",
              symbol: "sparkles", color: .purple),
        .init(type: "gemini", title: "Google Gemini",
              subtitle: "支持 Gemini 系列及 Google AI Studio",
              symbol: "diamond", color: .blue),
        .init(type: "openRouter", title: "OpenRouter",
              subtitle: "聚合 GPT、Claude、Gemini、Llama 等主流模型",
              symbol: "arrow.triangle.branch", color: .cyan),
        .init(type: "xAI", title: "xAI (Grok)",
              subtitle: "支持 Grok 系列模型",
              symbol: "xmark.circle", color: .gray),
        .init(type: "kimiCode", title: "Kimi Code",
              subtitle: "使用你的 Kimi Code / Coding Plan 订阅登录",
              symbol: "moon.stars", color: .indigo),
        .init(type: "githubCopilot", title: "GitHub Copilot",
              subtitle: "使用 GitHub 登录 —— 非官方方式，风险自负",
              symbol: "chevron.left.forwardslash.chevron.right", color: .primary),
    ]

    static let voiceTypes: [VoiceTypeMeta] = [
        .init(name: "ElevenLabs", capability: "语音合成（TTS）",
              symbol: "waveform", tint: .purple, baseURL: "https://api.elevenlabs.io"),
        .init(name: "Deepgram", capability: "识别 + 合成",
              symbol: "mic.fill", tint: .blue, baseURL: "https://api.deepgram.com"),
        .init(name: "Azure TTS", capability: "语音合成（TTS）",
              symbol: "speaker.wave.2", tint: .cyan, baseURL: "https://<region>.tts.speech.microsoft.com"),
        .init(name: "MiniMax", capability: "语音合成（TTS）",
              symbol: "speaker.wave.3", tint: .orange, baseURL: "https://api.minimax.chat"),
    ]
}
