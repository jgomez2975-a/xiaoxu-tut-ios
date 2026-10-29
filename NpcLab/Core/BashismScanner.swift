//
//  BashismScanner.swift
//  NpcLab
//
//  终端里贴 bash 脚本进来，在 Alpine 的 busybox ash 下十有八九会翻车，
//  而且最坑的是 tier S 那些——不报错，算出来的结果却是错的。
//
//  规则放在 Resources/bashism_rules.json，逐行匹配。命中只提示不拦截：
//  用户可能真装了 bash（apk add bash），也可能是故意的。
//

import Foundation

// MARK: - 命中

struct BashismHit: Identifiable, Hashable {
    let id: String          // 规则 id + 行号
    let rule: String
    let tier: String        // S / E / T1
    let line: Int           // 1 起
    let snippet: String
    let hint: String

    var badge: String {
        switch tier {
        case "S":  return "静默算错"
        case "E":  return "会报错"
        default:   return "可能有问题"
        }
    }
}

// MARK: - 规则

private struct Rule: Decodable {
    let id: String
    let tier: String
    let pattern: String
    let hint: String
}

private struct RuleFile: Decodable {
    let schemaVersion: Int
    let target: String
    let rules: [Rule]
}

// MARK: - 扫描器

enum BashismScanner {

    private static var rules: [Rule] = []
    private static var regexes: [String: NSRegularExpression] = [:]
    private static var loaded = false

    /// 只加载一次，终端里每条命令都要用
    private static func load() {
        guard !loaded else { return }
        loaded = true

        guard let url = Bundle.main.url(forResource: "bashism_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RuleFile.self, from: data)
        else { return }

        rules = file.rules
        for r in file.rules {
            // 正则写错不该让整个功能挂掉，坏一条就跳过
            if let re = try? NSRegularExpression(pattern: r.pattern, options: []) {
                regexes[r.id] = re
            }
        }
    }

    /// 扫一段脚本，返回所有命中（按行号排序）
    static func scan(_ script: String) -> [BashismHit] {
        load()
        guard !rules.isEmpty else { return [] }

        var hits: [BashismHit] = []
        let lines = script.components(separatedBy: "\n")

        for (i, raw) in lines.enumerated() {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 注释行和空行不用扫
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)

            for r in rules {
                guard let re = regexes[r.id] else { continue }
                guard re.firstMatch(in: line, options: [], range: range) != nil else { continue }

                hits.append(BashismHit(
                    id: "\(r.id)#\(i + 1)",
                    rule: r.id,
                    tier: r.tier,
                    line: i + 1,
                    snippet: trimmed.count > 90
                        ? String(trimmed.prefix(90)) + "…"
                        : trimmed,
                    hint: r.hint))
            }
        }
        return hits.sorted { $0.line < $1.line }
    }

    /// 只挑真正值得打断用户的（S 和 E），T1 那类放进详情
    static func serious(_ hits: [BashismHit]) -> [BashismHit] {
        hits.filter { $0.tier == "S" || $0.tier == "E" }
    }

    /// 给终端输出用的一行摘要。没有严重问题就返回 nil。
    static func summary(_ script: String) -> String? {
        let hits = serious(scan(script))
        guard !hits.isEmpty else { return nil }

        var out = "[bashism] 这段脚本在 busybox ash 下有 \(hits.count) 处会出问题：\n"
        for h in hits.prefix(4) {
            out += "  第 \(h.line) 行 · \(h.badge) · \(h.snippet)\n"
        }
        if hits.count > 4 {
            out += "  …还有 \(hits.count - 4) 处\n"
        }
        if let first = hits.first {
            out += "  → \(first.hint)\n"
        }
        out += "  （只是提示，仍然照原样执行；装了 bash 的话可以 bash -c 跑）"
        return out
    }
}
