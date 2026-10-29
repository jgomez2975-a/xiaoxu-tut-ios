import SwiftUI

struct RevFunc: Identifiable, Hashable {
    var name: String
    var offset: Int
    var size: Int
    var id: String { "\(name)@\(offset)" }
    var hex: String { String(format: "0x%llx", Int64(offset)) }
}

// MARK: - 逆向分析

struct RevPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var targets: [RevTarget] = []
    @State private var current: RevTarget?
    @State private var funcs: [RevFunc] = []
    @State private var code = ""
    @State private var engine = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var addPath = ""

    var body: some View {
        PanelShell(title: "逆向分析", sub: "解析在节点上做；手机只负责挑目标和读伪代码") {
            statusCard

            SectionTitle(text: "目标 \(targets.count)")
            Card {
                if targets.isEmpty {
                    Text("还没有目标。填节点上的一个二进制路径（.app 主程序、.so、.exe 都行）。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(targets) { t in
                    Button {
                        select(t)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: current?.id == t.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(current?.id == t.id ? T.accent : T.txt3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.label.isEmpty ? t.path : t.label)
                                    .font(.system(size: 12.5)).foregroundColor(T.txt)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 5) {
                                    if !t.arch.isEmpty { Pill(text: t.arch, color: T.purple) }
                                    if !t.size.isEmpty {
                                        Text(t.size).font(T.mono(9)).foregroundColor(T.txt3)
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                remove(t)
                            } label: {
                                Image(systemName: "trash").font(.system(size: 10))
                                    .foregroundColor(T.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    TextField("节点上的路径", text: $addPath)
                        .font(T.mono(11))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .glass(8)
                    Button {
                        addTarget()
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white).frame(width: 30, height: 30)
                            .background(T.accent).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                if !msg.isEmpty {
                    Text(msg).font(T.mono(10)).foregroundColor(T.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if busy {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("节点在算；首次分析大文件要几十秒").font(.system(size: 11)).foregroundColor(T.txt3)
                }
            }

            if current != nil && !funcs.isEmpty {
                SectionTitle(text: "函数 \(funcs.count) · 点一条出伪代码")
                Card {
                    ForEach(funcs.prefix(120)) { f in
                        Button {
                            decompile(f)
                        } label: {
                            HStack(spacing: 6) {
                                Text(f.name).font(T.mono(10.5)).foregroundColor(T.accent)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(f.hex).font(T.mono(9)).foregroundColor(T.txt3)
                                if f.size > 0 {
                                    Text("\(f.size)B").font(T.mono(9)).foregroundColor(T.txt3)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !code.isEmpty {
                SectionTitle(text: engine.isEmpty ? "伪代码" : "伪代码 · \(engine)")
                Card {
                    HStack {
                        Text(engine.isEmpty ? "r2" : engine).font(T.mono(10)).foregroundColor(T.txt3)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = code
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.system(size: 11)).foregroundColor(T.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(code).font(T.mono(10))
                        .foregroundColor(Color(red: 0.80, green: 0.88, blue: 0.95))
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            if st.bridgeOn {
                hub.refresh(st)
                loadRemote()
            } else {
                targets = st.revTargets
            }
        }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 8) {
                Circle().fill(hub.state.revReady ? T.green : T.txt3).frame(width: 6, height: 6)
                Text(hub.state.revReady ? "radare2 就绪" : "节点未就绪")
                    .font(T.mono(11)).foregroundColor(T.txt2)
                Spacer()
                Button {
                    hub.refresh(st)
                    loadRemote()
                } label: {
                    Text("刷新").font(.system(size: 11.5)).foregroundColor(T.accent)
                }
                .buttonStyle(.plain)
            }
            Text("伪代码引擎按 pdg → pdd → pdc → pdf 自动降级，节点返回哪个就用哪个。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)
                .fixedSize(horizontal: false, vertical: true)
            if !hub.state.online {
                Text("逆向只能在节点上跑：iOS 沙箱不能 fork 进程，也不允许执行 App 之外的可执行文件。")
                    .font(.system(size: 10.5)).foregroundColor(T.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadRemote() {
        guard let b = Bridge(st), st.bridgeOn else { return }
        Task {
            guard let r = try? await b.revTargets(),
                  let arr = r["targets"] as? [[String: Any]] else { return }
            var list: [RevTarget] = []
            for d in arr {
                var t = RevTarget()
                t.key = (d["id"] as? String) ?? ""
                t.path = (d["path"] as? String) ?? ""
                t.label = (d["name"] as? String) ?? ""
                t.arch = (d["arch"] as? String) ?? ((d["kind"] as? String) ?? "")
                t.size = (d["size"] as? String) ?? ""
                list.append(t)
            }
            await MainActor.run { targets = list }
        }
    }

    private func addTarget() {
        let p = addPath.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        guard let b = Bridge(st), st.bridgeOn else {
            msg = "节点未连接"
            return
        }
        busy = true
        Task {
            do {
                _ = try await b.json("/api/rev/add", method: "POST", body: ["path": p])
                await MainActor.run {
                    addPath = ""
                    busy = false
                    st.log("逆向", "加入目标 \(p)")
                }
                loadRemote()
            } catch {
                await MainActor.run { msg = error.localizedDescription; busy = false }
            }
        }
    }

    private func remove(_ t: RevTarget) {
        guard let b = Bridge(st), st.bridgeOn else { return }
        Task {
            _ = try? await b.json("/api/rev/del", method: "POST", body: ["id": t.callKey])
            await MainActor.run {
                targets.removeAll { $0.id == t.id }
                if current?.id == t.id { current = nil; funcs = [] }
            }
            loadRemote()
        }
    }

    private func select(_ t: RevTarget) {
        current = t
        funcs = []
        code = ""
        msg = ""
        guard let b = Bridge(st), st.bridgeOn else { return }
        busy = true
        Task {
            do {
                let r = try await b.revFuncs(t.callKey, limit: 150)
                var out: [RevFunc] = []
                if let arr = r["functions"] as? [[String: Any]] {
                    for f in arr {
                        out.append(RevFunc(name: (f["name"] as? String) ?? "?",
                                           offset: (f["offset"] as? Int) ?? 0,
                                           size: (f["size"] as? Int) ?? 0))
                    }
                }
                let err = (r["error"] as? String) ?? ""
                let cnt = (r["count"] as? Int) ?? out.count
                await MainActor.run {
                    funcs = out
                    busy = false
                    if out.isEmpty { msg = err.isEmpty ? "没有函数" : err }
                    st.log("逆向", "\(t.path) → \(cnt) 个函数")
                }
            } catch {
                await MainActor.run { msg = error.localizedDescription; busy = false }
            }
        }
    }

    private func decompile(_ f: RevFunc) {
        guard let b = Bridge(st), let t = current else { return }
        busy = true
        code = ""
        msg = ""
        Task {
            do {
                let r = try await b.revPseudo(t.callKey, off: f.offset)
                let text = (r["text"] as? String) ?? ""
                let eng = (r["engine"] as? String) ?? ""
                let err = (r["error"] as? String) ?? ""
                await MainActor.run {
                    engine = eng
                    code = text.isEmpty ? (err.isEmpty ? "（无输出）" : err) : text
                    busy = false
                    st.log("逆向", "\(f.name) → \(eng) \(text.count) 字")
                }
            } catch {
                await MainActor.run {
                    code = error.localizedDescription
                    busy = false
                }
            }
        }
    }
}

// MARK: - 抓包与改写

struct ProxyPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var port = "8888"
    @State private var sessions: [[String: Any]] = []
    @State private var busy = false
    @State private var msg = ""
    @State private var editRule = false
    @State private var draft = ProxyRule()

    var body: some View {
        PanelShell(title: "抓包与改写", sub: "MITM 跑在节点上；手机把 WiFi 代理指到节点 IP") {
            Card {
                HStack(spacing: 8) {
                    Circle().fill(hub.state.proxyRunning ? T.green : T.txt3)
                        .frame(width: 6, height: 6)
                    Text(hub.state.proxyRunning
                         ? "运行中 · :\(String(hub.state.proxyPort))"
                         : "未启动")
                        .font(T.mono(11)).foregroundColor(T.txt2)
                    Spacer()
                    Text("\(hub.state.proxyCount) 条").font(T.mono(10)).foregroundColor(T.txt3)
                }
                HStack(spacing: 8) {
                    TextField("端口", text: $port)
                        .font(T.mono(12))
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .frame(width: 84)
                        .glass(8)
                    Button {
                        toggle()
                    } label: {
                        Text(hub.state.proxyRunning ? "停止" : "启动")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(st.allowProxy
                                        ? (hub.state.proxyRunning ? T.red : T.green)
                                        : T.card)
                            .foregroundColor(st.allowProxy ? .white : T.txt3)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !st.allowProxy)

                    Button {
                        loadSessions()
                    } label: {
                        Text("刷新").font(.system(size: 12))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if busy { ProgressView().scaleEffect(0.7) }
                }
                if !st.allowProxy {
                    Text("未授权：设置 → 权限 → 抓包代理")
                        .font(.system(size: 10.5)).foregroundColor(T.orange)
                }
                if !msg.isEmpty {
                    Text(msg).font(T.mono(10)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionTitle(text: "在手机上下载 CA")
            Card {
                Text("节点启动代理后生成自签 CA。手机浏览器打开下面地址装描述文件，再到「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任。")
                    .font(.system(size: 11.5)).foregroundColor(T.txt2)
                    .fixedSize(horizontal: false, vertical: true)
                CodeBox(code: "http://\(hostOnly):\(port)/api/proxy/ca.crt", lang: "url")
                Text("然后把 WiFi 的 HTTP 代理指到 \(hostOnly):\(port)。")
                    .font(.system(size: 10.5)).foregroundColor(T.txt3)
            }

            SectionTitle(text: "改写规则 \(st.proxyRules.count)")
            Card {
                if st.proxyRules.isEmpty {
                    Text("没有规则。规则用正则匹配 URL，命中才改写，其余流量原样放过。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(st.proxyRules.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $st.proxyRules[i].on)
                            .labelsHidden().tint(T.accent).scaleEffect(0.75)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.proxyRules[i].url.isEmpty ? "*" : st.proxyRules[i].url)
                                .font(T.mono(10.5)).foregroundColor(T.txt)
                                .lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 4) {
                                Pill(text: st.proxyRules[i].phase,
                                     color: st.proxyRules[i].phase == "req" ? T.orange : T.teal)
                                if !st.proxyRules[i].bodyMatch.isEmpty {
                                    Text("替换 \(st.proxyRules[i].bodyMatch.prefix(14))")
                                        .font(T.mono(9)).foregroundColor(T.txt3).lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            del(st.proxyRules[i])
                            st.proxyRules.remove(at: i)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                                .foregroundColor(T.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    draft = ProxyRule()
                    editRule = true
                } label: {
                    Label("新增规则", systemImage: "plus.circle")
                        .font(.system(size: 12.5)).foregroundColor(T.accent)
                }
                .buttonStyle(.plain)
            }

            if !sessions.isEmpty {
                SectionTitle(text: "会话 \(sessions.count)")
                Card {
                    ForEach(sessions.indices, id: \.self) { i in
                        let s = sessions[i]
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text((s["method"] as? String) ?? "?")
                                    .font(T.mono(9.5, .bold)).foregroundColor(T.accent)
                                Text("\((s["status"] as? Int) ?? 0)")
                                    .font(T.mono(9.5))
                                    .foregroundColor(((s["status"] as? Int) ?? 0) >= 400 ? T.red : T.green)
                                Text((s["sizeText"] as? String) ?? "\(s["size"] as? Int ?? 0)B")
                                    .font(T.mono(9)).foregroundColor(T.txt3)
                                Spacer()
                            }
                            Text((s["url"] as? String) ?? "")
                                .font(T.mono(9.5)).foregroundColor(T.txt2)
                                .lineLimit(2).truncationMode(.middle)
                            if let hits = s["hits"] as? [String], !hits.isEmpty {
                                Pill(text: "改写 ×\(hits.count)", color: T.teal)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .onAppear {
            if st.bridgeOn {
                hub.refresh(st)
                loadSessions()
                if hub.state.proxyPort > 0 { port = "\(hub.state.proxyPort)" }
            }
        }
        .sheet(isPresented: $editRule) {
            RuleEditor(rule: draft) { r in
                st.proxyRules.append(r)
                push(r)
            }
        }
    }

    private var hostOnly: String {
        st.bridgeURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first ?? st.bridgeURL
    }

    private func toggle() {
        guard let b = Bridge(st) else { return }
        busy = true
        Task {
            do {
                if hub.state.proxyRunning {
                    _ = try await b.proxyStop()
                } else {
                    _ = try await b.proxyStart(Int(port) ?? 8888)
                }
                await MainActor.run { busy = false }
                hub.refresh(st)
                loadSessions()
                await MainActor.run { st.log("抓包", "切换代理 :\(port)") }
            } catch {
                await MainActor.run { msg = error.localizedDescription; busy = false }
            }
        }
    }

    private func loadSessions() {
        guard let b = Bridge(st), st.bridgeOn else { return }
        Task {
            if let r = try? await b.proxySessions(),
               let arr = r["sessions"] as? [[String: Any]] {
                await MainActor.run { sessions = Array(arr.prefix(60).reversed()) }
            }
            hub.refresh(st)
        }
    }

    private func push(_ r: ProxyRule) {
        guard let b = Bridge(st) else { return }
        Task {
            _ = try? await b.json("/api/proxy/rule", method: "POST", body: [
                "action": "add",
                "url": r.url, "phase": r.phase,
                "bodyMatch": r.bodyMatch, "bodyReplace": r.bodyReplace,
                "setHeader": r.setHeader, "on": r.on,
                "name": r.url.isEmpty ? "手机端规则" : r.url
            ])
            await MainActor.run { st.log("抓包", "新增规则 \(r.url)") }
        }
    }

    private func del(_ r: ProxyRule) {
        guard let b = Bridge(st) else { return }
        Task {
            _ = try? await b.json("/api/proxy/rule", method: "POST",
                                  body: ["action": "del", "id": r.url])
        }
    }
}

/// 正则合法性检查。用 NSRegularExpression 真编译一遍 —— 跟节点侧 re 的方言不完全一样，
/// 但 90% 的写错都能在本地拦住，省得推到节点才报错。
struct RegexCheck {
    let ok: Bool
    let detail: String

    init(_ p: String) {
        let s = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            self.ok = false
            self.detail = "空"
            return
        }
        do {
            _ = try NSRegularExpression(pattern: s)
        } catch {
            self.ok = false
            self.detail = (error as NSError).localizedDescription
            return
        }
        if s.count > 2, s.hasPrefix("/"), s.hasSuffix("/") {
            self.ok = false
            self.detail = "带了 /.../ 分隔符，去掉首尾斜杠"
        } else if s.range(of: #"\(\?<[A-Za-z]"#, options: .regularExpression) != nil {
            self.ok = false
            self.detail = "ICU 不支持命名捕获组 (?<name>)，用普通 ( )"
        } else {
            self.ok = true
            self.detail = "合法"
        }
    }
}

struct RuleEditor: View {
    @State var rule: ProxyRule
    var onSave: (ProxyRule) -> Void
    @Environment(\.dismiss) private var dismiss

    private var urlCheck: RegexCheck { RegexCheck(rule.url) }
    private var bodyCheck: RegexCheck { RegexCheck(rule.bodyMatch) }

    /// url 必填且必须合法；bodyMatch 留空表示不做正文替换，填了就必须合法
    private var canSave: Bool {
        urlCheck.ok && (rule.bodyMatch.isEmpty || bodyCheck.ok)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    presets

                    Card {
                        Text("名字（只给列表显示用）")
                            .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        TextField("例如 改 VIP 字段", text: $rule.name)
                            .font(.system(size: 12.5))
                            .padding(8).glass(8)
                    }

                    Card {
                        HStack {
                            Text("匹配（正则）").font(.system(size: 11.5)).foregroundColor(T.txt3)
                            Spacer()
                            checkBadge(urlCheck, empty: "必填")
                        }
                        TextField("例如 api\\.example\\.com/v1/user", text: $rule.url)
                            .font(T.mono(11.5))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(8).glass(8)
                        if !urlCheck.ok && !rule.url.isEmpty {
                            Text(urlCheck.detail)
                                .font(.system(size: 10)).foregroundColor(T.red)
                        }
                        Text("整条 URL 匹配，不带 /.../ 分隔符。留空 = 命中所有请求，慎用。")
                            .font(.system(size: 10)).foregroundColor(T.txt3)

                        Picker("", selection: $rule.phase) {
                            Text("请求+响应").tag("both")
                            Text("只请求").tag("req")
                            Text("只响应").tag("res")
                        }
                        .pickerStyle(.segmented)
                    }

                    Card {
                        HStack {
                            Text("正文替换").font(.system(size: 11.5)).foregroundColor(T.txt3)
                            Spacer()
                            if !rule.bodyMatch.isEmpty {
                                checkBadge(bodyCheck, empty: "可空")
                            }
                        }
                        TextField("要匹配的正则（留空则不替换正文）", text: $rule.bodyMatch)
                            .font(T.mono(11))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(8).glass(8)
                        if !rule.bodyMatch.isEmpty && !bodyCheck.ok {
                            Text(bodyCheck.detail)
                                .font(.system(size: 10)).foregroundColor(T.red)
                        }
                        TextEditor(text: $rule.bodyReplace)
                            .font(T.mono(11))
                            .frame(height: 84)
                            .scrollContentBackground(.hidden)
                            .background(Color.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("替换串可以用 $1 / ${1} 引用分组。")
                            .font(.system(size: 10)).foregroundColor(T.txt3)
                    }

                    Card {
                        Text("改头（每行 Key: Value）")
                            .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        TextEditor(text: $rule.setHeader)
                            .font(T.mono(11))
                            .frame(height: 70)
                            .scrollContentBackground(.hidden)
                            .background(Color.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("空行和 # 开头的行会被忽略。")
                            .font(.system(size: 10)).foregroundColor(T.txt3)
                    }

                    syntax

                    Card {
                        HStack {
                            Text("启用").font(.system(size: 12.5)).foregroundColor(T.txt)
                            Spacer()
                            Toggle("", isOn: $rule.on).labelsHidden()
                        }
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("改写规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var r = rule
                        if r.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            r.name = r.url.isEmpty ? "手机端规则" : r.url
                        }
                        onSave(r)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: 预设

    private struct Preset {
        let label: String
        let color: Color
        let make: () -> ProxyRule
    }

    private var presetList: [Preset] {
        [
            Preset(label: "看某接口的返回", color: T.accent) {
                var r = ProxyRule()
                r.name = "抓接口返回"
                r.url = #"api\.example\.com/v\d+/"#
                r.phase = "res"
                return r
            },
            Preset(label: "改 VIP 字段", color: T.purple) {
                var r = ProxyRule()
                r.name = "改 VIP 字段"
                r.url = #"api\.example\.com/"#
                r.phase = "res"
                r.bodyMatch = #""vip"\s*:\s*false"#
                r.bodyReplace = #""vip": true"#
                return r
            },
            Preset(label: "换 UA", color: T.orange) {
                var r = ProxyRule()
                r.name = "换 User-Agent"
                r.url = #"https?://"#
                r.phase = "req"
                r.setHeader = "User-Agent: NpcLab/1.0"
                return r
            },
            Preset(label: "加鉴权头", color: T.green) {
                var r = ProxyRule()
                r.name = "加鉴权头"
                r.url = #"api\.example\.com/"#
                r.phase = "req"
                r.setHeader = "Authorization: Bearer <token>"
                return r
            }
        ]
    }

    private var presets: some View {
        Card {
            Text("从模板起手")
                .font(.system(size: 11.5)).foregroundColor(T.txt3)
            // 两行两列，不用 LazyVGrid 省一层嵌套
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { col in
                        let i = row * 2 + col
                        let p = presetList[i]
                        Button {
                            rule = p.make()
                        } label: {
                            Text(p.label)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(p.color)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(p.color.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 语法说明

    private var syntax: some View {
        Card {
            Text("写法要点")
                .font(.system(size: 11.5, weight: .semibold)).foregroundColor(T.txt2)
            ForEach(syntaxTips.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundColor(T.txt3)
                    Text(syntaxTips[i])
                        .font(.system(size: 10.5))
                        .foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var syntaxTips: [String] {
        [
            "不要带 /.../ 或 #...# 分隔符，直接写正则本身。",
            #"点在正则里是「任意字符」，要匹配真点号写 \. （Swift 字符串里是 \\. ）。"#,
            "忽略大小写用 (?i) 开头，例如 (?i)api\\.example\\.com 。",
            "贪婪改非贪婪：.*? 而不是 .* ，否则会一路吃到最后一个引号。",
            #"替换串引用分组写 $1 或 ${1}，不是 \1 。"#,
            "中文和 emoji 按 UTF-16 码元算，跨字符的 . 可能只吃到半个代理对。",
            "规则命中才改写，没命中的流量原样放过——不会因为写了规则就全断。"
        ]
    }

    // MARK: 小部件

    private func checkBadge(_ c: RegexCheck, empty: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 9))
            Text(c.ok ? "OK" : c.detail == "空" ? empty : "有问题")
                .font(.system(size: 9.5))
        }
        .foregroundColor(c.ok ? T.green : T.red)
    }
}
