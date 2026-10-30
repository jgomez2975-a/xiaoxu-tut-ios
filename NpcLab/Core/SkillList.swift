import Foundation

/// 「你会什么技能」这类技能清单查询的本地兜底。
///
/// 为什么要兜底：技能清单是纯本地数据（skills.json 随包），问「你会什么技能」
/// 本应秒回。但走「对话内工具」时，模型（尤其小模型如 deepseek-flash）容易
/// 反复调 search_skills 不收敛，6 轮触顶只吐「没有拿到结果」。本地直接答：
/// 省 token、不出错、没配 Key 也能回。
enum SkillList {

    /// 命中技能清单查询就返回答案；否则返回 nil 走正常模型流程。
    static func answerIfAsked(_ text: String) -> String? {
        let norm = normalize(text)
        guard !norm.isEmpty else { return nil }

        // 强命中：明确的「问技能清单」短语，直接兜底，不看长度
        let exact = [
            "你会什么技能", "你有什么技能", "你会哪些技能", "有哪些技能",
            "技能有哪些", "技能列表", "列出技能", "列一下技能", "你会啥技能",
            "技能都有啥", "技能清单", "都有什么技能", "你会什么本事", "技能有几条"
        ]
        if exact.contains(where: { norm.contains($0) }) {
            return answer()
        }

        // 弱命中：问「会什么 / 能干什么」这类，要求整句很短且没带具体任务，
        // 否则「你能做什么帮我逆向这个 app」会被误兜底。
        let broad = [
            "你会什么", "你会啥", "能干什么", "你能干什么", "你能做什么",
            "你能干啥", "你会哪些", "有什么能力", "有什么功能", "你能干嘛"
        ]
        // 任务词用多字词，别用单字（「做/查/看」会误伤「你能做什么」这种问句）
        let task = [
            "帮我", "给我", "教我", "分析", "逆向", "破解", "审计", "脱壳",
            "免杀", "渗透", "攻击", "利用", "看看", "打开", "处理", "写个", "查一下"
        ]
        if broad.contains(where: { norm.contains($0) }),
           norm.count <= 6,
           !task.contains(where: { norm.contains($0) }) {
            return answer()
        }
        return nil
    }

    /// 生成本地技能清单回答：按方向分组 + 每个方向列代表技能。
    static func answer() -> String {
        let pack = PackData.shared
        let skills = pack.skills
        let domains = pack.domains

        var lines: [String] = []
        lines.append("我内置 \(skills.count) 条技能，分 \(domains.count) 个方向，"
                     + "全部离线可用。直接说目标，我会自动挑对应技能干活：\n")

        for d in domains {
            let inDomain = skills.filter { $0.code == d.code }
            let reps = inDomain.prefix(3).map { $0.id }
            lines.append("**\(d.name)**（\(d.code) · \(inDomain.count) 条）— \(d.desc)")
            lines.append("  例：\(reps.joined(separator: "、"))")
        }

        lines.append("\n想看某条技能全文，说「看技能 <id>」；按关键词找，说「搜技能 <关键词>」。")
        return lines.joined(separator: "\n")
    }

    /// 归一化：小写、去空白与标点，只留字母数字（含中文）。
    private static func normalize(_ s: String) -> String {
        let alnum = CharacterSet.alphanumerics
        var out = ""
        for ch in s.lowercased() {
            if ch.unicodeScalars.allSatisfy({ alnum.contains($0) }) {
                out.append(ch)
            }
        }
        return out
    }
}
