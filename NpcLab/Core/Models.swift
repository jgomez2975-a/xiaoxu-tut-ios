import Foundation

// MARK: - 技能

struct Skill: Identifiable, Hashable, Decodable {
    let id: String
    let code: String
    let domain: String
    let name: String
    let desc: String
    let bytes: Int
    let lines: Int
    let triggers: [String]

    enum CodingKeys: String, CodingKey {
        case id, code, domain, name, desc, bytes, lines, triggers
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        code = (try? c.decode(String.self, forKey: .code)) ?? "GEN"
        domain = (try? c.decode(String.self, forKey: .domain)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        lines = (try? c.decode(Int.self, forKey: .lines)) ?? 0
        triggers = (try? c.decode([String].self, forKey: .triggers)) ?? []
    }
}

struct Domain: Identifiable, Hashable, Decodable {
    let code: String
    let name: String
    let desc: String
    let count: Int
    var id: String { code }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        code = (try? c.decode(String.self, forKey: .code)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? code
        desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
    enum CodingKeys: String, CodingKey { case code, name, desc, count }
}

struct SkillPack: Decodable {
    let pack: String
    let total: Int
    let domains: [Domain]
    let skills: [Skill]

    enum CodingKeys: String, CodingKey { case pack, total, domains, skills }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pack = (try? c.decode(String.self, forKey: .pack)) ?? "NPC-team"
        domains = (try? c.decode([Domain].self, forKey: .domains)) ?? []
        skills = (try? c.decode([Skill].self, forKey: .skills)) ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? skills.count
    }
}

// MARK: - 工具链

struct Tool: Identifiable, Hashable, Decodable {
    let id: String
    let kind: String
    let kindLabel: String
    let group: String
    let purpose: String
    let platform: [String]
    let version: String
    let size: String
    let path: String
    let upstream: String
    let install: String
    let verify: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case id, kind, kindLabel, group, purpose, platform, version, size, path, upstream, install, verify, note
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "external"
        kindLabel = (try? c.decode(String.self, forKey: .kindLabel)) ?? kind
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        purpose = (try? c.decode(String.self, forKey: .purpose)) ?? ""
        platform = (try? c.decode([String].self, forKey: .platform)) ?? []
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        size = (try? c.decode(String.self, forKey: .size)) ?? ""
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        upstream = (try? c.decode(String.self, forKey: .upstream)) ?? ""
        install = (try? c.decode(String.self, forKey: .install)) ?? ""
        verify = (try? c.decode(String.self, forKey: .verify)) ?? ""
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

struct ToolGroup: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let desc: String
    let count: Int

    enum CodingKeys: String, CodingKey { case id, name, desc, count }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

struct ToolPack: Decodable {
    let pack: String
    let total: Int
    let groups: [ToolGroup]
    let tools: [Tool]

    enum CodingKeys: String, CodingKey { case pack, total, groups, tools }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pack = (try? c.decode(String.self, forKey: .pack)) ?? "NPC-team"
        groups = (try? c.decode([ToolGroup].self, forKey: .groups)) ?? []
        tools = (try? c.decode([Tool].self, forKey: .tools)) ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? tools.count
    }
}

// MARK: - 思维模板

struct Preset: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let tag: String
    let code: String
    let desc: String
    let body: String
    let bytes: Int

    enum CodingKeys: String, CodingKey { case id, name, tag, code, desc, body, bytes }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        tag = (try? c.decode(String.self, forKey: .tag)) ?? ""
        code = (try? c.decode(String.self, forKey: .code)) ?? "GEN"
        desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? body.utf8.count
    }
}

struct PresetFile: Decodable {
    let presets: [Preset]
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        presets = (try? c.decode([Preset].self, forKey: .presets)) ?? []
    }
    enum CodingKeys: String, CodingKey { case presets }
}

// MARK: - 文档

struct PackDoc: Identifiable, Hashable, Decodable {
    let path: String
    let name: String
    let group: String
    let title: String
    let desc: String
    let size: String
    let body: String
    var id: String { path }

    enum CodingKeys: String, CodingKey { case path, name, group, title, desc, size, body }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? name
        desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
        size = (try? c.decode(String.self, forKey: .size)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
    }
}

struct DocFile: Decodable {
    let docs: [PackDoc]
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        docs = (try? c.decode([PackDoc].self, forKey: .docs)) ?? []
    }
    enum CodingKeys: String, CodingKey { case docs }
}

// MARK: - 对话

