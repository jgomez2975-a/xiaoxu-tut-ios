import SwiftUI

// MARK: - 权限

struct PermPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    var body: some View {
        PanelShell(title: "权限", sub: "授权不是 UI 装饰：关掉之后，节点侧那道门也会拒绝") {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ToggleRow(title: "宿主文件读取",
                              sub: "允许 AI 读节点上的授权根目录；越界路径节点侧直接 403",
                              on: $st.allowFileRead)
                    RowDivider()
                    ToggleRow(title: "命令执行",
                              sub: "允许在节点上跑 shell 命令；关闭后终端页只能预览不能执行",
                              on: $st.allowExec)
                    RowDivider()
                    ToggleRow(title: "抓包代理",
                              sub: "允许启停节点上的 MITM 代理与改写规则",
                              on: $st.allowProxy)
                }
            }

            SectionTitle(text: "本机能力")
            Card {
                item("人设 / 技能 / 文档", "可用", T.green, "全部内置在 App 沙箱，离网可用")
                item("对话", st.activeProvider.apiKey.isEmpty ? "缺 Key" : "可用",
                     st.activeProvider.apiKey.isEmpty ? T.orange : T.green,
                     st.activeProvider.apiKey.isEmpty ? "设置 → 模型 → API Key" : "\(st.activeProvider.providerLabel) · \(st.activeProvider.model)")
                item("终端 / Linux", LinuxRuntime.shared.stage.isReady ? "运行中" : "未启动",
                     LinuxRuntime.shared.stage.isReady ? T.green : T.orange,
                     "内置 iSH 内核 + Alpine，真 shell，不需要节点")
                item("逆向分析", RevLocal.shared.r2Ready ? "radare2 就绪" : "待启动 Linux",
                     RevLocal.shared.r2Ready ? T.green : T.txt3,
                     "本机跑 r2 + r2ghidra；节点模式下更完整")
                item("抓包", LocalProxy.shared.running
                     ? "本机代理 :\(LocalProxy.shared.port)" : "可启动",
                     LocalProxy.shared.running ? T.green : T.txt3,
                     "本机 HTTP 代理（明文可改）；HTTPS 只看隧道，MITM 需装 CA")
                item("本机文件读写", "可用", T.green, "Documents / Workspace，「文件」App 同步可见")
                item("读写其他 App 容器", "不可用", T.txt3, "iOS 沙箱硬约束，越狱环境另说")
            }

            SectionTitle(text: "锁定")
            Card(padding: 0) {
                ToggleRow(title: "Face ID 保护", sub: "启动时校验身份", on: $st.faceIDLock)
            }
            Text("Face ID 需要工程里配 NSFaceIDUsageDescription；不填也不会崩，只是拿不到结果。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)
        }
    }

    private func item(_ t: String, _ v: String, _ c: Color, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(c).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(t).font(.system(size: 13)).foregroundColor(T.txt)
                    Spacer()
                    Text(v).font(T.mono(10.5)).foregroundColor(c)
                }
                Text(s).font(.system(size: 10.5)).foregroundColor(T.txt3)
            }
        }
    }
}

// MARK: - 宿主访问

