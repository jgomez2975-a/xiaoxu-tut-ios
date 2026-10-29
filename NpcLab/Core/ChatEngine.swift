import Foundation
import SwiftUI

/// 对话引擎：OpenAI 兼容 / Anthropic 两套流式协议
@MainActor
final class ChatEngine: ObservableObject {
    @Published var streaming = false
    @Published var live = ""
    @Published var err: String?
    @Published var lastUsage = 0

    private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
        streaming = false
    }

    func send(_ st: AppSettings, system: String, text: String, images: [String] = []) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !images.isEmpty else { return }
        guard !streaming else { return }

        if st.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            err = "还没填 API Key（设置 → 模型）"
            return
        }

        st.messages.append(ChatMessage(role: "user", text: body, images: images))
        st.save()
        err = nil
        live = ""
        streaming = true
        st.log("对话", "发送 \(body.count) 字" + (images.isEmpty ? "" : " + \(images.count) 图")
               + " · \(st.model)")

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let full = try await self.run(st, system: system)
                await MainActor.run {
                    if !full.isEmpty {
                        st.messages.append(ChatMessage(role: "assistant", text: full,
                                                       tokens: self.lastUsage))
                    }
                    self.live = ""
                    self.streaming = false
                    st.save()
                    st.log("对话", "收到 \(full.count) 字")
                }
            } catch is CancellationError {
                await MainActor.run {
                    if !self.live.isEmpty {
                        st.messages.append(ChatMessage(role: "assistant", text: self.live + "\n\n[已中断]"))
                    }
                    self.live = ""
                    self.streaming = false
                    st.save()
                }
            } catch {
                await MainActor.run {
                    self.err = error.localizedDescription
                    self.streaming = false
                    self.live = ""
                    st.messages.append(ChatMessage(role: "assistant",
                                                   text: "请求失败：\(error.localizedDescription)",
                                                   error: true))
                    st.save()
                    st.log("错误", error.localizedDescription)
                }
            }
        }
    }

    private func run(_ st: AppSettings, system: String) async throws -> String {
        var base = st.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let isAnthropic = st.provider == "anthropic"
        let path = isAnthropic ? "/messages" : "/chat/completions"
        guard let url = URL(string: base + path) else { throw BridgeError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if isAnthropic {
            req.setValue(st.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(st.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let msgs = trimHistory(st)
        var payload: [String: Any] = [
            "model": st.model,
            "max_tokens": st.maxTokens,
            "temperature": st.temperature,
            "stream": st.streamOn
        ]
        if isAnthropic {
            payload["system"] = system
            payload["messages"] = msgs.map { m -> [String: Any] in
                ["role": m.role, "content": Self.content(m, anthropic: true)]
            }
        } else {
            var arr: [[String: Any]] = [["role": "system", "content": system]]
            arr.append(contentsOf: msgs.map { m -> [String: Any] in
                ["role": m.role, "content": Self.content(m, anthropic: false)]
            })
            payload["messages"] = arr
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        if st.streamOn {
            return try await streamText(req, anthropic: isAnthropic)
        } else {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw BridgeError.offline }
            let raw = String(data: data, encoding: .utf8) ?? ""
            guard http.statusCode < 400 else {
                throw BridgeError.http(http.statusCode, String(raw.prefix(400)))
            }
            if isAnthropic {
                if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let blocks = o["content"] as? [[String: Any]] {
                    return blocks.compactMap { $0["text"] as? String }.joined()
                }
                return raw
            } else {
                if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ch = o["choices"] as? [[String: Any]],
                   let m = ch.first?["message"] as? [String: Any],
                   let t = m["content"] as? String {
                    return t
                }
                return raw
            }
        }
    }

    private func streamText(_ req: URLRequest, anthropic: Bool) async throws -> String {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.offline }

        if http.statusCode >= 400 {
            var buf = ""
            for try await line in bytes.lines {
                buf += line
                if buf.count > 1200 { break }
            }
            throw BridgeError.http(http.statusCode, buf)
        }

        var full = ""
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("data:") else { continue }
            var json = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if json == "[DONE]" { break }
            if json.isEmpty { continue }
            // 有些兼容端会在 data: 后面再套一层
            if json.hasPrefix("data:") { json = String(json.dropFirst(5)) }

            guard let d = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                continue
            }

            if anthropic {
                if let t = o["type"] as? String, t == "message_stop" { break }
                if let delta = o["delta"] as? [String: Any],
                   let txt = delta["text"] as? String {
                    full += txt
                    self.live = full
                }
            } else {
                if let ch = o["choices"] as? [[String: Any]],
                   let delta = ch.first?["delta"] as? [String: Any] {
                    if let txt = delta["content"] as? String {
                        full += txt
                        self.live = full
                    }
                }
                if let u = o["usage"] as? [String: Any],
                   let n = u["total_tokens"] as? Int {
                    lastUsage = n
                }
            }
        }
        return full
    }

    /// 一条消息的 content。没图就是纯字符串（省钱、兼容性最好）；
    /// 有图才变成 parts 数组 —— 有些第三方兼容端不认数组格式，能简单就不复杂。
    private static func content(_ m: ChatMessage, anthropic: Bool) -> Any {
        let imgs = Attachment.alive(m.images)
        guard !imgs.isEmpty else { return m.text }

        var parts: [[String: Any]] = []
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            parts.append(["type": "text", "text": t])
        }
        for name in imgs {
            if anthropic {
                if let p = Attachment.anthropicPart(name) { parts.append(p) }
            } else {
                if let p = Attachment.openAIPart(name) { parts.append(p) }
            }
        }
        // 图全读不出来（被清理了）就退成纯文字，别发个空 content 让接口 400
        return parts.isEmpty ? m.text : parts
    }

    /// 上下文窗口：超阈值时从最老的开始丢，system 永远保留
    private func trimHistory(_ st: AppSettings) -> [ChatMessage] {
        let cap = max(2000, st.ctxLimit) * 2          // 粗略按字符折算
        var arr = st.messages.filter { $0.role == "user" || $0.role == "assistant" }
        var total = arr.reduce(0) { $0 + $1.text.count + $1.images.count * 1500 }
        while total > cap && arr.count > 2 {
            total -= arr[0].text.count + arr[0].images.count * 1500
            arr.removeFirst()
        }
        return arr
    }
}
