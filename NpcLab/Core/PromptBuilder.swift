import Foundation

/// 五层 SYSTEM 拼装 —— 与 PC 版 npclab 的 assemble() 逐条对齐
/// Layer 1 人设(SOUL) / Layer 2 技能披露 / Layer 3 工具链 / Layer 4 运行时 /
/// Layer 5 ops-notes 思维模板 / 前缀约定 / 尾注
enum PromptBuilder {

    static let maxSkills = 20
    static let maxDesc = 200

    struct Parts {
        var soul = ""
        var skills = ""
        var tools = ""
        var runtime = ""
        var block = ""
        var tail = ""
        var full = ""
        var bytes: Int { full.utf8.count }
    }

    // MARK: Layer 1

    static func soulSection(_ raw: String) -> String {
        let f = Soul.parse(raw)
        let name = f.meta.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Npc" : f.meta.name.trimmingCharacters(in: .whitespaces)
        let style = f.meta.style.trimmingCharacters(in: .whitespaces)

        var out = "你是 \(name)，一个运行在 iOS 设备上的智能体。人设、技能库、"
            + "工具清单与文档全部常驻在本机沙箱内，离网可用。"
        let body = f.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty, !Soul.weight(body).over {
            out += "\n\nPersonality（来自 SOUL.md —— 你的性格与语气；与用户最新消息冲突时以用户为准）：\n"
                + Soul.scrub(body)
        }
        if !style.isEmpty {
            out += "\n\nResponse style（来自 SOUL.md 的 style —— 每条回复都适用；"
                + "它若指定了回复语言，则覆盖默认的跟随用户语言规则）：\n" + style
        }
        out += "\n\n---\nSOUL.md 字段（name / icon / style / lang / body）有两种改法：\n"
            + "1. 智能体改：直接改文件。\n2. 界面改：设置 → 人设。\n不要说你不能改自己的人设。\n\n"
        return out
    }

