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

    @State private var newPath = ""
    @State private var msg = ""

    var body: some View {
        PanelShell(title: "宿主访问",
                   sub: "授权手机本机文件给 AI 读写；跟 PC 节点的授权根是两回事") {

            // ===== 总开关 =====
            SectionTitle(text: "总开关")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    RadioRow(color: T.txt3, symbol: "lock.slash",
                             title: "全部关闭",
                             sub: "AI 无法访问任何宿主文件，只能用已复制到沙盒的内容",
                             selected: st.hostAccessMode == "off") {
                        setMode("off")
                    }
                    RowDivider()
                    RadioRow(color: T.accent, symbol: "hand.raised",
                             title: "逐项授权",
                             sub: "AI 访问未授权位置时弹窗确认；已授权位置直接可用",
                             selected: st.hostAccessMode == "ask") {
                        setMode("ask")
                    }
                    RowDivider()
                    RadioRow(color: T.green, symbol: "checkmark.shield",
                             title: "授权项自动放行",
                             sub: "已打开开关的位置全部直接可用，不再询问",
                             selected: st.hostAccessMode == "always") {
                        setMode("always")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            SectionFootnote(text: "「全部关闭」会立即撤销所有已授权位置。切到该档后 AI 无法读取任何宿主文件。")

            // ===== 全盘访问 =====
            SectionTitle(text: "全盘访问")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    IconToggleRow(color: T.orange, symbol: "internaldrive",
                                  title: "全盘访问（读写）",
                                  sub: "开启后 AI 可读写手机上任意路径，包含越狱目录与其 App 容器",
                                  on: $st.hostFullDisk)
                    RowDivider()
                    IconToggleRow(color: T.teal, symbol: "lock.doc",
                                  title: "写保护",
                                  sub: "全盘访问下只放读；写只给已授权且设为读写的位置",
                                  on: $st.hostWriteProtect)
                }
                .frame(maxWidth: .infinity)
            }
            SectionFootnote(text: "这是最省事的用法：开这一个就够。想精确控制时，关掉它改用下面的逐项授权。")

            // ===== 一键授权 =====
            SectionTitle(text: "一键授权")
            Card {
                VStack(spacing: 10) {
                    Button {
                        grantAll()
                    } label: {
                        Text("一键授权全部位置（读写）")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(canAuthorize ? T.accent : T.card)
                            .foregroundColor(canAuthorize ? .white : T.txt3)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAuthorize)

                    Button {
                        revokeAll()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle").font(.system(size: 12, weight: .semibold))
                            Text("撤销全部").font(.system(size: 14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(T.card)
                        .foregroundColor(st.hostGrants.isEmpty ? T.txt3 : T.red)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(st.hostGrants.isEmpty)

                    HStack(spacing: 0) {
                        Text(grantSummary).font(.system(size: 11.5)).foregroundColor(T.txt3)
                        Spacer()
                    }
                }
            }
            SectionFootnote(text: "一次性把下面所有位置（含自定义）设为读写。不存在的路径会自动跳过，不影响其它项。总开关为「全部关闭」时不可用。")

            // ===== 自定义路径 =====
            SectionTitle(text: "自定义路径")
            Card {
                HStack(spacing: 8) {
                    TextField("/var/mobile/…  任意宿主路径", text: $newPath)
                        .font(T.mono(11.5))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .glass(8)
                        .onSubmit { addCustom() }
                    Button {
                        addCustom()
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(canAuthorize ? T.accent : T.txt3)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAuthorize)
                }
                if !msg.isEmpty {
                    Text(msg).font(.system(size: 10.5)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SectionFootnote(text: "填任意宿主绝对路径并添加。它会和内置位置一样出现在下面的列表里，可单独设只读或读写。总开关为「全部关闭」时不可用。")

            // ===== 已授权列表 =====
            SectionTitle(text: "已授权位置")
            Card(padding: 0) {
                if st.hostGrants.isEmpty {
                    HStack {
                        Text("还没有授权任何位置。点上面「一键授权全部位置」最省事。")
                            .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                } else {
                    VStack(spacing: 0) {
                        // 按 id 枚举，不用 indices —— 删一项时 indices 会错位，
                        // 轻则删错行，重则越界崩。
                        ForEach(Array(st.hostGrants.enumerated()), id: \.element.id) { item in
                            grantRow(item.element)
                            if item.offset < st.hostGrants.count - 1 { RowDivider() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // ===== 节点授权根（原来那一套，独立子页）=====
            SectionTitle(text: "PC 节点")
            Card(padding: 0) {
                NavigationLink { NodeHostPanel() } label: {
                    NavRow(color: Color(white: 0.55), symbol: "desktopcomputer",
                           title: "节点授权根",
                           sub: "授权电脑上的目录给 AI 读，走 /api/host/*，跟本机是两套",
                           value: st.hostRoots.isEmpty ? "未设置" : "\(st.hostRoots.count) 项")
                }.buttonStyle(.plain)
            }
        }
        .onAppear { refreshMsg() }
    }

    // MARK: - 行

    @ViewBuilder
    private func grantRow(_ g: HostGrant) -> some View {
        let exists = HostFS.exists(g.path)
        HStack(spacing: 8) {
            Image(systemName: g.mode == "rw" ? "pencil.and.outline" : "eye")
                .font(.system(size: 11))
                .foregroundColor(exists ? T.accent : T.txt3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(g.builtin && !g.title.isEmpty ? g.title : g.path)
                        .font(.system(size: 12.5)).foregroundColor(T.txt)
                        .lineLimit(1)
                    if !exists {
                        Text("不存在").font(.system(size: 9.5))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(T.orange.opacity(0.18))
                            .foregroundColor(T.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(g.path).font(T.mono(9.5)).foregroundColor(T.txt3)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button {
                toggleMode(g.id)
            } label: {
                Pill(text: g.mode == "rw" ? "读写" : "只读",
                     color: g.mode == "rw" ? T.orange : T.txt3)
            }
            .buttonStyle(.plain)

            Button {
                removeGrant(g.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
                    .foregroundColor(T.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func toggleMode(_ id: UUID) {
        guard let i = st.hostGrants.firstIndex(where: { $0.id == id }) else { return }
        st.hostGrants[i].mode = (st.hostGrants[i].mode == "rw" ? "ro" : "rw")
        refreshMsg()
    }

    private func removeGrant(_ id: UUID) {
        guard let i = st.hostGrants.firstIndex(where: { $0.id == id }) else { return }
        let p = st.hostGrants[i].path
        st.hostGrants.remove(at: i)
        st.log("宿主", "撤销授权 \(p)")
        refreshMsg()
    }

    // MARK: - 状态

    private var canAuthorize: Bool { st.hostAccessMode != "off" }

    private var grantSummary: String {
        let n = st.hostGrants.count
        guard n > 0 else { return "已授权 0 项" }
        let rw = st.hostGrants.filter { $0.mode == "rw" }.count
        let ro = n - rw
        if ro == 0 { return "已授权 \(n) 项（读写）" }
        if rw == 0 { return "已授权 \(n) 项（只读）" }
        return "已授权 \(n) 项（读写 \(rw) · 只读 \(ro)）"
    }

    private func refreshMsg() {
        if st.hostAccessMode == "off" {
            msg = ""
        }
    }

    // MARK: - 操作

    private func setMode(_ m: String) {
        st.hostAccessMode = m
        // 「全部关闭」立即撤销所有已授权位置（对齐 AzTuT 那句说明）
        if m == "off" {
            let n = st.hostGrants.count
            st.hostGrants.removeAll()
            st.hostFullDisk = false
            st.log("宿主", "切到全部关闭，撤销 \(n) 项授权")
        }
        refreshMsg()
    }

    /// 一键授权：内置位置（探活通过）+ 用户已经加过的自定义路径，全部设成读写。
    /// 不存在的路径直接跳过 —— 越狱目录在非越狱设备上本来就 stat 不到。
    private func grantAll() {
        var grants: [HostGrant] = []
        var skipped = 0

        for p in HostFS.presets {
            guard HostFS.exists(p.path) else { skipped += 1; continue }
            grants.append(HostGrant(path: p.path, mode: "rw",
                                    builtin: true, title: p.title))
        }

        // 保留用户自定义的那些（内置的会被上面重建，别重复）
        for g in st.hostGrants where !g.builtin {
            if HostFS.exists(g.path) {
                grants.append(HostGrant(path: g.path, mode: "rw",
                                        builtin: false, title: g.title))
            } else {
                skipped += 1
            }
        }

        st.hostGrants = grants
        if st.hostAccessMode == "off" { st.hostAccessMode = "always" }
        msg = "已授权 \(grants.count) 项" + (skipped > 0 ? "，跳过 \(skipped) 项不存在的路径" : "")
        st.log("宿主", "一键授权 \(grants.count) 项，跳过 \(skipped)")
    }

    private func revokeAll() {
        let n = st.hostGrants.count
        st.hostGrants.removeAll()
        msg = "已撤销 \(n) 项"
        st.log("宿主", "撤销全部 \(n) 项")
    }

    private func addCustom() {
        let raw = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard canAuthorize else {
            msg = "总开关是「全部关闭」，先切到逐项授权或自动放行"
            return
        }
        let p = HostFS.canonical(raw)
        guard !p.isEmpty else {
            msg = "要填绝对路径，例如 /var/mobile/Documents"
            return
        }
        if st.hostGrants.contains(where: { $0.path == p }) {
            msg = "这个路径已经在列表里了"
            return
        }

        let exists = HostFS.exists(p)
        st.hostGrants.append(HostGrant(path: p, mode: "rw", builtin: false, title: ""))
        newPath = ""
        msg = exists
            ? "已加入 \(p)"
            : "已加入 \(p)，但当前读不到（越狱目录需要越狱设备，或路径不存在）"
        st.log("宿主", "新增自定义路径 \(p) exists=\(exists)")
    }
}

/// PC 节点上的授权根 —— 原来 HostPanel 的主体搬到这里。
/// 入口：「宿主访问 → PC 节点 → 节点授权根」。
/// 跟本机宿主访问完全是两套东西：这里授权的是**电脑上**的目录。
struct NodeHostPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var newPath = ""
    @State private var browsePath = ""
    @State private var listing: [String] = []
    @State private var busy = false
    @State private var msg = ""

    var body: some View {
        PanelShell(title: "节点授权根", sub: "授权根写在节点侧；这里只是决定 AI 能不能用") {
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
    @ObservedObject private var rt = LinuxRuntime.shared

    @State private var editWorkdir = false
    @State private var editMaxLines = false

    var body: some View {
        PanelShell(title: "终端") {

            // ===== 权限档位 =====
            SectionTitle(text: "权限档位")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    RadioRow(color: T.accent, symbol: "person.fill",
                             title: "App 原生权限",
                             sub: "以当前应用身份运行，只能访问沙盒与已挂载的目录。最安全。",
                             selected: st.execIdentity == "user") {
                        st.execIdentity = "user"
                    }
                    RowDivider()
                    RadioRow(color: T.orange, symbol: "person.fill",
                             title: "iSH Root",
                             sub: "在 iSH 模拟环境中以 root 运行，可读写整个 Alpine 根文件系统；对读写挂载的宿主目录同样可写。",
                             selected: st.execIdentity == "admin") {
                        st.execIdentity = "admin"
                    }
                    RowDivider()
                    RadioRow(color: T.purple, symbol: "crown.fill",
                             title: "系统 Root（实验性）",
                             sub: "尝试通过越狱环境获取真实 iOS root，可访问沙盒外的系统路径。依赖平台签名标志，可能失败。",
                             selected: st.execIdentity == "system") {
                        st.execIdentity = "system"
                    }
                }
                .frame(maxWidth: .infinity)
            }
            SectionFootnote(text: "控制终端命令以什么身份执行。系统 Root 依赖越狱环境的平台签名标志，若不可用会自动回落到 iSH Root。")

            // ===== AI 联动 =====
            SectionTitle(text: "AI 联动")
            Card(padding: 0) {
                IconToggleRow(color: T.accent, symbol: "sparkles",
                              title: "允许 AI 调用终端",
                              sub: "开启后 AI 可通过 shell_execute 执行命令",
                              on: $st.allowExec)
            }
            SectionFootnote(text: "AI 执行的命令使用与上方相同的权限档位。关闭后 AI 将无法执行任何 shell 命令。")

            // ===== 行为 =====
            SectionTitle(text: "行为")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ValueRow(title: "工作目录", value: st.execWorkdir, editable: true) {
                        editWorkdir = true
                    }
                    RowDivider()
                    ValueRow(title: "输出上限", value: "\(st.execMaxLines) 行", editable: true) {
                        editMaxLines = true
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // ===== 当前状态 =====
            SectionTitle(text: "当前状态")
            Card {
                VStack(alignment: .leading, spacing: 3) {
                    statusLine("终端权限档位", identityLabel)
                    statusLine("AI 终端调用", st.allowExec ? "已开启" : "已关闭")
                    statusLine("工作目录", st.execWorkdir)
                    statusLine("输出上限", "\(st.execMaxLines) 行")
                    statusLine("内核状态", rt.stage.label)
                    statusLine("iSH 内核", String(cString: npc_linux_version()))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 内核报错原文：启动失败时这里是唯一能定位问题的东西，
                // 直接把这段截图就能看出卡在哪一步、errno 是多少。
                if !kernelErr.isEmpty {
                    Divider().overlay(T.line)
                    Text(kernelErr)
                        .font(T.mono(9.5)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // ===== 说明 =====
            SectionTitle(text: "说明")
            Card {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12)).foregroundColor(T.txt3)
                    Text("iSH 是用户态模拟环境。iSH Root 对 Alpine 根文件系统是完全权限，但跨出模拟环境后仍受 iOS 沙盒限制 —— 那是内核强制的，绕不过去。系统 Root 只在越狱设备上才有意义，靠平台签名标志探测，不可靠时会自动回落到 iSH Root。")
                        .font(.system(size: 11)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // ===== 节点命令（原执行面板搬去子页，主页面保持干净）=====
            SectionTitle(text: "节点命令")
            Card(padding: 0) {
                NavigationLink { NodeShellPanel() } label: {
                    NavRow(color: Color(white: 0.55), glyph: "$", title: "在 PC 节点上执行",
                           sub: "走算力节点的 shell，跟本机 iSH 终端是两套东西")
                }.buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $editWorkdir) {
            PromptSheet(title: "工作目录",
                        hint: "终端会话的初始目录，必须存在于 Alpine 里（例如 /root、/home、/tmp）",
                        placeholder: "/root",
                        initial: st.execWorkdir) { v in
                let t = v.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { st.execWorkdir = t }
            }
        }
        .sheet(isPresented: $editMaxLines) {
            PromptSheet(title: "输出上限",
                        hint: "单次命令最多保留多少行回显（100 - 20000）",
                        placeholder: "2000",
                        initial: "\(st.execMaxLines)") { v in
                if let n = Int(v.trimmingCharacters(in: .whitespaces)), n > 0 {
                    st.execMaxLines = min(max(n, 100), 20000)
                }
            }
        }
    }

    private var identityLabel: String {
        switch st.execIdentity {
        case "admin":  return "iSH Root"
        case "system": return "系统 Root（实验性）"
        default:       return "App 原生权限"
        }
    }

    /// 内核最后一次报错（npc_linux_last_error 是 C 字符串，可能为空串）
    private var kernelErr: String {
        String(cString: npc_linux_last_error())
    }

    private func statusLine(_ k: String, _ v: String) -> some View {
        HStack(spacing: 0) {
            Text("\(k)：").foregroundColor(T.txt3)
            Text(v).foregroundColor(T.txt2)
        }
        .font(T.mono(10.5))
    }
}

/// 节点命令：在 PC 节点上跑 shell。原来的 TermPanel 主体搬到这里，
/// 入口在「终端 → 节点命令」。跟本机 iSH 终端是两条完全不同的链路。
struct NodeShellPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub

    @State private var cmd = ""
    @State private var out = ""
    @State private var exit = 0
    @State private var busy = false
    @State private var history: [String] = []

    var body: some View {
        PanelShell(title: "节点命令", sub: "命令在节点上执行；身份决定它有没有管理员权限") {
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
                    Text("未授权执行：设置 → 终端 → 允许 AI 调用终端")
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
