//
//  TerminalView.swift
//  NpcLab
//
//  终端页。不追求 xterm 那种光标定位仿真——vi/top 这类全屏程序在这里会花屏，
//  但 ls / cat / apk / grep / python 这些行式输出完全正常。
//  真要全屏支持，得把 xterm.js 塞进 WKWebView，那是另一件事。
//

import SwiftUI

struct TerminalView: View {
    @ObservedObject private var rt = LinuxRuntime.shared
    @State private var input = ""
    @State private var showHelp = false
    @FocusState private var focused: Bool

    private let quick: [(String, String)] = [
        ("系统", "uname -a"),
        ("发行版", "cat /etc/os-release"),
        ("磁盘", "df -h"),
        ("进程", "ps aux"),
        ("包", "apk info | head -30"),
        ("网络", "ip addr"),
    ]

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                Divider().overlay(T.line)
                console
                quickBar
                Divider().overlay(T.line)
                inputBar
            }
        }
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { rt.clear() } label: { Label("清屏", systemImage: "trash") }
                    Button { showHelp = true } label: { Label("说明", systemImage: "questionmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showHelp) { helpSheet }
        // npclab-open / xdg-open 发上来的 OSC 1337 请求在这里落地
        .sheet(item: $rt.openRequest) { req in
            OpenSheet(req: req)
        }
        .onAppear { rt.bootIfNeeded() }
    }

    // MARK: 状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(rt.stage.label)
                .font(T.mono(11.5))
                .foregroundColor(T.txt2)
            Spacer()
            if case .unpacking(let p) = rt.stage {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                    .tint(T.teal)
            }
            if rt.busy {
                ProgressView().scaleEffect(0.6)
            }
            Text("Linux")
                .font(T.mono(10))
                .foregroundColor(T.txt3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(T.bg2)
    }

    private var dotColor: Color {
        switch rt.stage {
        case .ready:        return T.green
        case .failed:       return T.red
        case .idle:         return T.txt3
        default:            return T.orange
        }
    }

    // MARK: 输出区

    private var console: some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1.5) {
                    ForEach(rt.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(red: 0.035, green: 0.038, blue: 0.05))
            .onChange(of: rt.lines.count) { _ in
                withAnimation(.linear(duration: 0.08)) {
                    sp.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onTapGesture { focused = false }
        }
    }

    private func color(_ k: TermLine.Kind) -> Color {
        switch k {
        case .out:     return Color(red: 0.86, green: 0.90, blue: 0.92)
        case .system:  return T.teal
        case .command: return T.green
        case .error:   return T.red
        }
    }

    // MARK: 快捷命令

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(quick, id: \.1) { item in
                    Button {
                        rt.runInTerminal(item.1)
                    } label: {
                        Text(item.0)
                            .font(.system(size: 11.5))
                            .foregroundColor(T.txt2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(T.card)
                                    .overlay(Capsule().stroke(T.line, lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!rt.stage.isReady)
                    .opacity(rt.stage.isReady ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(T.bg2)
    }

    // MARK: 输入行

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundColor(T.green)

            TextField("", text: $input)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(T.txt)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit(sendInput)

            Button(action: sendInput) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(input.isEmpty ? T.txt3 : T.accent)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty || !rt.stage.isReady)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(T.bg2)
    }

    private func sendInput() {
        let c = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, rt.stage.isReady else { return }
        input = ""
        rt.runInTerminal(c)
    }

    // MARK: 说明

    private var helpSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("这是什么").font(.system(size: 15, weight: .semibold)).foregroundColor(T.txt)
                    Text("""
                    一个真正跑在 iPhone 上的 Alpine Linux。不是远程连服务器，\
                    也不是调外部进程——内核和应用模拟器都在这个 App 里。
                    """)
                    .font(.system(size: 13)).foregroundColor(T.txt2)

                    Text("能干什么").font(.system(size: 15, weight: .semibold)).foregroundColor(T.txt)
                    Text("""
                    · 完整的 POSIX 环境：sh、busybox、python3、apk
                    · 读写 App 沙箱内的文件
                    · 跑脚本、编小工具、做文本处理
                    """)
                    .font(.system(size: 13)).foregroundColor(T.txt2)

                    Text("不能干什么").font(.system(size: 15, weight: .semibold)).foregroundColor(T.txt)
                    Text("""
                    · vi / top / less 这类全屏程序会花屏（这里没有完整 VT100 光标定位）
                    · 不能访问系统目录、不能提权、不能碰别的 App
                    · 联网要走 App 的沙箱权限，不是真网卡
                    """)
                    .font(.system(size: 13)).foregroundColor(T.txt2)

                    Text("第一次启动").font(.system(size: 15, weight: .semibold)).foregroundColor(T.txt)
                    Text("解压 139MB 的 rootfs，大概 10–20 秒，之后每次秒开。")
                        .font(.system(size: 13)).foregroundColor(T.txt2)
                }
                .padding(18)
            }
            .background(T.bg.ignoresSafeArea())
            .navigationTitle("关于终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { showHelp = false }
                }
            }
        }
    }
}