struct HostPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var newPath = ""
    @State private var browsePath = ""
    @State private var listing: [String] = []
    @State private var busy = false
    @State private var msg = ""

    var body: some View {
        PanelShell(title: "宿主访问", sub: "授权根写在节点侧；这里只是决定 AI 能不能用") {
            Card(padding: 0) {
                ToggleRow(title: "允许读取", sub: "关闭后所有 /api/host/* 调用直接拒绝",
                          on: $st.allowFileRead)
                    .onChange(of: st.allowFileRead) { on in
                        syncEnabled(on)
                    }
            }

            SectionTitle(text: "授权根")
            Card {
                if st.hostRoots.isEmpty {
                    Text("还没有授权根。加一个，例如 D:\\work 或 /Users/me/src")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                }
                ForEach(st.hostRoots.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Image(systemName: st.hostRoots[i].mode == "rw" ? "pencil.and.outline" : "eye")
                            .font(.system(size: 11)).foregroundColor(T.accent)
                        Text(st.hostRoots[i].path).font(T.mono(11)).foregroundColor(T.txt)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            let m = (st.hostRoots[i].mode == "rw" ? "ro" : "rw")
                            st.hostRoots[i].mode = m
                            syncRoot(st.hostRoots[i].path, mode: m)
                        } label: {
                            Pill(text: st.hostRoots[i].mode == "rw" ? "读写" : "只读",
                                 color: st.hostRoots[i].mode == "rw" ? T.orange : T.txt3)
                        }
                        .buttonStyle(.plain)
                        Button {
                            let p = st.hostRoots[i].path
                            st.hostRoots.remove(at: i)
                            syncRoot(p, del: true)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                                .foregroundColor(T.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    TextField("新增授权根", text: $newPath)
                        .font(T.mono(11.5))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .glass(8)
                    Button {
                        let p = newPath.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty else { return }
                        st.hostRoots.append(HostRoot(path: p, mode: "ro"))
                        newPath = ""
                        syncRoot(p)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(T.accent).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            SectionTitle(text: "在节点上浏览")
            Card {
                HStack(spacing: 8) {
                    TextField("路径", text: $browsePath)
                        .font(T.mono(11.5))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .glass(8)
                    Button("列出") { ls() }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(T.accent.opacity(0.18))
                        .foregroundColor(T.accent)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                }
                if busy { ProgressView().scaleEffect(0.7) }
                if !msg.isEmpty {
                    Text(msg).font(T.mono(10)).foregroundColor(T.txt3)
                        .textSelection(.enabled)
                }
                ForEach(listing, id: \.self) { p in
                    Button {
                        browsePath = p
                        ls()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.hasSuffix("/") ? "folder" : "doc")
                                .font(.system(size: 10)).foregroundColor(T.txt3)
                            Text(p).font(T.mono(10.5)).foregroundColor(T.txt2)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            if st.bridgeOn { hub.refresh(st) }
            if browsePath.isEmpty, let r = st.hostRoots.first { browsePath = r.path }
        }
    }

    /// 把授权根同步到节点端 hostfs（add/del），保持两端一致
    private func syncRoot(_ path: String, mode: String = "ro", del: Bool = false) {
        guard st.bridgeOn, let b = Bridge(st) else { return }
        Task {
            _ = try? await b.hostSetRoot(path: path, mode: mode, del: del)
        }
    }

    /// 把「允许读取」开关同步到节点端 hostfs.set_enabled
    private func syncEnabled(_ on: Bool) {
        guard st.bridgeOn, let b = Bridge(st) else { return }
        Task {
            _ = try? await b.hostEnabled(on)
        }
    }

    private func ls() {
        guard let b = Bridge(st) else { msg = "节点地址无效"; return }
        busy = true; msg = ""
        Task {
            do {
                let r = try await b.hostLs(browsePath)
                var out: [String] = []
                if let arr = r["entries"] as? [[String: Any]] {
                    for e in arr {
                        let name = (e["name"] as? String) ?? ""
                        let dir = (e["dir"] as? Bool) ?? false
                        out.append(dir ? name + "/" : name)
                    }
                } else if let arr = r["list"] as? [String] {
                    out = arr
                } else {
                    msg = pretty(r)
                }
                await MainActor.run {
                    listing = out
                    busy = false
                    st.log("宿主", "列目录 \(browsePath) → \(out.count) 项")
                }
            } catch {
                await MainActor.run { msg = error.localizedDescription; busy = false }
            }
        }
    }
}

// MARK: - 终端

struct TermPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var cmd = ""
    @State private var out = ""
    @State private var exit = 0
    @State private var busy = false
    @State private var history: [String] = []

    var body: some View {
        PanelShell(title: "终端", sub: "命令在节点上执行；身份决定它有没有管理员权限") {
            Card {
                Text("执行身份").font(.system(size: 12, weight: .semibold)).foregroundColor(T.txt2)
                Picker("", selection: $st.execIdentity) {
                    Text("普通").tag("user")
                    Text("管理员").tag("admin")
                    Text("SYSTEM").tag("system")
                }
                .pickerStyle(.segmented)
                Text(identityHint).font(.system(size: 10.5)).foregroundColor(T.txt3)

                Divider().overlay(T.line)

                HStack {
                    Text("Shell").font(.system(size: 13)).foregroundColor(T.txt)
                    Spacer()
                    Picker("", selection: $st.execShell) {
                        Text("cmd").tag("cmd")
                        Text("powershell").tag("powershell")
                        Text("bash").tag("bash")
                        Text("sh").tag("sh")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
                HStack {
                    Text("超时 \(st.execTimeout)s").font(.system(size: 12)).foregroundColor(T.txt2)
                    Slider(value: Binding(
                        get: { Double(st.execTimeout) },
                        set: { st.execTimeout = Int($0) }
                    ), in: 5...600, step: 5).tint(T.accent)
                }
            }

            Card {
                HStack(spacing: 6) {
                    Text("$").font(T.mono(12, .bold)).foregroundColor(T.green)
                    TextField("输入命令", text: $cmd)
                        .font(T.mono(12))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { run() }
                }
                HStack(spacing: 8) {
                    Button {
                        run()
                    } label: {
                        HStack(spacing: 4) {
                            if busy { ProgressView().scaleEffect(0.6) }
                            Text(busy ? "执行中" : "执行")
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(st.allowExec ? T.accent : T.card)
                        .foregroundColor(st.allowExec ? .white : T.txt3)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !st.allowExec || cmd.isEmpty)

                    Button {
                        cmd = ""
                        out = ""
                    } label: {
                        Text("清屏").font(.system(size: 12.5))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !out.isEmpty {
                        Pill(text: "exit \(exit)", color: exit == 0 ? T.green : T.red)
                    }
                }
                if !st.allowExec {
                    Text("未授权执行：设置 → 权限 → 命令执行")
                        .font(.system(size: 10.5)).foregroundColor(T.orange)
                }
            }

            if !out.isEmpty {
                SectionTitle(text: "输出")
                CodeBox(code: out, lang: st.execShell)
            }

            if !history.isEmpty {
                SectionTitle(text: "最近")
                Card {
                    ForEach(history.prefix(8), id: \.self) { h in
                        Button {
                            cmd = h
                        } label: {
                            Text(h).font(T.mono(10.5)).foregroundColor(T.txt3)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var identityHint: String {
        switch st.execIdentity {
        case "admin": return "管理员：需要节点进程本身有管理员令牌（启动.bat admin）"
        case "system": return "SYSTEM：需要以管理员运行启动.bat system，节点会拉起系统级子进程"
        default: return "普通：与节点进程同权限，不能提权"
        }
    }

    private func run() {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let b = Bridge(st) else { return }
        busy = true
        out = "执行中…"
        Task {
            do {
                // 身份与 shell 先写进节点配置，再执行
                _ = try? await b.setIdentity(st.execIdentity, shell: st.execShell,
                                             timeout: st.execTimeout)
                let r = try await b.exec(c, shell: st.execShell, timeout: st.execTimeout)
                let stdout = (r["out"] as? String) ?? ""
                let stderr = (r["err"] as? String) ?? ""
                let code = (r["code"] as? Int) ?? -1
                var text = stdout
                if !stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + stderr }
                if text.isEmpty { text = "（无输出）\n" + pretty(r) }
                let final = text
                await MainActor.run {
                    out = final
                    exit = code
                    busy = false
                    history.insert(c, at: 0)
                    st.log("终端", "\(c) → exit \(code)")
                }
            } catch {
                await MainActor.run {
                    out = error.localizedDescription
                    exit = -1
                    busy = false
                    st.log("终端", "失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - GitHub

struct GitHubPanel: View {
    @EnvironmentObject var st: AppSettings
    @State private var out = ""
    @State private var busy = false

    var body: some View {
        PanelShell(title: "GitHub 连接", sub: "Token 存在节点侧，手机只发指令") {
            Card {
                field("Token", text: $st.ghToken, placeholder: "ghp_… / github_pat_…")
                field("仓库", text: $st.ghRepo, placeholder: "owner/repo")
                HStack(spacing: 8) {
                    Button {
                        save()
                    } label: {
                        Text("保存到节点").font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(T.accent).foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        loadState()
                    } label: {
                        Text("读取状态").font(.system(size: 12.5))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if busy { ProgressView().scaleEffect(0.7) }
                }
            }
            if !out.isEmpty {
                SectionTitle(text: "返回")
                CodeBox(code: out, lang: "json")
            }
            Text("节点侧用 Contents API，能读树、读文件、写提交；写操作要 repo 权限的 token。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)
        }
        .onAppear { loadState() }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundColor(T.txt3)
            TextField(placeholder, text: text)
                .font(T.mono(11.5))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .glass(8)
        }
    }

    private func save() {
        guard let b = Bridge(st) else { return }
        busy = true
        Task {
            do {
                let r = try await b.ghSave(token: st.ghToken, repo: st.ghRepo)
                await MainActor.run { out = pretty(r); busy = false; st.log("GitHub", "保存配置") }
            } catch {
                await MainActor.run { out = error.localizedDescription; busy = false }
            }
        }
    }

    private func loadState() {
        guard let b = Bridge(st), st.bridgeOn else { return }
        Task {
            if let r = try? await b.ghState() {
                await MainActor.run {
                    out = pretty(r)
                    if let t = r["token"] as? String, !t.isEmpty, st.ghToken.isEmpty {
                        st.ghToken = t
                    }
                    if let rp = r["repo"] as? String, !rp.isEmpty, st.ghRepo.isEmpty {
                        st.ghRepo = rp
                    }
                }
            }
        }
    }
}

// MARK: - 上下文窗口

struct CtxPanel: View {
    @EnvironmentObject var st: AppSettings

    private var chars: Int { st.messages.reduce(0) { $0 + $1.text.count } }
    private var est: Int { chars / 2 }   // 中文约 1.5 字/token，粗算

    var body: some View {
        PanelShell(title: "上下文窗口", sub: "超阈值时从最老的消息开始丢，system 永不丢") {
            Card {
                HStack {
                    Text("上限").font(.system(size: 13.5)).foregroundColor(T.txt)
                    Spacer()
                    Text("\(st.ctxLimit) token").font(T.mono(11.5)).foregroundColor(T.accent)
                }
                Slider(value: Binding(
                    get: { Double(st.ctxLimit) },
                    set: { st.ctxLimit = Int($0) }
                ), in: 4000...200000, step: 2000).tint(T.accent)
                Text("常见值：GPT-4o 128k / Claude 200k / 本地小模型 8k–32k。")
                    .font(.system(size: 10.5)).foregroundColor(T.txt3)
                Divider().overlay(T.line)
                ToggleRow(title: "自动压缩", sub: "接近上限时先丢最老的对话", on: $st.autoCompact)
            }

            SectionTitle(text: "当前占用")
            Card {
                row("消息条数", "\(st.messages.count)")
                row("正文字符", "\(chars)")
                row("估算 token", "≈\(est)")
                row("SYSTEM", "\(PromptBuilder.assemble(st, bridge: BridgeState()).bytes) 字节")
                let pct = min(1.0, Double(est) / Double(max(1, st.ctxLimit)))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(T.card)
                        Capsule()
                            .fill(pct > 0.85 ? T.red : (pct > 0.6 ? T.orange : T.green))
                            .frame(width: g.size.width * CGFloat(pct))
                    }
                }
                .frame(height: 6)
                Text(String(format: "%.1f%% 占用", pct * 100))
                    .font(T.mono(10)).foregroundColor(T.txt3)
            }

            Button(role: .destructive) {
                st.resetChat()
            } label: {
                HStack {
                    Spacer()
                    Text("清空会话").font(.system(size: 13.5))
                    Spacer()
                }
                .padding(.vertical, 11).glass(12)
            }
            .buttonStyle(.plain).foregroundColor(T.red)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundColor(T.txt2)
            Spacer()
            Text(v).font(T.mono(11)).foregroundColor(T.txt3)
        }
    }
}

// MARK: - 日志

struct LogsPanel: View {
    @EnvironmentObject var st: AppSettings
    @State private var filter = ""

    private var list: [LogItem] {
        let k = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return Array(st.logs.reversed()) }
        return Array(st.logs.reversed()).filter {
            $0.kind.lowercased().contains(k) || $0.text.lowercased().contains(k)
        }
    }

    var body: some View {
        PanelShell(title: "日志", sub: "\(st.logs.count) 条 · 只存本机，最多 800 条") {
            SearchBar(text: $filter, placeholder: "按类型或内容过滤")
            if list.isEmpty {
                EmptyHint(icon: "list.bullet.rectangle", title: "没有日志")
            }
            ForEach(list) { l in
                HStack(alignment: .top, spacing: 8) {
                    Text(l.ts).font(T.mono(9.5)).foregroundColor(T.txt3).frame(width: 52, alignment: .leading)
                    Pill(text: l.kind, color: kindColor(l.kind))
                    Text(l.text).font(.system(size: 11.5)).foregroundColor(T.txt2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
            Button(role: .destructive) {
                st.clearLogs()
            } label: {
                HStack {
                    Spacer()
                    Text("清空日志").font(.system(size: 13.5))
                    Spacer()
                }
                .padding(.vertical, 11).glass(12)
            }
            .buttonStyle(.plain).foregroundColor(T.red)
        }
    }

    private func kindColor(_ k: String) -> Color {
        switch k {
        case "终端": return T.green
        case "逆向": return T.purple
        case "抓包": return T.teal
        case "错误": return T.red
        case "节点": return T.accent
        default: return T.txt3
        }
    }
}

// MARK: - 通用

func pretty(_ obj: Any) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        return s
    }
    return String(describing: obj)
}
