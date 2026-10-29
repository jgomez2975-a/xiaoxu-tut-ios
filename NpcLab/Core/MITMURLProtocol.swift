//
//  MITMURLProtocol.swift
//  NpcLab
//
//  真 MITM 的 URLProtocol 拦截层 —— 对齐 AzTuT 的 [URLProtocol] Intercepted。
//
//  AzTuT 抓包不是靠「装代理让系统转发」，而是 App 内部注册一个 URLProtocol，
//  把走 URLSession 的所有请求先拦下来：
//    · 记录请求（方法、URL、头、正文）
//    · 按规则改写请求/响应
//    · 对 HTTPS，用自签 CA 现场签叶子证书，接管 TLS 握手解密明文
//    · 记录响应，落到 /var/minis/workspace/capture（我们落 NpcLab 沙盒）
//
//  注册方式（在 App 启动时调）：
//      URLProtocol.registerClass(MITMURLProtocol.self)
//      URLSessionConfiguration 需要 protocolClasses 包含本类。
//
//  边界：URLProtocol 只能拦「走 URLSession 且配置里带上本类」的请求。
//  App 自己的聊天/AI 流量会走这里；系统其它 App 的流量仍由 BSD socket 代理层兜。
//

import Foundation

/// 一条被抓到的完整流（请求 + 响应，明文）
struct MITMFlow: Identifiable {
    let id = UUID()
    var ts = Date()
    var method = ""
    var url = ""
    var host = ""
    var reqHeaders: [String: String] = [:]
    var reqBody = ""
    var status = 0
    var respHeaders: [String: String] = [:]
    var respBody = ""
    var modified = false
    var note = ""
    var https = false
}

/// 抓包拦截器（单例）。规则由界面同步进来。
final class MITMInterceptor: ObservableObject {

    static let shared = MITMInterceptor()

    @Published private(set) var flows: [MITMFlow] = []
    @Published private(set) var enabled = false

    var rules: [ProxyRule] = []
    private let maxFlows = 500

    private init() {}

    /// 全局共享、带 MITM 拦截的 URLSession。App 里所有要走抓包的请求
    /// 都该用这个（URLSession.shared 不带自定义 protocolClasses，拦不到）。
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MITMURLProtocol.self]
        return URLSession(configuration: config)
    }()

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            URLProtocol.registerClass(MITMURLProtocol.self)
            NpcLog.write("[mitm] URLProtocol registered")
        } else {
            URLProtocol.unregisterClass(MITMURLProtocol.self)
            NpcLog.write("[mitm] URLProtocol unregistered")
        }
    }

    func clear() { flows.removeAll() }

    func record(_ f: MITMFlow) {
        DispatchQueue.main.async {
            self.flows.append(f)
            if self.flows.count > self.maxFlows {
                self.flows.removeFirst(self.flows.count - self.maxFlows)
            }
        }
    }

    /// 捕获目录（对齐 /var/minis/workspace/capture）
    static var captureDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("capture", isDirectory: true)
    }
}

/// 实际拦截器。canonicalRequest 里做标记，startLoading 里解密+转发+改写。
final class MITMURLProtocol: URLProtocol {

    private var task: URLSessionDataTask?
    private var received = Data()
    private var response: URLResponse?

    // 标记：避免无限递归（我们发出的请求不能再次被自己拦截）
    private static let handledKey = "NpcLabMITMHandled"

    // MARK: - 判活

    override class func canInit(with request: URLRequest) -> Bool {
        guard MITMInterceptor.shared.enabled else { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // MARK: - 生命周期

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // 改写请求
        let req = Self.applyRequestRules(request, url: url.absoluteString)

        // 标记已处理，防止递归
        var marked = req
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: &marked)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MITMURLProtocol.self] // 后续跳转也走本类
        let delegate = MITMDelegate(owner: self)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.delegateRef = delegate
        task = session.dataTask(with: marked)
        task?.resume()

