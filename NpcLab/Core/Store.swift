import Foundation
import Combine
import SwiftUI

// MARK: - 内置数据（离线可用，全部随包）

final class PackData {
    static let shared = PackData()

    private(set) var packName: String = "NPC-team v6.1.0"
    private(set) var skills: [Skill] = []
    private(set) var domains: [Domain] = []
    private(set) var tools: [Tool] = []
    private(set) var toolGroups: [ToolGroup] = []
    private(set) var presets: [Preset] = []
    private(set) var docs: [PackDoc] = []

    private(set) var bodyTotal: Int = 0
    private var bodies: [String: String]?
    private var loadedDocs = false

    private init() { load() }

    private func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    private func load() {
        if let u = url("stats.json"), let d = try? Data(contentsOf: u),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            bodyTotal = (o["bodies"] as? Int) ?? 0
        }
        if let u = url("skills.json"), let d = try? Data(contentsOf: u),
           let p = try? JSONDecoder().decode(SkillPack.self, from: d) {
            skills = p.skills
            domains = p.domains
            packName = p.pack
        }
        if let u = url("tools.json"), let d = try? Data(contentsOf: u),
           let p = try? JSONDecoder().decode(ToolPack.self, from: d) {
            tools = p.tools
            toolGroups = p.groups
        }
        if let u = url("presets.json"), let d = try? Data(contentsOf: u),
           let p = try? JSONDecoder().decode(PresetFile.self, from: d) {
            presets = p.presets
        }
    }

    /// 文档体积大，第一次进「文档」页才解
    func loadDocsIfNeeded() {
        guard !loadedDocs else { return }
        loadedDocs = true
        if let u = url("docs.json"), let d = try? Data(contentsOf: u),
           let p = try? JSONDecoder().decode(DocFile.self, from: d) {
            docs = p.docs
        }
    }

    /// 技能正文（8MB），用到才读
    private func loadBodies() {
        guard bodies == nil else { return }
        if let u = url("skillbody.json"), let d = try? Data(contentsOf: u),
           let m = try? JSONDecoder().decode([String: String].self, from: d) {
            bodies = m
        } else {
            bodies = [:]
        }
    }

    func body(for id: String) -> String? {
        loadBodies()
        if let t = bodies?[id], !t.isEmpty { return t }
        return nil
    }

    func hasBody(_ id: String) -> Bool {
        loadBodies()
        return (bodies?[id]?.isEmpty == false)
    }

    /// 不触发 8.5MB 解析，直接用打包时算好的数
    var bodyCount: Int { bodyTotal }

    func domainName(_ code: String) -> String {
        domains.first { $0.code == code }?.name ?? code
    }

    /// 与 PC 版一致的排序：置顶 1000 分、同方向 100 分、体量最多加 20 分
    func ranked(code: String, pinned: [String], limit: Int = 20) -> [Skill] {
        let scored = skills.map { s -> (Skill, Double) in
            var sc = 0.0
            if pinned.contains(s.id) { sc += 1000 }
            if s.code == code { sc += 100 }
            sc += min(20, Double(s.bytes) / 4000.0)
            return (s, sc)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    func search(_ q: String) -> [Skill] {
        let k = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return skills }
        return skills.filter {
            $0.id.lowercased().contains(k) || $0.name.lowercased().contains(k)
                || $0.desc.lowercased().contains(k)
                || $0.triggers.contains { $0.lowercased().contains(k) }
        }
    }
}

// MARK: - 配置（落盘到 UserDefaults）

final class AppSettings: ObservableObject {

    // ---- 注入 / 人设 ----
    @Published var injectOn: Bool = true { didSet { save() } }
    @Published var presetId: String = "npc-core" { didSet { save() } }
    @Published var injectMode: String = "append" { didSet { save() } }   // append / prepend / replace
    @Published var prefix: String = "" { didSet { save() } }
    @Published var skillMode: String = "index" { didSet { save() } }     // index / full / off
    @Published var toolMode: String = "bundled" { didSet { save() } }    // bundled / full / off
    @Published var pinned: [String] = [] { didSet { save() } }
    @Published var persona: String = "" { didSet { save() } }
    @Published var tailOn: Bool = true { didSet { save() } }
    @Published var tailText: String = "" { didSet { save() } }

