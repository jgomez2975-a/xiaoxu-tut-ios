import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var editNode = false
    @State private var editingProvider: ProviderInstance? = nil

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
                }
            }
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
        var p = ProviderInstance()
        p.name = "新服务商 \(st.providers.count + 1)"
        st.providers.append(p)
        editingProvider = p
    }

    private func removeProvider(_ p: ProviderInstance) {
        st.providers.removeAll { $0.id == p.id }
        if st.activeProviderId == p.id {
            st.activeProviderId = st.providers.first?.id
        }
    }

    private func statLine(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundColor(T.txt2)
            Spacer()
            Text(v).font(T.mono(11)).foregroundColor(T.txt3)
        }
    }
}

// MARK: - 服务商编辑器

/// 编辑/新建一个服务商实例：服务商类型、名称、baseURL、Key、模型、启用。
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
            Form {
                Section("服务商") {
                    Picker("类型", selection: $p.providerType) {
                        ForEach(ProviderInstance.providerTypes, id: \.self) { t in
                            Text(ProviderInstance(id: UUID(), providerType: t).providerLabel).tag(t)
                        }
                    }
                    .onChange(of: p.providerType) { t in
                        // 切类型时，若 baseURL/模型还停在上一家的默认值，换成新家的默认
                        if p.baseURL == "https://api.openai.com/v1" ||
                           p.baseURL == "https://api.anthropic.com/v1" ||
                           p.baseURL == "https://openrouter.ai/api/v1" ||
                           p.baseURL == "https://api.x.ai/v1" ||
                           p.baseURL == "https://generativelanguage.googleapis.com/v1beta" ||
                           p.baseURL == "https://api.kimi.com/coding/v1" {
                            p.baseURL = ProviderInstance.defaultBaseURL(t)
                        }
                        if p.model == "gpt-4o" || p.model == "claude-sonnet-4-5" ||
                           p.model == "openai/gpt-4o" || p.model == "grok-3" ||
                           p.model == "gemini-2.5-pro" || p.model == "kimi-k2" {
                            p.model = ProviderInstance.defaultModel(t)
                        }
                    }
                    TextField("名称（唯一标识）", text: $p.name)
                        .autocorrectionDisabled()
                }
                Section("连接") {
                    TextField("接口地址", text: $p.baseURL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("API Key", text: $p.apiKey)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("模型", text: $p.model)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section {
                    Toggle("启用此服务商", isOn: $p.isEnabled)
                }
                Section {
                    Text(p.isAnthropic
                         ? "Anthropic 走 Messages API（x-api-key + anthropic-version）。"
                         : "OpenAI 兼容，走 /chat/completions（Bearer Token）。其余服务商（OpenRouter/xAI/Gemini/Kimi）都兼容此协议，改 baseURL 即可。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .navigationTitle(p.name.isEmpty ? "服务商" : p.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // 切服务商类型时，若 baseURL/模型还是上一家的默认值，自动换成新家的默认
                        onSave(p)
                        dismiss()
                    }
                }
            }
        }
    }
}
