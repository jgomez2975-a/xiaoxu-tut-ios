//
//  PanelsProxyLocal.swift
//  NpcLab
//
//  抓包与改写 · 本机模式。代理跑在 App 进程里，规则也在这里执行。
//

import SwiftUI

struct ProxyPanel: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub
    @State private var local = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $local) {
                Text("PC 节点").tag(false)
                Text("本机代理").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            if local {
                LocalProxyPanel()
            } else {
                NodeProxyPanel()
            }
        }
        .background(Backdrop())
        .onAppear {
            // 默认走节点（对齐 AzTuT：节点端 proxy.py 是真 MITM，能解密 HTTPS）；
            // 只有节点明确离线时才落到本机 HTTP 明文代理降级。
            local = !(st.bridgeOn && hub.state.online)
        }
    }
}

struct LocalProxyPanel: View {

    @EnvironmentObject var st: AppSettings
    @ObservedObject private var px = LocalProxy.shared
    @ObservedObject private var mitm = MITMInterceptor.shared

    @State private var port = "8888"
    @State private var showEditor = false
    @State private var draft = ProxyRule()
    @State private var hint = ""

    var body: some View {
        PanelShell(title: "抓包与改写",
                   sub: "代理就在这个 App 里跑；手机把 HTTP 代理指到 127.0.0.1 即可") {

            Card {
                HStack(spacing: 8) {
                    Circle().fill(px.running ? T.green : T.txt3).frame(width: 6, height: 6)
                    Text(px.running ? "运行中 · :\(String(px.port))" : "未启动")
                        .font(T.mono(11)).foregroundColor(T.txt2)
                    Spacer()
                    Text("\(px.hits.count) 条").font(T.mono(10)).foregroundColor(T.txt3)
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
                        Text(px.running ? "停止" : "启动")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(st.allowProxy ? (px.running ? T.red : T.green) : T.card)
                            .foregroundColor(st.allowProxy ? .white : T.txt3)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!st.allowProxy)

                    Button {
                        px.clear()
                    } label: {
                        Text("清空").font(.system(size: 12))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if !st.allowProxy {
                    Text("未授权：设置 → 权限 → 抓包代理")
                        .font(.system(size: 10.5)).foregroundColor(T.orange)
                }
                if !px.lastError.isEmpty {
                    Text(px.lastError).font(T.mono(10)).foregroundColor(T.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hint.isEmpty {
                    Text(hint).font(T.mono(10)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionTitle(text: "手机上怎么指过来")
            Card {
                Text("设置 → 无线局域网 → 当前网络右边的 ⓘ → 配置代理 → 手动")
                    .font(.system(size: 11.5)).foregroundColor(T.txt2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("服务器").font(.system(size: 11.5)).foregroundColor(T.txt3)
                    Text("127.0.0.1").font(T.mono(11)).foregroundColor(T.txt)
                    Text("端口").font(.system(size: 11.5)).foregroundColor(T.txt3)
                    Text(px.running ? "\(px.port)" : port).font(T.mono(11)).foregroundColor(T.txt)
                    Spacer()
                }
                Text("""
                · HTTP 明文：完整抓取，能改头、改正文
                · HTTPS：真 MITM 解密（内置自签 CA + URLProtocol 拦截），明文可见、可改写
                · 别的设备想抓：把服务器填成这台手机的局域网 IP
                """)
                .font(.system(size: 10.5)).foregroundColor(T.txt3)
                .fixedSize(horizontal: false, vertical: true)
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
                    showEditor = true
                } label: {
                    Label("新增规则", systemImage: "plus.circle")
                        .font(.system(size: 12.5)).foregroundColor(T.accent)
                }
                .buttonStyle(.plain)
            }

            if !px.hits.isEmpty {
                SectionTitle(text: "会话 \(px.hits.count)")
                Card {
                    ForEach(px.hits.reversed()) { h in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(h.method)
                                    .font(T.mono(9.5, .bold))
                                    .foregroundColor(h.tunnel ? T.purple : T.accent)
                                Text("\(h.status)")
                                    .font(T.mono(9.5))
                                    .foregroundColor(h.status >= 400 || h.status == 0 ? T.red : T.green)
                                Text(byteText(h.bytes))
                                    .font(T.mono(9)).foregroundColor(T.txt3)
                                Text("\(h.ms)ms")
                                    .font(T.mono(9)).foregroundColor(T.txt3)
                                Spacer()
                                if !h.hits.isEmpty {
                                    Pill(text: "改写 ×\(h.hits.count)", color: T.teal)
                                }
                            }
                            Text(h.url)
                                .font(T.mono(9.5)).foregroundColor(T.txt2)
                                .lineLimit(2).truncationMode(.middle)
                            if !h.note.isEmpty {
                                Text(h.note).font(T.mono(9)).foregroundColor(T.txt3)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            // MITM 明文流（对齐 AzTuT 的 CapturedFlow —— 真 HTTPS 解密后的明文）
            if !mitm.flows.isEmpty {
                SectionTitle(text: "MITM 明文流 \(mitm.flows.count)")
                Card {
                    ForEach(mitm.flows.reversed()) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(f.method)
                                    .font(T.mono(9.5, .bold)).foregroundColor(T.accent)
                                Text("\(f.status)")
                                    .font(T.mono(9.5))
                                    .foregroundColor(f.status >= 400 || f.status == 0 ? T.red : T.green)
                                if f.https {
                                    Pill(text: "https", color: T.teal)
                                }
                                if f.modified {
                                    Pill(text: "已改写", color: T.orange)
                                }
                                Spacer()
                                Text(hhmmss(f.ts)).font(T.mono(9)).foregroundColor(T.txt3)
                            }
                            Text(f.url).font(T.mono(9.5)).foregroundColor(T.txt2)
                                .lineLimit(2).truncationMode(.middle)
                            if !f.reqBody.isEmpty {
                                Text("→ \(String(f.reqBody.prefix(120)))")
                                    .font(T.mono(9)).foregroundColor(T.txt3).lineLimit(2)
                            }
                            if !f.respBody.isEmpty {
                                Text("← \(String(f.respBody.prefix(120)))")
                                    .font(T.mono(9)).foregroundColor(T.txt3).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            RuleEditor(rule: draft) { r in
                st.proxyRules.append(r)
            }
        }
        .onAppear {
            px.rules = st.proxyRules
            mitm.rules = st.proxyRules
            if px.running { port = "\(px.port)" }
        }
        .onChange(of: st.proxyRules) { v in
            px.rules = v
            mitm.rules = v
        }
    }

    private func toggle() {
        if px.running {
            px.stop()
            hint = ""
            return
        }
        px.rules = st.proxyRules
        if let e = px.start(Int(port) ?? 8888) {
            hint = e
        } else {
            hint = ""
            st.log("抓包", "本机代理启动 :\(port)")
        }
    }

    private func byteText(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
