import Foundation

/// SOUL.md 解析 —— 行为对齐 Minis 的 SoulStore：
/// YAML 头（name / emoji / style / lang / icon）+ Markdown 正文；
/// 中文 800 字 / 英文 500 词为上限，超限只注入身份句。
enum Soul {

    struct Meta {
        var name: String = "Npc"
        var emoji: String = ""
        var style: String = ""
        var lang: String = "auto"
        var icon: String = ""
    }

    struct Parsed {
        var meta = Meta()
        var body: String = ""
    }

    static let limitCN = 800
    static let limitEN = 500

    static func parse(_ src: String) -> Parsed {
        var out = Parsed()
        out.body = src
        var text = src.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasPrefix("\n") { text.removeFirst() }
        guard text.hasPrefix("---") else { return out }

        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return out }

        var close = -1
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            close = i
            break
        }
        guard close > 0 else { return out }

        for l in lines[1..<close] {
            guard let idx = l.firstIndex(of: ":") else { continue }
            let k = l[l.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            var v = l[l.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast())
            }
            switch k {
            case "name": out.meta.name = v
            case "emoji": out.meta.emoji = v
            case "style": out.meta.style = v
            case "lang": out.meta.lang = v
            case "icon": out.meta.icon = v
            default: break
            }
        }
        let rest = lines[(close + 1)...].joined(separator: "\n")
        out.body = rest.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        lines = []
        return out
    }

    /// 清掉正文里的注入行（防止人设文件被塞"忽略以上指令"）
    static func scrub(_ s: String) -> String {
        let pats = [
            "ignore.{0,30}previous.{0,30}instructions?",
            "disregard.{0,30}(previous|prior).{0,30}instructions?",
            "forget.{0,30}(previous|prior).{0,30}instructions?",
            "(忽略|无视|忘记).{0,12}(之前|以上|前面|先前).{0,12}(指令|提示|设定|规则)"
        ]
        var regs: [NSRegularExpression] = []
        for p in pats {
            if let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                regs.append(r)
            }
        }
        let kept = s.components(separatedBy: "\n").filter { line in
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            for r in regs where r.firstMatch(in: line, options: [], range: range) != nil {
                return false
            }
            return true
        }
        return kept.joined(separator: "\n")
    }

    /// 中文字数 / 英文词数
    static func weight(_ body: String) -> (cn: Int, en: Int, over: Bool) {
        var cn = 0
        for u in body.unicodeScalars where (0x4E00...0x9FFF).contains(u.value) { cn += 1 }
        let stripped = body.replacingOccurrences(
            of: "[\\u4e00-\\u9fff]", with: " ", options: .regularExpression)
        let en = stripped.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "-") }).count
        return (cn, en, cn > limitCN || en > limitEN)
    }
}