struct ChatMessage: Identifiable, Hashable, Codable {
    var id = UUID()
    var role: String          // user / assistant
    var text: String
    var ts = Date()
    var error: Bool = false
    var tokens: Int = 0
    /// 图片附件，存的是 Documents/attachments/ 下的文件名，不是 base64。
    /// 见 Core/Attachment.swift。
    var images: [String] = []

    enum CodingKeys: String, CodingKey { case id, role, text, ts, error, tokens, images }

    init(role: String, text: String, error: Bool = false, tokens: Int = 0,
         images: [String] = []) {
        self.role = role
        self.text = text
        self.error = error
        self.tokens = tokens
        self.images = images
    }

    /// 手写解码：`images` 是后加的字段，老存档里没有。
    /// 交给合成的 Decodable 会因为缺 key 整条抛错，把旧聊天记录一起带崩。
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(String.self, forKey: .role)) ?? "user"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        ts = (try? c.decode(Date.self, forKey: .ts)) ?? Date()
        error = (try? c.decode(Bool.self, forKey: .error)) ?? false
        tokens = (try? c.decode(Int.self, forKey: .tokens)) ?? 0
        images = (try? c.decode([String].self, forKey: .images)) ?? []
    }
}

// MARK: - 模型服务商（对齐 Minis 的多 Provider 实例）

/// 一个可用的 LLM 服务商实例。Minis 的模型体系是「多 provider 并存」，
/// 每个实例绑定一个服务商 + 独立 baseURL + key + 模型，可增删、可启用/禁用。
struct ProviderInstance: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String = ""            // 唯一显示名 / label
    var providerType: String = "openai"  // openai / anthropic / openRouter / xAI / gemini / kimiCode
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var model: String = "gpt-4o"
    var isEnabled: Bool = true

    /// 协议只有两类：Anthropic Messages API，其余全是 OpenAI 兼容 /chat/completions
    var isAnthropic: Bool { providerType == "anthropic" }

    /// 显示用服务商名
    var providerLabel: String {
        switch providerType {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "openRouter": return "OpenRouter"
        case "xAI": return "xAI (Grok)"
        case "gemini": return "Google Gemini"
        case "kimiCode": return "Kimi Code"
        case "githubCopilot": return "GitHub Copilot"
        default: return providerType
        }
    }

    /// 该服务商的默认 baseURL（新建实例时预填）
    static func defaultBaseURL(_ type: String) -> String {
        switch type {
        case "anthropic": return "https://api.anthropic.com/v1"
        case "openRouter": return "https://openrouter.ai/api/v1"
        case "xAI": return "https://api.x.ai/v1"
        case "gemini": return "https://generativelanguage.googleapis.com/v1beta"
        case "kimiCode": return "https://api.kimi.com/coding/v1"
        case "githubCopilot": return "https://api.githubcopilot.com"
        default: return "https://api.openai.com/v1"
        }
    }

    /// 该服务商的默认模型名（新建实例时预填）
    static func defaultModel(_ type: String) -> String {
        switch type {
        case "anthropic": return "claude-sonnet-4-5"
        case "openRouter": return "openai/gpt-4o"
        case "xAI": return "grok-3"
        case "gemini": return "gemini-2.5-pro"
        case "kimiCode": return "kimi-k2"
        default: return "gpt-4o"
        }
    }

    static let providerTypes: [String] = [
        "openai", "anthropic", "openRouter", "xAI", "gemini", "kimiCode"
    ]
}

// MARK: - 节点桥

struct HostRoot: Identifiable, Hashable, Codable {
    var id = UUID()
    var path: String = ""
    var mode: String = "ro"    // ro / rw
}

struct RevTarget: Identifiable, Hashable, Codable {
    var key: String = ""        // 节点侧目标 id（md5 前 10 位）
    var path: String = ""
    var label: String = ""
    var arch: String = ""
    var size: String = ""

    var id: String { key.isEmpty ? path : key }
    /// 调用节点时优先用 key，没有就退回 path（服务端两者都认）
    var callKey: String { key.isEmpty ? path : key }
}

struct ProxyRule: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String = ""
    var url: String = ""            // 正则，匹配完整 URL
    var phase: String = "both"      // req / res / both
    var bodyMatch: String = ""      // 正则，命中才替换
    var bodyReplace: String = ""
    var setHeader: String = ""      // 每行 "K: V"
    var on: Bool = true
}

struct LogItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var ts: String
    var kind: String
    var text: String
}

/// 小工具
func hhmmss(_ d: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

func humanBytes(_ n: Int) -> String {
    let u = ["B", "KB", "MB", "GB"]
    var v = Double(n), i = 0
    while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i])
}
