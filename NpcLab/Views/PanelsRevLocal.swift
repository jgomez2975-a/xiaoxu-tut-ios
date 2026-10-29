//
//  PanelsRevLocal.swift
//  NpcLab
//
//  逆向分析的本机模式：目标是 App 内置 Alpine 里的一个路径，
//  radare2 也在里面跑，全程不碰网络、不需要 PC 节点。
//

import SwiftUI
import UniformTypeIdentifiers

/// 入口：本机 / 节点 两种模式共用一个页面
struct RevPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub
    @State private var local = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $local) {
                Text("本机 radare2").tag(true)
                Text("PC 节点").tag(false)
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
            // 没配节点就直接落在本机模式，别一进来就是「节点未就绪」
            if !st.bridgeOn || !hub.state.online {
                local = true
            } else {
                local = false
            }
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
