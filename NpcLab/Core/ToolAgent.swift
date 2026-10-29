//
//  ToolAgent.swift
//  NpcLab
//
//  让模型在对话里直接动手，而不是只吐文字然后让你自己去点界面。
//
//  跟 ChatEngine 的分工：
//    ChatEngine  —— 纯聊天，流式，没有工具（保持原样，不动它）
//    ToolAgent   —— 带工具的循环，非流式，一轮可能往返多次
//  界面上由「设置 → 开发者 → 对话内工具」切换。关着的时候完全不碰这条路径。
//
//  为什么非流式：流式解析 tool_calls 要处理「参数被切成十几个 chunk」的
//  增量拼接，OpenAI 和 Anthropic 的 delta 结构还不一样。非流式一次拿完整的
//  JSON 参数，稳定得多。工具调用本来就不是「一个字一个字蹦」的场景。
//
//  八个工具，三个纯本地（没节点也能用）：
//    read_skill / search_skills / read_doc
//  五个走节点：
//    node_exec / rev_targets / rev_funcs / rev_pseudo / proxy_add_rule
//

import Foundation

@MainActor
final class ToolAgent: ObservableObject {

    /// 正在跑哪个工具，界面显示用
    @Published var current: String?
    /// 本轮已经跑了几轮
    @Published var round = 0
    @Published var streaming = false
    @Published var err: String?

    private var task: Task<Void, Never>?

    /// 单轮最多往返几次。设太大遇到模型死循环会烧钱。
    static let maxRounds = 6

    func stop() {
        task?.cancel()
        task = nil
        streaming = false
        current = nil
    }

    // MARK: 入口

