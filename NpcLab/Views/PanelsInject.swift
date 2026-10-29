//
//  PanelsInject.swift
//  NpcLab
//
//  目标应用动态注入 + Frida hook + 日志 —— 对齐 AzTuT 的 FridaAppsView /
//  InjectPanelView / InjectLogViewer。
//

import SwiftUI

struct InjectPanel: View {
    @ObservedObject private var eng = InjectEngine.shared
    @ObservedObject private var rt = LinuxRuntime.shared

    @State private var showHookEditor = false
    @State private var draftHook = FridaHook()

    var body: some View {
        PanelShell(title: "动态注入",
                   sub: "在本机 Alpine 里跑 frida，hook 目标 App —— 对齐 AzTuT") {

            // 状态
            Card {
                HStack(spacing: 8) {
                    Circle().fill(rt.stage.isReady ? T.green : T.txt3).frame(width: 6, height: 6)
                    Text(rt.stage.isReady ? "Linux 就绪" : "Linux 未启动")
                        .font(T.mono(11)).foregroundColor(T.txt2)
                    Spacer()
                    Text("\(eng.targets.count) 进程 · \(eng.hooks.count) hook")
                        .font(T.mono(10)).foregroundColor(T.txt3)
                }
                if eng.busy {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(eng.status).font(.system(size: 11)).foregroundColor(T.txt3)
                    }
                }
                if !eng.status.isEmpty && !eng.busy {
                    Text(eng.status).font(T.mono(10)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !rt.stage.isReady {
                    Text("先到「终端」页把 Linux 启起来，注入和 hook 才有环境可跑。")
                        .font(.system(size: 10.5)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 目标列表
            SectionTitle(text: "可注入 App \(eng.targets.count)")
            Card {
                if eng.targets.isEmpty {
                    Text("还没有扫到进程。点下面「扫描」列出本机 App。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                }
                ForEach(eng.targets) { t in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.system(size: 12.5)).foregroundColor(T.txt)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(t.bundleId)  ·  pid \(t.pid)")
                                .font(T.mono(9)).foregroundColor(T.txt3).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            eng.applyHooks(to: t.bundleId, pid: t.pid)
                        } label: {
                            Text("Hook").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(T.accent).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(eng.hooks.isEmpty)
                    }
                    .padding(.vertical, 3)
                }
                HStack(spacing: 8) {
                    Button {
                        eng.scan()
                    } label: {
                        Label("扫描", systemImage: "arrow.clockwise")
                            .font(.system(size: 12.5)).foregroundColor(T.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }

            // Hook 规则
            SectionTitle(text: "Hook 规则 \(eng.hooks.count)")
            Card {
                if eng.hooks.isEmpty {
                    Text("没有 hook 规则。规则 = 类名 + 方法名 + 类型，对齐 AzTuT 的六类：logMethod / returnConstant / blockMethod / modifyProperty / flexOverride / methodSwizzle。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(eng.hooks) { h in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(h.isClassMethod ? "+" : "-")[\(h.className) \(h.methodName)]")
                                .font(T.mono(10.5)).foregroundColor(T.txt).lineLimit(1)
                            HStack(spacing: 4) {
                                Pill(text: h.hookType.rawValue, color: hookColor(h.hookType))
                                if !h.returnValue.isEmpty {
                                    Text("→ \(h.returnValue)").font(T.mono(9)).foregroundColor(T.txt3)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            eng.hooks.removeAll { $0.id == h.id }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                                .foregroundColor(T.red.opacity(0.8))
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                }
                Button {
                    draftHook = FridaHook()
                    showHookEditor = true
                } label: {
                    Label("新增 hook", systemImage: "plus.circle")
                        .font(.system(size: 12.5)).foregroundColor(T.accent)
                }.buttonStyle(.plain)
            }

            // 日志
            SectionTitle(text: "注入日志 \(eng.logs.count)")
            Card {
                if eng.logs.isEmpty {
                    Text("还没有日志。hook 命中、注入结果都会记录在这里。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(eng.logs.reversed()) { l in
                            HStack(alignment: .top, spacing: 6) {
                                Text(hhmmss(l.ts)).font(T.mono(9)).foregroundColor(T.txt3)
                                Text(l.level).font(T.mono(9, .bold)).foregroundColor(levelColor(l.level))
                                Text(l.text).font(T.mono(10)).foregroundColor(T.txt2)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
                .frame(maxHeight: 220)
                Button {
                    eng.clearLogs()
                } label: {
                    Text("清空日志").font(.system(size: 12)).foregroundColor(T.accent)
                }.buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showHookEditor) {
            HookEditor(hook: draftHook) { h in
                eng.hooks.append(h)
            }
        }
        .onAppear { eng.scan() }
    }

    private func hookColor(_ t: FridaHookType) -> Color {
        switch t {
        case .logMethod: return T.teal
        case .returnConstant: return T.orange
        case .blockMethod: return T.red
        case .modifyProperty: return T.purple
        case .flexOverride: return T.accent
        case .methodSwizzle: return T.green
        }
    }

    private func levelColor(_ l: String) -> Color {
        switch l {
        case "hook": return T.purple
        case "error": return T.red
        default: return T.green
        }
    }
}

// MARK: - Hook 编辑器

struct HookEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hook: FridaHook
    let onSave: (FridaHook) -> Void

    init(hook: FridaHook, onSave: @escaping (FridaHook) -> Void) {
        _hook = State(initialValue: hook)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section("类与方法") {
                    TextField("类名（如 UIViewController）", text: $hook.className)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("方法名（如 viewDidLoad）", text: $hook.methodName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Toggle("类方法（+）", isOn: $hook.isClassMethod)
                }
                Section("Hook 类型") {
                    Picker("类型", selection: $hook.hookType) {
                        ForEach(FridaHookType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                }
                if hook.hookType == .returnConstant || hook.hookType == .flexOverride {
                    Section("返回值") {
                        TextField("返回值（如 0 或 true）", text: $hook.returnValue)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                if hook.hookType == .modifyProperty {
                    Section("属性") {
                        TextField("属性名", text: $hook.property)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle("Hook 规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(hook)
                        dismiss()
                    }
                    .disabled(hook.className.isEmpty || hook.methodName.isEmpty)
                }
            }
        }
    }
}