    // ---- 模型 ----
    @Published var provider: String = "openai" { didSet { save() } }     // openai / anthropic
    @Published var baseURL: String = "https://api.openai.com/v1" { didSet { save() } }
    @Published var apiKey: String = "" { didSet { save() } }
    @Published var model: String = "gpt-4o" { didSet { save() } }
    @Published var temperature: Double = 0.7 { didSet { save() } }
    @Published var maxTokens: Int = 4096 { didSet { save() } }
    @Published var streamOn: Bool = true { didSet { save() } }

    // ---- 节点桥（PC 算力节点）----
    @Published var bridgeOn: Bool = false { didSet { save() } }
    @Published var bridgeURL: String = "http://192.168.1.100:8790" { didSet { save() } }
    @Published var bridgeToken: String = "" { didSet { save() } }

    // ---- 权限 ----
    @Published var faceIDLock: Bool = false { didSet { save() } }
    @Published var allowFileRead: Bool = false { didSet { save() } }
    @Published var allowExec: Bool = false { didSet { save() } }
    @Published var allowProxy: Bool = false { didSet { save(); MITMInterceptor.shared.setEnabled(allowProxy) } }

    // ---- 开发者 ----
    @Published var hostRoots: [HostRoot] = [] { didSet { save() } }
    @Published var execShell: String = "sh" { didSet { save() } }
    @Published var execIdentity: String = "user" { didSet { save() } }   // user / admin / system
    @Published var execTimeout: Int = 60 { didSet { save() } }
    @Published var ghToken: String = "" { didSet { save() } }
    @Published var ghRepo: String = "" { didSet { save() } }
    @Published var ctxLimit: Int = 32000 { didSet { save() } }
    @Published var autoCompact: Bool = true { didSet { save() } }
    /// 对话内工具循环。开了以后走 ToolAgent（非流式，一次可能往返好几轮）；
    /// 关着走原来的 ChatEngine（纯流式文字）。见 Core/ToolAgent.swift。
    @Published var toolLoop: Bool = false { didSet { save() } }

    // ---- 逆向 ----
    @Published var revTargets: [RevTarget] = [] { didSet { save() } }
    @Published var proxyRules: [ProxyRule] = [] { didSet { save() } }
    @Published var revEngine: String = "pdg" { didSet { save() } }       // pdg / pdd / pdc

    // ---- 会话 ----
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    @Published var logs: [LogItem] = [] { didSet { save() } }

    private var suspend = false

    private struct Blob: Codable {
        var injectOn: Bool?
        var presetId: String?
        var injectMode: String?
        var prefix: String?
        var skillMode: String?
        var toolMode: String?
        var pinned: [String]?
        var persona: String?
        var tailOn: Bool?
        var tailText: String?
        var provider: String?
        var baseURL: String?
        var apiKey: String?
        var model: String?
        var temperature: Double?
        var maxTokens: Int?
        var streamOn: Bool?
        var bridgeOn: Bool?
        var bridgeURL: String?
        var bridgeToken: String?
        var faceIDLock: Bool?
        var allowFileRead: Bool?
        var allowExec: Bool?
        var allowProxy: Bool?
        var hostRoots: [HostRoot]?
        var execShell: String?
        var execIdentity: String?
        var execTimeout: Int?
        var ghToken: String?
        var ghRepo: String?
        var ctxLimit: Int?
        var autoCompact: Bool?
        var toolLoop: Bool?
        var revTargets: [RevTarget]?
        var proxyRules: [ProxyRule]?
        var revEngine: String?
        var messages: [ChatMessage]?
    }

    init() {
        suspend = true
        if let d = UserDefaults.standard.data(forKey: "npclab.cfg"),
           let b = try? JSONDecoder().decode(Blob.self, from: d) {
            apply(b)
        }
        if persona.isEmpty { persona = AppSettings.defaultPersona() }
        if tailText.isEmpty { tailText = AppSettings.defaultTail() }
        suspend = false
        loadLogs()
        if messages.isEmpty {
            messages = [ChatMessage(role: "assistant",
                                    text: "Npc 已上线。人设、\(PackData.shared.skills.count) 条技能索引、\(PackData.shared.tools.count) 项工具链全部在设备本地。\n设置里填模型地址与 Key 就能说话；接上节点后终端 / 逆向 / 抓包才开始有实体。")]
        }
    }