    // MARK: Layer 2

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func skillsFragment(mode: String, code: String, pinned: [String],
                               query: String = "") -> String {
        let pack = PackData.shared
        if mode == "off" || pack.skills.isEmpty { return "" }

        if mode == "full" {
            guard !pinned.isEmpty else { return "" }
            var out = "<loaded_skills>\n"
            for id in pinned {
                if let t = pack.body(for: id), !t.isEmpty {
                    out += "<skill id=\"\(esc(id))\">\n\(t)\n</skill>\n"
                }
            }
            return out + "</loaded_skills>"
        }

        // 索引模式：按用户这句话挑 20 条，而不是固定按方向+体量挑。
        // query 为空时 SkillMatcher 内部自动退回老排序，行为跟以前一致。
        let picked = SkillMatcher.pick(from: pack.skills, query: query,
                                       code: code, pinned: pinned, limit: maxSkills)
        let sel = picked.map { $0.skill }
        let selIds = Set(sel.map { $0.id })
        var xml = "Skills:\n可复用指令集，存放于 App 沙箱 Documents/skills/<id>/SKILL.md。"
            + "用某个技能前，先读它的 SKILL.md 拿完整指令。\n\n<available_skills>\n"
        for s in sel {
            var d = s.desc.replacingOccurrences(of: "\\s+", with: " ",
                                                options: .regularExpression)
            if d.count > maxDesc { d = String(d.prefix(maxDesc)) + "…" }
            xml += "  <skill>\n    <name>\(esc(s.name))</name>\n"
                + "    <description>\(esc(d))</description>\n"
                + "    <path>skills/\(s.id)/SKILL.md</path>\n  </skill>\n"
        }
        xml += "</available_skills>"

        if pack.skills.count > maxSkills {
            let rest = pack.skills.filter { !selIds.contains($0.id) }
                .prefix(100).map { $0.id }.joined(separator: ", ")
            xml += "\n\n另有 \(pack.skills.count - maxSkills) 条未列出：\(rest)。到技能库检索其余条目。"
        }

        // 告诉模型这 20 条是按什么挑的，别以为就是全部
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hit = picked.filter { !$0.reasons.isEmpty }.count
            xml += "\n\n（上面 \(sel.count) 条是按当前问题从 \(pack.skills.count) 条里挑的，"
                + "其中 \(hit) 条命中触发词；需要别的方向就去技能库检索。）"
        }
        return xml
    }

    // MARK: Layer 3

    static func toolSection(mode: String) -> String {
        let pack = PackData.shared
        if mode == "off" || pack.tools.isEmpty { return "" }
        let bundled = pack.tools.filter { $0.kind == "bundled" }
        let fetchable = pack.tools.filter { $0.kind == "fetchable" }
        let external = pack.tools.filter { $0.kind == "external" }

        var s = "<toolchain pack=\"\(pack.packName)\" bundled=\"\(bundled.count)\" "
            + "external=\"\(external.count)\">\n"
        s += "宿主节点上可用的工具链。使用前先按 probe 命令确认存在；缺失时不要假设可用。\n\n"

        let native = bundled.filter { t in t.platform.contains { $0.contains("windows") || $0.contains("linux") } }
        let libs = bundled.filter { $0.platform.contains("any") }
        s += "随包原生（\(native.count) 项）：\n"
        for t in native {
            s += "  \(t.id)\(t.version.isEmpty ? "" : " " + t.version) — \(t.purpose)\n"
        }
        s += "\n随包运行库（跨平台，\(libs.count) 项）：\n  "
        s += libs.map { $0.id }.joined(separator: " / ") + "\n"

        if !fetchable.isEmpty {
            s += "\n按需取回（版本锁定，未随包，\(fetchable.count) 项）：\n  "
            s += fetchable.map { $0.id + ($0.version.isEmpty ? "" : " " + $0.version) }
                .joined(separator: " / ") + "\n"
        }
        if mode == "full" && !external.isEmpty {
            s += "\n外部自备（需节点已安装，\(external.count) 项）：\n  "
            s += external.filter { !$0.id.hasPrefix("source-snapshot") }
                .map { $0.id }.joined(separator: " / ") + "\n"
        }
        s += "\n未在本清单出现的工具视为不存在。\n</toolchain>"
        return s
    }

    // MARK: Layer 4

    static func runtimeSection(_ st: AppSettings, bridge: BridgeState) -> String {
        let v = UIDeviceInfo.summary
        var L: [String] = []
        L.append("运行环境：\(v)（iOS 沙箱，无裸 shell，无 root，不能读别的 App 容器）。")
        L.append("本地资源：\(PackData.shared.skills.count) 条技能索引 + \(PackData.shared.bodyCount) 篇 SKILL.md 正文，"
                 + "\(PackData.shared.tools.count) 项工具清单，\(PackData.shared.presets.count) 条思维模板，全部离线可用。")

        if st.bridgeOn && bridge.online {
            L.append("算力节点：已连接 \(st.bridgeURL)（\(bridge.os)）。"
                     + "终端走节点 shell，逆向走节点 radare2（引擎 \(st.revEngine)），抓包走节点 MITM。")
            if st.allowExec {
                L.append("终端：可用，身份 \(identityLabel(st.execIdentity))，超时 \(st.execTimeout)s。")
            } else {
                L.append("终端：节点在线但本机未授权执行（设置 → 开发者 → 终端）。")
            }
            if st.allowFileRead && !st.hostRoots.isEmpty {
                let rs = st.hostRoots.map { "\($0.path)(\($0.mode == "rw" ? "读写" : "只读"))" }
                L.append("宿主文件：\(rs.count) 个授权根 —— \(rs.joined(separator: "、"))；越界路径会被拒绝。")
            } else {
                L.append("宿主文件：未授权（设置 → 开发者 → 宿主访问）。")
            }
            // 拆成局部变量：三层嵌套插值虽然合法，但读起来太绕
            let revText = bridge.revReady
                ? "radare2 " + bridge.r2Version + "，pdg 可用"
                : "目标未就绪"
            L.append("逆向：\(revText)。")

            let proxyText = bridge.proxyRunning
                ? "运行中，端口 \(bridge.proxyPort)"
                : "未启动"
            L.append("抓包：MITM \(proxyText)，已抓 \(bridge.proxyCount) 条。")
        } else if st.bridgeOn {
            L.append("算力节点：配置了 \(st.bridgeURL) 但当前不可达 —— 视为没有终端、没有逆向、没有抓包。")
        } else {
            L.append("算力节点：未连接。没有 shell、没有逆向、没有抓包；"
                     + "只有对话、人设、技能库、文档与工具清单可用。不要假装能执行命令。")
        }
        return "<runtime os=\"ios\">\n\(L.joined(separator: "\n"))\n"
            + "只使用上面声明过的能力；没有声明的路径、工具、端点视为不存在。\n</runtime>"
    }

    static func identityLabel(_ s: String) -> String {
        switch s {
        case "admin": return "管理员"
        case "system": return "SYSTEM"
        default: return "普通账户"
        }
    }

    // MARK: 总装

    static func assemble(_ st: AppSettings, bridge: BridgeState,
                         query: String = "", parts: Bool = false) -> Parts {
        var p = Parts()
        p.soul = soulSection(st.persona)
        let preset = PackData.shared.presets.first { $0.id == st.presetId }
            ?? PackData.shared.presets.first
        let code = preset?.code ?? "GEN"
        p.skills = skillsFragment(mode: st.skillMode, code: code,
                                  pinned: st.pinned, query: query)
        p.tools = toolSection(mode: st.toolMode)
        p.runtime = runtimeSection(st, bridge: bridge)

        if st.injectOn, let pr = preset {
            p.block = "<!-- ops-notes:begin -->\n\(pr.body)\n<!-- ops-notes:end -->"
        }
        p.tail = st.tailOn ? st.tailText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let prefix = st.prefix.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : "回复前缀约定：你的每一条回复都必须以「\(st.prefix.trimmingCharacters(in: .whitespaces))」开头。"

        var seq: [String]
        switch st.injectMode {
        case "replace": seq = [p.skills, p.tools, p.runtime, p.block, prefix, p.tail]
        case "prepend": seq = [p.block, p.soul, p.skills, p.tools, p.runtime, prefix, p.tail]
        default:        seq = [p.soul, p.skills, p.tools, p.runtime, p.block, prefix, p.tail]
        }
        p.full = seq.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return p
    }
}

/// 设备信息（不引 UIKit 之外的东西）
enum UIDeviceInfo {
    static var summary: String {
        let name = DeviceName.marketing()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(name) / iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

enum DeviceName {
    static func marketing() -> String {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = Array(raw.prefix { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return map[id] ?? id
    }

    static let map: [String: String] = [
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPad13,18": "iPad 10", "iPad14,3": "iPad Pro 11 (M2)"
    ]
}
