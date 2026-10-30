//
//  PanelsRevLocal.swift
//  NpcLab
//
//  逆向分析的本机模式：目标是 App 内置 Alpine 里的一个路径，
//  radare2 也在里面跑，全程不碰网络、不需要 PC 节点。
//

import SwiftUI
import UniformTypeIdentifiers

/// 入口：设置 → 逆向分析。
///
/// 布局对齐 AzTuT 的「逆向分析」设置页：四个区块（目标应用 / 深度分析 /
/// 辅助工具 / 工具链状态），每个区块下面跟一段灰色说明文字。
///
/// 跟 AzTuT 的唯一差别：它的「目标 App 管理」点进去就是任务列表，我们这里
/// 还要再区分「解析跑在 PC 节点还是本机」——小徐TuT 有节点模式，不能因为套了
/// 层 UI 就丢掉。那一层放在 RevWorkspace 里。
struct RevPanel: View {
    @EnvironmentObject var st: AppSettings
    @ObservedObject private var eng = RevLocal.shared
    @ObservedObject private var inv = AppInventory.shared

    var body: some View {
        PanelShell(title: "逆向分析") {

            // ===== 目标应用 =====
            SectionTitle(text: "目标应用")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { RevWorkspace() } label: {
                        NavRow(color: T.accent, symbol: "square.grid.2x2",
                               title: "目标 App 管理")
                    }.buttonStyle(.plain)

                    RowDivider()

                    NavigationLink { LogsPanel() } label: {
                        NavRow(color: T.teal, symbol: "doc.text.magnifyingglass",
                               title: "动态注入日志")
                    }.buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
            }
            SectionFootnote(text: "枚举本机已安装的 App，查看 Bundle 与数据容器，把主二进制或任意文件复制到沙盒，交给 AI 用 strings / radare2 做静态分析。")

            // ===== 深度分析 =====
            SectionTitle(text: "深度分析")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    IconToggleRow(color: T.accent, glyph: "r2", title: "radare2 反汇编",
                                  sub: "函数识别、交叉调用、字符串提取（AI 可调用 r2_execute）",
                                  on: $st.revR2)
                    RowDivider()
                    IconToggleRow(color: T.purple, glyph: "gh", title: "r2ghidra 伪代码",
                                  sub: "输出函数级 C 伪代码，读懂逻辑最快的方式",
                                  on: $st.revGhidra)
                }
                .frame(maxWidth: .infinity)
            }
            SectionFootnote(text: "开启后 AI 获得 r2_execute 工具：可对二进制做函数识别、交叉引用与字符串提取。r2ghidra 插件还能输出函数级 C 伪代码。关闭时 AI 只用 App 原生的 strings / hexdump 做轻量分析，零开销。")

            // ===== 辅助工具 =====
            SectionTitle(text: "辅助工具")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    IconToggleRow(color: T.orange, glyph: "cs", title: "capstone 指令引擎",
                                  sub: "脚本内做指令级反汇编解析",
                                  on: $st.revCapstone)
                    RowDivider()
                    IconToggleRow(color: T.teal, symbol: "snowflake", title: "binutils 工具集",
                                  sub: "nm / objdump / readelf / strings 符号与结构",
                                  on: $st.revBinutils)
                    RowDivider()
                    IconToggleRow(color: Color(red: 0.35, green: 0.62, blue: 0.95),
                                  symbol: "cylinder.split.1x2",
                                  title: "文件与数据库识别",
                                  sub: "file 类型识别、sqlite3 读目标 App 数据库",
                                  on: $st.revFileDb)
                }
                .frame(maxWidth: .infinity)
            }
            SectionFootnote(text: "工具链已内置在 App 中，离线可用，切换开关即即时生效，无需联网或安装。")

            // ===== 工具链状态 =====
            SectionTitle(text: "工具链状态")
            Card(padding: 0) {
                Button { eng.probe() } label: {
                    NavRow(color: T.teal, symbol: "checkmark.shield",
                           title: "检测已内置工具",
                           sub: statusLine)
                }.buttonStyle(.plain)
            }
            SectionFootnote(text: "radare2、capstone、binutils、file、sqlite3 与 r2ghidra 均随 App 内置，无需安装。此按钮做一次只读探测，用于确认版本是否正确。")
        }
        .onAppear {
            if inv.apps.isEmpty { inv.scanHost() }
        }
    }

    /// 「检测已内置工具」那行的副标题：探测中 / 已就绪带版本 / 未启动原因
    private var statusLine: String {
        if eng.busy { return eng.status.isEmpty ? "探测中…" : eng.status }
        if eng.r2Ready { return eng.r2Version.isEmpty ? "已就绪" : eng.r2Version }
        if !eng.r2Version.isEmpty { return eng.r2Version }
        return "点一下确认 radare2 / r2ghidra 版本"
    }
}

