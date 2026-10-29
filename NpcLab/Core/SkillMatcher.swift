//
//  SkillMatcher.swift
//  NpcLab
//
//  按用户这句话，从 897 条技能里把最该看到的挑出来塞进 SYSTEM。
//
//  为什么要有：Layer 2 的技能索引固定只露 20 条（见 PromptBuilder.maxSkills），
//  以前是按「方向 + 置顶 + 体量」排，跟你问什么完全无关 —— 问「EDR 绕过」，
//  露出来的可能是 20 条最胖的免杀技能，真正对口的反而不在里面。
//
//  打分规则（跟 ranked() 的 1000/100/20 那套兼容，只在上面加语义分）：
//    置顶            +1000
//    方向命中        +100
//    trigger 整句命中 +200      用户原话里出现了技能声明的触发词
//    trigger 分词重叠 +40 / 个   中文 bigram、英文词
//    名称命中        +150
//    描述命中        +80
//    体量            最多 +20    体量大通常内容厚，微调
//
//  没有 NLP、没有分词库。中文用 bigram（连续两个字），英文按词边界。
//  对 897 条 × 十几个 trigger 的量，这个精度够用，而且是纯 CPU，微秒级。
//

import Foundation

enum SkillMatcher {

    /// 命中详情，UI 上可以显示「为什么推荐这条」
    struct Hit {
        let skill: Skill
        let score: Double
        let reasons: [String]
    }

    // MARK: 分词

    /// 中文 bigram + 英文/数字词 + 连字符标识符
    static func tokens(_ s: String) -> Set<String> {
        var out = Set<String>()
        let lower = s.lowercased()

        // 英文 / 数字 / 下划线 / 连字符 连续段
        var cur = ""
        for ch in lower {
            if (ch.isLetter && ch.isASCII) || ch.isNumber || ch == "_" || ch == "-" {
                cur.append(ch)
            } else {
                if cur.count >= 2 { out.insert(cur) }
                cur = ""
            }
        }
        if cur.count >= 2 { out.insert(cur) }

        // 中文 bigram（含单个汉字的词太少，两字起步）
        let chars = Array(lower)
        var i = 0
        while i < chars.count {
            if isHan(chars[i]) {
                if i + 1 < chars.count && isHan(chars[i + 1]) {
                    out.insert(String(chars[i...i + 1]))
                    i += 1
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }

    private static func isHan(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }

    /// 一个 trigger 能不能被 query 直接「整句」命中。
    /// 加边界判断，否则 trigger "sql" 会被 "mysql" 骗到。
    static func containsWhole(_ trigger: String, in query: String) -> Bool {
        let t = trigger.lowercased().trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        let q = query.lowercased()
        guard q.contains(t) else { return false }

        // 纯 ASCII trigger 要求两侧不是字母数字，避免子串误命中
        if t.allSatisfy({ $0.isASCII }) {
            var searchStart = q.startIndex
            while let r = q.range(of: t, range: searchStart..<q.endIndex) {
                let before = r.lowerBound > q.startIndex ? q[q.index(before: r.lowerBound)] : " "
                let after = r.upperBound < q.endIndex ? q[r.upperBound] : " "
                let okBefore = !(before.isLetter || before.isNumber)
                let okAfter = !(after.isLetter || after.isNumber)
                if okBefore && okAfter { return true }
                searchStart = r.upperBound
            }
            return false
        }
        return true
    }

    // MARK: 打分

    static func score(_ s: Skill, query: String, code: String, pinned: [String]) -> Hit {
        var sc = 0.0
        var why: [String] = []

        if pinned.contains(s.id) {
            sc += 1000
            why.append("置顶")
        }
        if s.code == code {
            sc += 100
            why.append("方向")
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            // 1. trigger 整句命中
            var whole = 0
            for t in s.triggers where containsWhole(t, in: q) {
                sc += 200
                whole += 1
                why.append("触发词「\(t)」")
                if whole >= 3 { break }        // 三条就够，再多是堆分
            }

            // 2. trigger 分词重叠
            let qTokens = tokens(q)
            if !qTokens.isEmpty && whole == 0 {
                var overlap = 0
                var seen = Set<String>()
                for t in s.triggers {
                    for tk in tokens(t) where qTokens.contains(tk) && !seen.contains(tk) {
                        seen.insert(tk)
                        overlap += 1
                    }
                }
                if overlap > 0 {
                    sc += min(160, Double(overlap) * 40)
                    why.append("关键词 ×\(overlap)")
                }
            }

            // 3. 名称 / 描述
            let nameLower = s.name.lowercased()
            if !nameLower.isEmpty, q.lowercased().contains(nameLower) {
                sc += 150
                why.append("名称")
            } else if !s.desc.isEmpty {
                let dt = tokens(s.desc)
                let hit = qTokens.intersection(dt).count
                if hit >= 2 {
                    sc += 80
                    why.append("描述相关")
                }
            }
        }

        // 4. 体量微调（跟 ranked() 一致）
        sc += min(20, Double(s.bytes) / 4000.0)

        return Hit(skill: s, score: sc, reasons: why)
    }

    // MARK: 入口

    /// 挑 limit 条最相关的。语义命中优先于纯方向/体量。
    static func pick(from skills: [Skill],
                     query: String,
                     code: String,
                     pinned: [String],
                     limit: Int) -> [Hit] {
        guard !skills.isEmpty, limit > 0 else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // 没输入（比如首次拼 SYSTEM）就退回老排序，省得白算 897 次
        if q.isEmpty {
            return skills.map { s -> Hit in
                var sc = 0.0
                if pinned.contains(s.id) { sc += 1000 }
                if s.code == code { sc += 100 }
                sc += min(20, Double(s.bytes) / 4000.0)
                return Hit(skill: s, score: sc, reasons: [])
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
        }

        // 先按体量粗筛：897 条全打分也要几毫秒，但没必要每条都算 bigram
        // 语义分只看有 token 交集的，所以直接全算，简单可靠
        var hits = skills.map { score($0, query: q, code: code, pinned: pinned) }
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.skill.id < b.skill.id          // 同分稳定排序，避免每次刷新跳动
        }
        return Array(hits.prefix(limit))
    }

    /// 给界面用：这条技能为什么被推荐
    static func explain(_ h: Hit) -> String {
        h.reasons.isEmpty ? "常规排序" : h.reasons.joined(separator: " · ")
    }
}