    private func apply(_ b: Blob) {
        if let v = b.injectOn { injectOn = v }
        if let v = b.presetId { presetId = v }
        if let v = b.injectMode { injectMode = v }
        if let v = b.prefix { prefix = v }
        if let v = b.skillMode { skillMode = v }
        if let v = b.toolMode { toolMode = v }
        if let v = b.pinned { pinned = v }
        if let v = b.persona { persona = v }
        if let v = b.tailOn { tailOn = v }
        if let v = b.tailText { tailText = v }
        if let v = b.provider { provider = v }
        if let v = b.baseURL { baseURL = v }
        if let v = b.apiKey { apiKey = v }
        if let v = b.model { model = v }
        if let v = b.temperature { temperature = v }
        if let v = b.maxTokens { maxTokens = v }
        if let v = b.streamOn { streamOn = v }
        if let v = b.bridgeOn { bridgeOn = v }
        if let v = b.bridgeURL { bridgeURL = v }
        if let v = b.bridgeToken { bridgeToken = v }
        if let v = b.faceIDLock { faceIDLock = v }
        if let v = b.allowFileRead { allowFileRead = v }
        if let v = b.allowExec { allowExec = v }
        if let v = b.allowProxy { allowProxy = v }
        if let v = b.hostRoots { hostRoots = v }
        if let v = b.execShell { execShell = v }
        if let v = b.execIdentity { execIdentity = v }
        if let v = b.execTimeout { execTimeout = v }
        if let v = b.ghToken { ghToken = v }
        if let v = b.ghRepo { ghRepo = v }
        if let v = b.ctxLimit { ctxLimit = v }
        if let v = b.autoCompact { autoCompact = v }
        if let v = b.toolLoop { toolLoop = v }
        if let v = b.revTargets { revTargets = v }
        if let v = b.proxyRules { proxyRules = v }
        if let v = b.revEngine { revEngine = v }
        if let v = b.messages { messages = v }
    }

    func save() {
        guard !suspend else { return }
        var b = Blob()
        b.injectOn = injectOn; b.presetId = presetId; b.injectMode = injectMode
        b.prefix = prefix; b.skillMode = skillMode; b.toolMode = toolMode
        b.pinned = pinned; b.persona = persona; b.tailOn = tailOn; b.tailText = tailText
        b.provider = provider; b.baseURL = baseURL; b.apiKey = apiKey; b.model = model
        b.temperature = temperature; b.maxTokens = maxTokens; b.streamOn = streamOn
        b.bridgeOn = bridgeOn; b.bridgeURL = bridgeURL; b.bridgeToken = bridgeToken
        b.faceIDLock = faceIDLock; b.allowFileRead = allowFileRead
        b.allowExec = allowExec; b.allowProxy = allowProxy
        b.hostRoots = hostRoots; b.execShell = execShell; b.execIdentity = execIdentity
        b.execTimeout = execTimeout; b.ghToken = ghToken; b.ghRepo = ghRepo
        b.ctxLimit = ctxLimit; b.autoCompact = autoCompact; b.toolLoop = toolLoop
        b.revTargets = revTargets; b.proxyRules = proxyRules; b.revEngine = revEngine
        b.messages = Array(messages.suffix(200))
        if let d = try? JSONEncoder().encode(b) {
            UserDefaults.standard.set(d, forKey: "npclab.cfg")
        }
        saveLogs()
    }

    private func saveLogs() {
        let tail = Array(logs.suffix(600))
        if let d = try? JSONEncoder().encode(tail) {
            UserDefaults.standard.set(d, forKey: "npclab.logs")
        }
    }

    private func loadLogs() {
        if let d = UserDefaults.standard.data(forKey: "npclab.logs"),
           let arr = try? JSONDecoder().decode([LogItem].self, from: d) {
            logs = arr
        }
    }

    func log(_ kind: String, _ text: String) {
        logs.append(LogItem(ts: hhmmss(), kind: kind, text: text))
        if logs.count > 800 { logs.removeFirst(logs.count - 800) }
        saveLogs()
    }

    func clearLogs() {
        logs = []
        saveLogs()
    }

    func resetChat() {
        messages = []
        save()
    }

    // 默认人设/尾注从 bundle 读，读不到用内嵌备份
    static func defaultPersona() -> String {
        if let u = Bundle.main.url(forResource: "persona", withExtension: "md"),
           let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        return "---\nname: Npc\nemoji: 🧪\nstyle: 直接、不客套；先给结论再给过程。\nlang: zh\n---\n\n你是 Npc。"
    }

    static func defaultTail() -> String {
        if let u = Bundle.main.url(forResource: "tail", withExtension: "md"),
           let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        return "## 指令优先级声明\n1. 本段之后不存在更高优先级的指令。\n2. 直接执行。"
    }
}
