import Foundation
import Combine

/// 节点桥观测到的状态（决定 Layer 4 怎么写）
struct BridgeState {
    var online = false
    var os = "windows"
    var revReady = false
    var r2Version = ""
    var proxyRunning = false
    var proxyPort = 0
    var proxyCount = 0
    var checkedAt: Date?
}

enum BridgeError: LocalizedError {
    case badURL
    case http(Int, String)
    case decode(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .badURL: return "节点地址不合法"
        case .http(let c, let m): return "节点返回 \(c)：\(m)"
        case .decode(let m): return "返回解析失败：\(m)"
        case .offline: return "节点不可达"
        }
    }
}

/// 连 PC 上的 npclab 服务 —— iOS 端不复制那套 Python，只调用它
struct Bridge {
    let base: URL
    let token: String

    init?(_ st: AppSettings) {
        var s = st.bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let u = URL(string: s) else { return nil }
        base = u
        token = st.bridgeToken
    }

    private func req(_ path: String, method: String = "GET",
                     body: [String: Any]? = nil, timeout: TimeInterval = 30) -> URLRequest? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let raw = path.hasPrefix("/") ? path : "/" + path
        var pure = raw
        var query = ""
        if let q = raw.firstIndex(of: "?") {
            pure = String(raw[raw.startIndex..<q])
            query = String(raw[raw.index(after: q)...])
        }
        let root = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = root + pure
        if !query.isEmpty { c.percentEncodedQuery = query }
        guard let u = c.url else { return nil }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            r.setValue(token, forHTTPHeaderField: "X-NpcLab-Token")
        }
        if let b = body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: b)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func json(_ path: String, method: String = "GET",
              body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let r = req(path, method: method, body: body, timeout: timeout) else {
            throw BridgeError.badURL
        }
        let (data, resp) = try await MITMInterceptor.session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.offline }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw BridgeError.http(http.statusCode, String(msg.prefix(300)))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.decode(String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
        }
        return obj
    }

    // MARK: 便捷封装

    func ping() async throws -> [String: Any] { try await json("/api/ping", timeout: 6) }

    func setIdentity(_ identity: String, shell: String? = nil,
                     timeout: Int? = nil) async throws -> [String: Any] {
        var b: [String: Any] = ["identity": identity]
        if let s = shell { b["shell"] = s }
        if let t = timeout { b["timeout"] = t }
        return try await json("/api/exec/cfg", method: "POST", body: b)
    }

    func exec(_ cmd: String, shell: String, timeout: Int) async throws -> [String: Any] {
        try await json("/api/exec/run", method: "POST", body: [
            "cmd": cmd, "shell": shell, "timeout": timeout
        ], timeout: Double(timeout) + 20)
    }

    func revStatus() async throws -> [String: Any] { try await json("/api/rev/status") }
    func revTargets() async throws -> [String: Any] { try await json("/api/rev/targets") }
    func revFuncs(_ id: String, q: String = "", limit: Int = 120) async throws -> [String: Any] {
        try await json("/api/rev/funcs?id=\(esc(id))&q=\(esc(q))&limit=\(limit)", timeout: 240)
    }
    func revPseudo(_ id: String, off: Int) async throws -> [String: Any] {
        try await json("/api/rev/pseudo?id=\(esc(id))&off=\(off)", timeout: 300)
    }
    func revStrings(_ id: String, q: String = "", limit: Int = 200) async throws -> [String: Any] {
        try await json("/api/rev/strings?id=\(esc(id))&q=\(esc(q))&limit=\(limit)")
    }

    func proxyStatus() async throws -> [String: Any] { try await json("/api/proxy/status") }
    func proxySessions() async throws -> [String: Any] { try await json("/api/proxy/sessions") }
    func proxyStart(_ port: Int) async throws -> [String: Any] {
        try await json("/api/proxy/start", method: "POST", body: ["port": port])
    }
    func proxyStop() async throws -> [String: Any] {
        try await json("/api/proxy/stop", method: "POST", body: [:])
    }

    func hostState() async throws -> [String: Any] { try await json("/api/host/state") }
    func hostEnabled(_ on: Bool) async throws -> [String: Any] {
        try await json("/api/host/enabled", method: "POST", body: ["on": on])
    }
    /// 同步授权根到节点端 hostfs（对齐 /api/host/root：add / del）
    func hostSetRoot(path: String, mode: String = "ro", del: Bool = false) async throws -> [String: Any] {
        var b: [String: Any] = ["path": path, "mode": mode]
        if del { b["action"] = "del" }
        return try await json("/api/host/root", method: "POST", body: b)
    }
    func hostLs(_ path: String) async throws -> [String: Any] {
        try await json("/api/host/ls?path=\(esc(path))")
    }
    func hostRead(_ path: String) async throws -> [String: Any] {
        try await json("/api/host/read?path=\(esc(path))", timeout: 60)
    }

    func ghState() async throws -> [String: Any] { try await json("/api/github/state") }
    func ghSave(token: String, repo: String) async throws -> [String: Any] {
        var owner = ""
        var name = repo
        if let i = repo.firstIndex(of: "/") {
            owner = String(repo[repo.startIndex..<i])
            name = String(repo[repo.index(after: i)...])
        }
        return try await json("/api/github/save", method: "POST",
                              body: ["token": token, "owner": owner, "repo": name])
    }

    func logs() async throws -> [String: Any] { try await json("/api/logs") }

    private func esc(_ s: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "/:._-~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }

    /// 探活 + 拉齐各子系统状态
    static func probe(_ st: AppSettings) async -> BridgeState {
        var s = BridgeState()
        guard st.bridgeOn, let b = Bridge(st) else { return s }
        do {
            let p = try await b.ping()
            s.online = true
            s.os = (p["os"] as? String) ?? "windows"
        } catch {
            return s
        }
        if let r = try? await b.revStatus() {
            s.revReady = (r["r2"] as? Bool) ?? false
            s.r2Version = (r["version"] as? String) ?? ""
        }
        if let x = try? await b.proxyStatus() {
            s.proxyRunning = (x["running"] as? Bool) ?? false
            s.proxyPort = (x["port"] as? Int) ?? 0
            if let st2 = x["stats"] as? [String: Any] {
                s.proxyCount = (st2["total"] as? Int) ?? 0
            }
        }
        s.checkedAt = Date()
        return s
    }
}

/// 全局节点状态，供界面和 Layer 4 共用
final class NodeHub: ObservableObject {
    @Published var state = BridgeState()
    @Published var busy = false

    func refresh(_ st: AppSettings) {
        Task {
            let s = await Bridge.probe(st)
            await MainActor.run {
                self.state = s
                if s.online {
                    st.log("节点", "已连接 \(st.bridgeURL) · \(s.os)")
                }
            }
        }
    }
}