/// 分析工作区：先选解析跑在哪（PC 节点 / 本机 radare2），再进对应的任务列表。
/// 这一层是原来的 RevPanel 主体，只是去掉了自己的导航壳（外面已经有一层）。
struct RevWorkspace: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub
    @State private var local = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $local) {
                Text("PC 节点").tag(false)
                Text("本机 radare2").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            if local {
                LocalRevView()
            } else {
                NodeRevView()
            }
        }
        .background(Backdrop())
        .onAppear {
            // 默认走节点（对齐 AzTuT）；只有节点明确离线时才落到本机降级，
            // 而不是反过来「默认本机、连上才切节点」。
            local = !(st.bridgeOn && hub.state.online)
        }
    }
}

// MARK: - 本机模式

struct LocalRevView: View {

    @ObservedObject private var eng = RevLocal.shared
    @ObservedObject private var rt = LinuxRuntime.shared
    @ObservedObject private var inv = AppInventory.shared

    @State private var addPath = ""
    @State private var showPicker = false
    @State private var hint = ""
    @State private var showAppList = false
    @State private var importingApp: InstalledApp? = nil

    var body: some View {
        PanelShell(title: "逆向分析",
                   sub: "在 App 内置的 Alpine 里跑 radare2，不连网、不需要节点") {

            statusCard

            SectionTitle(text: "目标 \(eng.targets.count)")
            Card {
                if eng.targets.isEmpty {
                    Text("还没有目标。可以从文件导入一个二进制，或者直接填 guest 里的路径（例如 /usr/bin/python3.12）。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(eng.targets) { t in
                    Button {
                        eng.analyze(t)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: eng.current?.id == t.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(eng.current?.id == t.id ? T.accent : T.txt3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.label.isEmpty ? t.path : t.label)
                                    .font(.system(size: 12.5)).foregroundColor(T.txt)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 5) {
                                    if !t.arch.isEmpty { Pill(text: t.arch, color: T.purple) }
                                    if !t.size.isEmpty {
                                        Text(t.size).font(T.mono(9)).foregroundColor(T.txt3)
                                    }
                                    Text(t.path).font(T.mono(9)).foregroundColor(T.txt3)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button {
                                eng.remove(t)
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
                    TextField("guest 里的路径", text: $addPath)
                        .font(T.mono(11))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .glass(8)
                    Button {
                        let p = addPath.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty else { return }
                        eng.addGuestPath(p)
                        addPath = ""
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white).frame(width: 30, height: 30)
                            .background(T.accent).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showPicker = true
                } label: {
                    Label("从文件导入（≤32MB）", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12.5)).foregroundColor(T.accent)
                }
                .buttonStyle(.plain)

                Divider().opacity(0.4).padding(.vertical, 4)

                // 已安装 App（对齐 AzTuT 的「逆向分析的目标应用」）
                Button {
                    showAppList = true
                } label: {
                    HStack {
                        Label("已安装 App（选目标）", systemImage: "apps.iphone")
                            .font(.system(size: 12.5)).foregroundColor(T.accent)
                        Spacer()
                        Text("\(inv.apps.count)").font(T.mono(10)).foregroundColor(T.txt3)
                    }
                }
                .buttonStyle(.plain)

                if !inv.apps.isEmpty {
                    ForEach(inv.apps.prefix(6)) { app in
                        Button {
                            importingApp = app
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.system(size: 12))
                                        .foregroundColor(T.txt).lineLimit(1)
                                    Text(app.bundleId).font(T.mono(8.5))
                                        .foregroundColor(T.txt3).lineLimit(1)
                                }
                                Spacer()
                                if !app.binaryPath.isEmpty {
                                    Image(systemName: "doc.badge.plus")
                                        .font(.system(size: 11)).foregroundColor(T.teal)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                    if inv.apps.count > 6 {
                        Text("还有 \(inv.apps.count - 6) 个，展开后可选")
                            .font(.system(size: 9.5)).foregroundColor(T.txt3)
                    }
                }

                if !inv.status.isEmpty {
                    Text(inv.status).font(T.mono(9)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !hint.isEmpty {
                    Text(hint).font(T.mono(10)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if eng.busy {
                Card {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(eng.status.isEmpty ? "处理中…" : eng.status)
                            .font(.system(size: 11)).foregroundColor(T.txt3)
                            .lineLimit(2)
                    }
                    if eng.progress > 0 {
                        ProgressView(value: eng.progress).tint(T.teal)
                        Text("\(Int(eng.progress * 100))%")
                            .font(T.mono(9)).foregroundColor(T.txt3)
                    }
                }
            } else if !eng.status.isEmpty {
                Text(eng.status).font(T.mono(10)).foregroundColor(T.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !eng.funcs.isEmpty {
                SectionTitle(text: "函数 \(eng.funcs.count) · 点一条出伪代码")
                Card {
                    ForEach(Array(eng.funcs.prefix(200))) { f in
                        Button {
                            eng.decompile(f)
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
                    if eng.funcs.count > 200 {
                        Text("只列前 200 条").font(.system(size: 10)).foregroundColor(T.txt3)
                    }
                }
            }

            // 深度分析辅助工具（对齐 AzTuT 的 binutils_query / file_query / capstone）
            if let cur = eng.current {
                SectionTitle(text: "辅助工具 · \(cur.label.isEmpty ? cur.path : cur.label)")
                Card {
                    HStack(spacing: 6) {
                        toolBtn("file", "文件识别") { eng.fileQuery(cur) }
                        toolBtn("llvm-otool", "头部/段") { eng.binutilsQuery(cur, tool: "headers") }
                        toolBtn("依赖", "依赖库") { eng.binutilsQuery(cur, tool: "deps") }
                        toolBtn("objc", "类列表") { eng.binutilsQuery(cur, tool: "objc") }
                    }
                    HStack(spacing: 6) {
                        toolBtn("符号", "符号表") { eng.binutilsQuery(cur, tool: "symbols") }
                        toolBtn("strings", "字符串") { eng.binutilsQuery(cur, tool: "strings") }
                        toolBtn("capstone", "反汇编") { eng.capstoneDisasm(cur) }
                    }
                    Text("capstone 指令级反汇编需 rootfs 带 py3-capstone；llvm-otool 需 llvm。")
                        .font(.system(size: 10)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !eng.pseudo.isEmpty {
                SectionTitle(text: eng.pseudoEngine.isEmpty
                             ? "伪代码" : "伪代码 · \(eng.pseudoEngine)")
                Card {
                    HStack {
                        Text(eng.pseudoEngine.isEmpty ? "r2" : eng.pseudoEngine)
                            .font(T.mono(10)).foregroundColor(T.txt3)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = eng.pseudo
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.system(size: 11)).foregroundColor(T.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(eng.pseudo).font(T.mono(10))
                        .foregroundColor(Color(red: 0.80, green: 0.88, blue: 0.95))
                        .textSelection(.enabled)
                }
            }
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let u = urls.first else { return }
                hint = ""
                eng.importFile(u)
            case .failure(let e):
                hint = "选文件失败：\(e.localizedDescription)"
            }
        }
        .sheet(isPresented: $showAppList) {
            AppListSheet { app in
                importingApp = app
                showAppList = false
            }
        }
        .onChange(of: importingApp) { app in
            guard let app = app else { return }
            importAppIntoGuest(app)
        }
        .onAppear {
            eng.probe()
            if inv.apps.isEmpty { inv.scanHost() }
        }
    }

    /// 把目标 App 主二进制拉进 guest，然后当逆向目标载入
    private func importAppIntoGuest(_ app: InstalledApp) {
        guard rt.stage.isReady else {
            hint = "先到「终端」页把 Linux 启起来，才能拉目标 App 二进制"
            return
        }
        hint = ""
        Task {
            guard let guestPath = await inv.importAppBinary(app) else {
                await MainActor.run {
                    hint = "读不到 \(app.binaryPath)（本机沙箱非越狱时，需先在终端挂宿主文件系统）"
                    self.importingApp = nil
                }
                return
            }
            // 送进 guest 后，按 guest 路径加进逆向目标并直接分析
            await MainActor.run {
                self.importingApp = nil
            }
            eng.addGuestPath(guestPath)
        }
    }

    private func toolBtn(_ glyph: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: glyph).font(.system(size: 12)).foregroundColor(T.accent)
                Text(label).font(.system(size: 9)).foregroundColor(T.txt2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(T.cardHi).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 8) {
                Circle().fill(eng.r2Ready ? T.green : T.txt3).frame(width: 6, height: 6)
                Text(eng.r2Ready ? "radare2 就绪" : (rt.stage.isReady ? "检查中…" : "Linux 未启动"))
                    .font(T.mono(11)).foregroundColor(T.txt2)
                Spacer()
                Button {
                    eng.probe()
                } label: {
                    Text("刷新").font(.system(size: 11.5)).foregroundColor(T.accent)
                }
                .buttonStyle(.plain)
            }
            if !eng.r2Version.isEmpty {
                Text(eng.r2Version).font(T.mono(10)).foregroundColor(T.txt3)
            }
            Text("引擎：pdg（r2ghidra）→ pdc → pdf 自动降级。全程在本机 Alpine 里跑，不出网。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)
                .fixedSize(horizontal: false, vertical: true)
            if !rt.stage.isReady {
                Text("先到「终端」页把 Linux 启起来，这里才有东西可跑。")
                    .font(.system(size: 10.5)).foregroundColor(T.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 已安装 App 选择器

/// 列出本机已安装 App，点选后回调，供逆向分析当作目标。
struct AppListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var inv = AppInventory.shared

    let onSelect: (InstalledApp) -> Void

    var body: some View {
        NavigationView {
            Group {
                if inv.apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "apps.iphone").font(.system(size: 34))
                            .foregroundColor(T.txt3)
                        Text(inv.status.isEmpty ? "还没枚举到 App" : inv.status)
                            .font(.system(size: 12)).foregroundColor(T.txt2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            inv.scanHost()
                        } label: {
                            Label("重新扫描", systemImage: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundColor(T.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(24)
                } else {
                    List(inv.apps) { app in
                        Button {
                            onSelect(app)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.system(size: 14))
                                    .foregroundColor(T.txt)
                                Text(app.bundleId).font(T.mono(9))
                                    .foregroundColor(T.txt3).lineLimit(1)
                                if !app.executable.isEmpty {
                                    Text("可执行文件：\(app.executable)")
                                        .font(T.mono(9)).foregroundColor(T.teal)
                                }
                                if !app.dataContainer.isEmpty {
                                    Text("数据容器：\(app.dataContainer)")
                                        .font(T.mono(8.5)).foregroundColor(T.txt3)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Backdrop())
            .navigationTitle("已安装 App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        inv.scanHost()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
