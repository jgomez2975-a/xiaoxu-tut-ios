//
//  PanelsRevLocal.swift
//  NpcLab
//
//  逆向分析的本机模式：目标是 App 内置 Alpine 里的一个路径，
//  radare2 也在里面跑，全程不碰网络、不需要 PC 节点。
//

import SwiftUI
import UniformTypeIdentifiers

/// 入口：本机 / 节点 两种模式共用一个页面。
/// 对齐 AzTuT：默认走 PC 节点（节点端 rev.py 跑 radare2 6.2.4 + r2ghidra，
/// 伪代码是 ghidra 级的）；本机 radare2 只是节点连不上时的降级。
struct RevPanel: View {
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

    @State private var addPath = ""
    @State private var showPicker = false
    @State private var hint = ""

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
        .onAppear { eng.probe() }
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