    func send(_ st: AppSettings, system: String, text: String,
              bridge: Bridge?, hub: NodeHub) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !streaming else { return }
        guard !st.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            err = "还没填 API Key（设置 → 模型）"
            return
        }

        st.messages.append(ChatMessage(role: "user", text: body))
        st.save()
        err = nil
        streaming = true
        round = 0
        st.log("工具", "开始 \(st.model) · 工具循环开")

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let out = try await self.loop(st, system: system, bridge: bridge, hub: hub)
                await MainActor.run {
                    st.messages.append(ChatMessage(role: "assistant", text: out.text))
                    self.streaming = false
                    self.current = nil
                    st.save()
                    st.log("工具", "完成 \(out.text.count) 字 · \(self.round) 轮")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.streaming = false
                    self.current = nil
                    st.messages.append(ChatMessage(role: "assistant", text: "[已中断]", error: true))
                    st.save()
                }
            } catch {
                await MainActor.run {
                    self.err = error.localizedDescription
                    self.streaming = false
                    self.current = nil
                    st.messages.append(ChatMessage(role: "assistant",
                                                   text: "请求失败：\(error.localizedDescription)",
                                                   error: true))
                    st.save()
                    st.log("错误", error.localizedDescription)
                }
            }
        }
    }

    // MARK: 主循环

    private struct Outcome { var text: String }

    private func loop(_ st: AppSettings, system: String,
                      bridge: Bridge?, hub: NodeHub) async throws -> Outcome {
        let isAnthropic = st.provider == "anthropic"

        // 工作消息：只在本轮有效。历史里的工具调用不跨轮带，
        // 免得消息数组越长越贵，也免得模型拿旧结果当新答案。
        var work: [[String: Any]] = st.messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { ["role": $0.role, "content": $0.text] }

        var lastText = ""

        for i in 0..<Self.maxRounds {
            try Task.checkCancellation()
            await MainActor.run { self.round = i + 1 }

            let reply: Reply
            if isAnthropic {
                reply = try await callAnthropic(st, system: system, messages: work)
            } else {
                reply = try await callOpenAI(st, system: system, messages: work)
            }

            if !reply.text.isEmpty { lastText = reply.text }

            // 没有工具调用 —— 收工
            if reply.calls.isEmpty {
                return Outcome(text: reply.text.isEmpty ? lastText : reply.text)
            }

            // 有工具调用：先把 assistant 那条塞进去（协议要求），再逐个执行
            if isAnthropic {
                work.append(["role": "assistant", "content": reply.rawBlocks])
            } else {
                var m: [String: Any] = ["role": "assistant"]
                m["content"] = reply.text.isEmpty ? NSNull() : reply.text
                m["tool_calls"] = reply.calls.map { c -> [String: Any] in
                    ["id": c.id, "type": "function",
                     "function": ["name": c.name, "arguments": c.argumentsJSON]]
                }
                work.append(m)
            }

            for c in reply.calls {
                try Task.checkCancellation()
                await MainActor.run { self.current = c.name }
                let result = await Self.execute(c, st: st, bridge: bridge)

                if isAnthropic {
                    work.append(["role": "user", "content": [[
                        "type": "tool_result",
                        "tool_use_id": c.id,
                        "content": result
                    ]]])
                } else {
                    work.append(["role": "tool",
                                 "tool_call_id": c.id,
                                 "content": result])
                }
            }
            await MainActor.run { self.current = nil }
        }

        // 跑满轮数还没收敛：把最后拿到的文字交出去，并说明情况
        let note = "\n\n（工具往返已达 \(Self.maxRounds) 轮上限，先给你这些。要接着来就再发一句。）"
        return Outcome(text: (lastText.isEmpty ? "（没有拿到结果）" : lastText) + note)
    }

    // MARK: 协议 —— OpenAI

    private struct Call {
        let id: String
        let name: String
        let argumentsJSON: String
        var args: [String: Any] {
            guard let d = argumentsJSON.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return [:]
            }
            return o
        }
    }

    private struct Reply {
        var text: String = ""
        var calls: [Call] = []
        /// Anthropic 要把 assistant 的原始 content blocks 原样回传，不能自己拼
        var rawBlocks: [[String: Any]] = []
    }

    private func endpoint(_ st: AppSettings) throws -> (URL, Bool) {
        var base = st.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let isA = st.provider == "anthropic"
        guard let u = URL(string: base + (isA ? "/messages" : "/chat/completions")) else {
            throw BridgeError.badURL
        }
        return (u, isA)
    }

    private func callOpenAI(_ st: AppSettings, system: String,
                            messages: [[String: Any]]) async throws -> Reply {
        let (url, _) = try endpoint(st)
        var req = URLRequest(url: url, timeoutInterval: 240)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(st.apiKey)", forHTTPHeaderField: "Authorization")

        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        msgs.append(contentsOf: messages)

        let payload: [String: Any] = [
            "model": st.model,
            "max_tokens": st.maxTokens,
            "temperature": st.temperature,
            "stream": false,
            "messages": msgs,
            "tools": Self.openAITools,
            "tool_choice": "auto"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.offline }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode < 400 else {
            throw BridgeError.http(http.statusCode, String(raw.prefix(400)))
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ch = o["choices"] as? [[String: Any]],
              let m = ch.first?["message"] as? [String: Any] else {
            throw BridgeError.decode(String(raw.prefix(300)))
        }

        var r = Reply()
        r.text = (m["content"] as? String) ?? ""
        if let tcs = m["tool_calls"] as? [[String: Any]] {
            for t in tcs {
                let id = (t["id"] as? String) ?? UUID().uuidString
                guard let f = t["function"] as? [String: Any],
                      let n = f["name"] as? String else { continue }
                let a = (f["arguments"] as? String) ?? "{}"
                r.calls.append(Call(id: id, name: n, argumentsJSON: a))
            }
        }
        return r
    }

    // MARK: 协议 —— Anthropic

    private func callAnthropic(_ st: AppSettings, system: String,
                               messages: [[String: Any]]) async throws -> Reply {
        let (url, _) = try endpoint(st)
        var req = URLRequest(url: url, timeoutInterval: 240)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(st.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload: [String: Any] = [
            "model": st.model,
            "max_tokens": st.maxTokens,
            "temperature": st.temperature,
            "system": system,
            "messages": messages,
            "tools": Self.anthropicTools
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.offline }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode < 400 else {
            throw BridgeError.http(http.statusCode, String(raw.prefix(400)))
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = o["content"] as? [[String: Any]] else {
            throw BridgeError.decode(String(raw.prefix(300)))
        }

        var r = Reply()
        r.rawBlocks = blocks
        for b in blocks {
            let t = (b["type"] as? String) ?? ""
            if t == "text" {
                r.text += (b["text"] as? String) ?? ""
            } else if t == "tool_use" {
                let id = (b["id"] as? String) ?? UUID().uuidString
                let name = (b["name"] as? String) ?? ""
                let input = (b["input"] as? [String: Any]) ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                r.calls.append(Call(id: id, name: name, argumentsJSON: json))
            }
        }
        return r
    }

    // MARK: 工具定义

    private static func schema(_ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    private static let defs: [(name: String, desc: String, params: [String: Any], req: [String])] = [
        ("read_skill",
         "读某条技能的完整 SKILL.md 正文。参数是技能 id（形如 NPC-EDR-Atlas-0001）。本机执行，无需节点。",
         ["id": ["type": "string", "description": "技能 id"]], ["id"]),

        ("search_skills",
         "在 897 条技能里搜。按 id / 名称 / 描述 / 触发词匹配，返回前 20 条。本机执行，无需节点。",
         ["query": ["type": "string", "description": "关键词"]], ["query"]),

        ("read_doc",
         "读内置文档（47 篇）。先不传 path 拿目录，再传具体 path 读正文。本机执行，无需节点。",
         ["path": ["type": "string", "description": "文档路径，留空则返回目录"]], []),

        ("node_exec",
         "在算力节点上执行 shell 命令。返回 out / err / code。需要节点在线且已授权执行。",
         ["cmd": ["type": "string", "description": "要执行的命令"],
                 "timeout": ["type": "integer", "description": "超时秒数，默认 60"]], ["cmd"]),

        ("rev_targets",
         "列出节点上已加载的逆向目标（二进制）。返回每条的 id / path / arch / size。",
         [:], []),

        ("rev_funcs",
         "列出某个逆向目标的函数。id 用 rev_targets 拿到的那个。",
         ["id": ["type": "string", "description": "目标 id"],
                 "q": ["type": "string", "description": "函数名过滤，可空"],
                 "limit": ["type": "integer", "description": "返回条数上限，默认 120"]], ["id"]),

        ("rev_pseudo",
         "对某个目标的某个函数出伪代码（节点按 pdg → pdd → pdc → pdf 自动降级）。",
         ["id": ["type": "string", "description": "目标 id"],
                 "off": ["type": "integer", "description": "函数入口偏移"]], ["id", "off"]),

        ("proxy_add_rule",
         "给抓包代理加一条改写规则。url 是正则，phase 决定改请求还是响应。",
         ["url": ["type": "string", "description": "URL 正则"],
                 "phase": ["type": "string", "description": "request / response / both"],
                 "bodyMatch": ["type": "string", "description": "正文匹配（可选）"],
                 "bodyReplace": ["type": "string", "description": "正文替换（可选）"],
                 "setHeader": ["type": "string", "description": "要设置的请求头，形如 Key: Value（可选）"]],
         ["url", "phase"])
    ]

    private static var openAITools: [[String: Any]] {
        defs.map { d in
            ["type": "function",
             "function": ["name": d.name, "description": d.desc,
                          "parameters": schema(d.params, required: d.req)]]
        }
    }

    private static var anthropicTools: [[String: Any]] {
        defs.map { d in
            ["name": d.name, "description": d.desc, "input_schema": schema(d.params, required: d.req)]
        }
    }

    // MARK: 执行

    private static func execute(_ c: Call, st: AppSettings, bridge: Bridge?) async -> String {
        let a = c.args

        switch c.name {

        // ---- 本地 ----

        case "read_skill":
            let id = (a["id"] as? String) ?? ""
            guard !id.isEmpty else { return "错误：id 为空" }
            guard let body = PackData.shared.body(for: id), !body.isEmpty else {
                return "没有这个技能的正文：\(id)。先用 search_skills 找准确的 id。"
            }
            return clip(body, 12000)

        case "search_skills":
            let q = (a["query"] as? String) ?? ""
            let hits = PackData.shared.search(q).prefix(20)
            if hits.isEmpty { return "没有匹配「\(q)」的技能。" }
            return hits.map { s in
                "\(s.id)  [\(s.code)]  \(s.desc.prefix(90))"
            }.joined(separator: "\n")

        case "read_doc":
            let p = ((a["path"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let docs = PackData.shared.docs
            if p.isEmpty {
                return "共 \(docs.count) 篇：\n" + docs.prefix(60).map { d in
                    "\(d.path)  —  \(d.title)"
                }.joined(separator: "\n")
            }
            guard let d = docs.first(where: { $0.path == p || $0.title == p }) else {
                let near = docs.filter { $0.path.contains(p) || $0.title.contains(p) }.prefix(5)
                let hint = near.isEmpty ? "" : "\n相近的：\n" + near.map { $0.path }.joined(separator: "\n")
                return "没有这篇：\(p)\(hint)"
            }
            return clip(d.body.isEmpty ? "（正文读不到）" : d.body, 12000)

        // ---- 节点 ----

        case "node_exec":
            guard let b = bridge else { return "节点未配置（设置 → 算力节点）。" }
            guard st.allowExec else { return "本机未授权执行（设置 → 开发者 → 终端）。" }
            let cmd = (a["cmd"] as? String) ?? ""
            guard !cmd.isEmpty else { return "错误：cmd 为空" }
            let to = (a["timeout"] as? Int) ?? st.execTimeout
            do {
                let r = try await b.exec(cmd, shell: st.execShell, timeout: to)
                let out = (r["out"] as? String) ?? ""
                let errOut = (r["err"] as? String) ?? ""
                let code = (r["code"] as? Int) ?? -1
                var s = "exit \(code)\n"
                if !out.isEmpty { s += "--- stdout ---\n" + clip(out, 8000) + "\n" }
                if !errOut.isEmpty { s += "--- stderr ---\n" + clip(errOut, 4000) + "\n" }
                if out.isEmpty && errOut.isEmpty { s += "（无输出）" }
                return s
            } catch {
                return "执行失败：\(error.localizedDescription)"
            }

        case "rev_targets":
            guard let b = bridge else { return "节点未配置。" }
            do {
                let r = try await b.revTargets()
                let arr = (r["targets"] as? [[String: Any]]) ?? []
                if arr.isEmpty { return "节点上还没有加载目标。" }
                return arr.map { t in
                    let id = (t["id"] as? String) ?? ""
                    let path = (t["path"] as? String) ?? ""
                    let arch = (t["arch"] as? String) ?? "?"
                    // 服务端两种写法都见过，挨个试
                    let size = (t["sizeText"] as? String)
                        ?? (t["size"] as? String)
                        ?? ((t["size"] as? Int).map { "\($0) B" } ?? "")
                    return "\(id)  \(path)  [\(arch)] \(size)"
                }.joined(separator: "\n")
            } catch {
                return "取目标列表失败：\(error.localizedDescription)"
            }

        case "rev_funcs":
            guard let b = bridge else { return "节点未配置。" }
            let id = (a["id"] as? String) ?? ""
            guard !id.isEmpty else { return "错误：id 为空" }
            let q = (a["q"] as? String) ?? ""
            let limit = (a["limit"] as? Int) ?? 120
            do {
                let r = try await b.revFuncs(id, q: q, limit: limit)
                let arr = (r["funcs"] as? [[String: Any]]) ?? []
                if arr.isEmpty { return "没拿到函数（目标未就绪，或过滤条件太窄）。" }
                return arr.prefix(limit).map { f in
                    let off = (f["off"] as? Int) ?? 0
                    let name = (f["name"] as? String) ?? "?"
                    let size = (f["size"] as? Int) ?? 0
                    return String(format: "0x%llx  %@  (%d B)", Int64(off), name, size)
                }.joined(separator: "\n")
            } catch {
                return "取函数列表失败：\(error.localizedDescription)"
            }

        case "rev_pseudo":
            guard let b = bridge else { return "节点未配置。" }
            let id = (a["id"] as? String) ?? ""
            let off = (a["off"] as? Int) ?? 0
            guard !id.isEmpty else { return "错误：id 为空" }
            do {
                let r = try await b.revPseudo(id, off: off)
                let code = (r["code"] as? String) ?? (r["pseudo"] as? String) ?? ""
                let engine = (r["engine"] as? String) ?? "?"
                if code.isEmpty { return "节点没返回伪代码（engine=\(engine)）。" }
                return "engine=\(engine)\n" + clip(code, 12000)
            } catch {
                return "反编译失败：\(error.localizedDescription)"
            }

        case "proxy_add_rule":
            guard let b = bridge else { return "节点未配置。" }
            let url = (a["url"] as? String) ?? ""
            guard !url.isEmpty else { return "错误：url 为空" }
            var body: [String: Any] = ["action": "add",
                                       "url": url,
                                       "phase": (a["phase"] as? String) ?? "both",
                                       "on": true,
                                       "name": url]
            if let v = a["bodyMatch"] as? String, !v.isEmpty { body["bodyMatch"] = v }
            if let v = a["bodyReplace"] as? String, !v.isEmpty { body["bodyReplace"] = v }
            if let v = a["setHeader"] as? String, !v.isEmpty { body["setHeader"] = v }
            do {
                _ = try await b.json("/api/proxy/rule", method: "POST", body: body)
                return "规则已加：\(url) · \(body["phase"] as? String ?? "")。到「逆向 → 抓包」能看到。"
            } catch {
                return "加规则失败：\(error.localizedDescription)"
            }

        default:
            return "未知工具：\(c.name)"
        }
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "\n…（截断，原长 \(s.count) 字）"
    }
}
