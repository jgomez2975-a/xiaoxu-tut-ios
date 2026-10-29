import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var editKey = false
    @State private var editBase = false
    @State private var editModel = false
    @State private var editNode = false

    var body: some View {
        PanelShell(title: "设置", sub: "改动即时落盘；节点在线才谈得上执行") {

            SectionTitle(text: "模型")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务商").font(.system(size: 14.5)).foregroundColor(T.txt)
                            Text(st.provider == "anthropic" ? "Anthropic Messages API" : "OpenAI 兼容 /chat/completions")
                                .font(.system(size: 11)).foregroundColor(T.txt3)
                        }
                        Spacer()
                        Picker("", selection: $st.provider) {
                            Text("OpenAI").tag("openai")
                            Text("Anthropic").tag("anthropic")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    RowDivider()
                    Button {
                        editBase = true
                    } label: {
                        NavRow(color: T.accent, glyph: "⌁", title: "接口地址",
                               sub: st.baseURL)
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    Button {
                        editKey = true
                    } label: {
                        NavRow(color: T.orange, glyph: "⚿", title: "API Key",
                               sub: st.apiKey.isEmpty ? "未填" : mask(st.apiKey))
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    Button {
                        editModel = true
                    } label: {
                        NavRow(color: T.purple, glyph: "◈", title: "模型",
                           sub: st.model)
                    }
                    .buttonStyle(.plain)
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
                    NavigationLink { HostPanel() } label: {
                        NavRow(color: T.purple, glyph: "盘", title: "宿主访问",
                               sub: "让 AI 读取节点上的文件（授权根之外一律拒绝）")
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
                               sub: "目标管理 + radare2 出函数级 C 伪代码（pdg / pdd / pdc）")
                    }.buttonStyle(.plain)
                    RowDivider()
                    NavigationLink { ProxyPanel() } label: {
                        NavRow(color: T.green, glyph: "⇄", title: "抓包与改写",
                               sub: "HTTP/HTTPS 中间人，查看流量并改写请求 / 响应")
                    }.buttonStyle(.plain)
                }
            }
            Text("目标管理、伪代码、抓包都在节点上执行；此页只做控制面。")
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
        .sheet(isPresented: $editKey) {
            PromptSheet(title: "API Key", hint: "只存在本机 UserDefaults，不上传任何第三方",
                        placeholder: "sk-…", initial: st.apiKey) { st.apiKey = $0 }
        }
        .sheet(isPresented: $editBase) {
            PromptSheet(title: "接口地址",
                        hint: st.provider == "anthropic"
                            ? "例如 https://api.anthropic.com/v1"
                            : "例如 https://api.openai.com/v1 或自建中转",
                        placeholder: "https://…/v1", initial: st.baseURL) { st.baseURL = $0 }
        }
        .sheet(isPresented: $editModel) {
            PromptSheet(title: "模型名", hint: "填服务商实际接受的 model 值",
                        placeholder: "gpt-4o", initial: st.model) { st.model = $0 }
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

    private func statLine(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundColor(T.txt2)
            Spacer()
            Text(v).font(T.mono(11)).foregroundColor(T.txt3)
        }
    }
}