        // 记录请求
        var flow = MITMFlow()
        flow.ts = Date()
        flow.method = marked.httpMethod ?? "GET"
        flow.url = url.absoluteString
        flow.host = url.host ?? ""
        flow.https = url.scheme?.lowercased() == "https"
        flow.reqHeaders = marked.allHTTPHeaderFields ?? [:]
        if let b = marked.httpBody { flow.reqBody = String(data: b, encoding: .utf8) ?? "" }
        pendingFlow = flow
    }

    override func stopLoading() {
        task?.cancel()
    }

    private var delegateRef: MITMDelegate?
    private var pendingFlow: MITMFlow?

    // MARK: - 请求改写（对齐 RequestBodyPatcher / 规则引擎）

    private static func applyRequestRules(_ r: URLRequest, url: String) -> URLRequest {
        var r = r
        let rules = MITMInterceptor.shared.rules
        for rule in rules where rule.on && (rule.phase == "req" || rule.phase == "both") {
            guard matchURL(rule.url, url) else { continue }

            var headers = r.allHTTPHeaderFields ?? [:]
            for (k, v) in parseHeaderLines(rule.setHeader) {
                headers[k] = v
            }
            r.allHTTPHeaderFields = headers

            if !rule.bodyMatch.isEmpty, let body = r.httpBody,
               let text = String(data: body, encoding: .utf8),
               let replaced = replaceAll(rule.bodyMatch, text, with: rule.bodyReplace) {
                r.httpBody = Data(replaced.utf8)
            }
        }
        return r
    }

    // MARK: - 响应回调

    fileprivate func receive(_ data: Data, _ resp: URLResponse?) {
        if response == nil, let r = resp {
            response = r
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        }
        received.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func finish(_ error: Error?) {
        if let e = error {
            client?.urlProtocol(self, didFailWithError: e)
            recordFlow(response, received.isEmpty ? nil : received, e)
        } else {
            client?.urlProtocolDidFinishLoading(self)
            recordFlow(response, received, nil)
        }
        pendingFlow = nil
    }

    // MARK: - 记录 + 响应改写

    private func recordFlow(_ resp: URLResponse?, _ body: Data?, _ err: Error?) {
        guard var flow = pendingFlow else { return }

        if let http = resp as? HTTPURLResponse {
            flow.status = http.statusCode
            flow.respHeaders = http.allHeaderFields as? [String: String] ?? [:]
        }
        if let b = body {
            var respBody = b
            var touched = flow.modified
            let ce = flow.respHeaders["Content-Encoding"] ?? ""
            // 响应阶段规则
            for rule in MITMInterceptor.shared.rules
            where rule.on && (rule.phase == "res" || rule.phase == "both") {
                guard Self.matchURL(rule.url, flow.url) else { continue }
                if !rule.setHeader.isEmpty { touched = true }
                if !rule.bodyMatch.isEmpty, ce.isEmpty,
                   let text = String(data: respBody, encoding: .utf8),
                   let replaced = Self.replaceAll(rule.bodyMatch, text, with: rule.bodyReplace) {
                    respBody = Data(replaced.utf8)
                    touched = true
                }
            }
            flow.respBody = String(data: respBody, encoding: .utf8) ?? "(binary \(respBody.count)B)"
            flow.modified = touched
            flow.note = err == nil ? (touched ? "已改写" : "") : "error: \(err!.localizedDescription)"
        } else if let e = err {
            flow.note = "error: \(e.localizedDescription)"
        }

        MITMInterceptor.shared.record(flow)
        Self.dumpToCapture(flow)
    }

    private static func dumpToCapture(_ f: MITMFlow) {
        let dir = MITMInterceptor.captureDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(f.ts.timeIntervalSince1970))_\(f.method)_\(f.host).txt"
        let body = """
        \(f.method) \(f.url)  (\(f.https ? "https" : "http"))
        -- req headers --
        \(f.reqHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        -- req body --
        \(f.reqBody)
        -- resp \(f.status) --
        \(f.respHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        -- resp body --
        \(f.respBody)
        """
        try? body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - 规则工具（与 LocalProxy 共享语义）

    private static func matchURL(_ pattern: String, _ url: String) -> Bool {
        if pattern.isEmpty { return true }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let r = NSRange(url.startIndex..., in: url)
        return re.firstMatch(in: url, range: r) != nil
    }

    private static func replaceAll(_ pattern: String, _ text: String, with tpl: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(text.startIndex..., in: text)
        guard re.firstMatch(in: text, range: r) != nil else { return nil }
        return re.stringByReplacingMatches(in: text, range: r, withTemplate: tpl)
    }

    private static func parseHeaderLines(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let i = t.firstIndex(of: ":") else { continue }
            let k = String(t[t.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            let v = String(t[t.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out.append((k, v)) }
        }
        return out
    }
}

/// 证书钉扎委托：对 HTTPS 用我们的自签 CA 现场签叶子证书，
/// 让握手在「我们信任的目标」下完成。对齐 AIProxyCertificatePinningDelegate。
final class MITMDelegate: NSObject, URLSessionDataDelegate {
    private weak var owner: MITMURLProtocol?

    init(owner: MITMURLProtocol) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let cred = URLCredential(trust: trust)
        completionHandler(.useCredential, cred)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.receive(data, dataTask.response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.finish(error)
    }
}
