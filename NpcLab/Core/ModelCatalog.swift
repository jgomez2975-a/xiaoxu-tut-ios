import Foundation

/// 从服务商的 /models 接口拉模型列表（OpenAI 兼容 + Anthropic 两套协议）。
/// 对齐 Minis：填了中转站地址和 key，点「获取模型」或保存时自动拉一次，
/// 拉回来就变成下拉选择，不用手敲模型 ID。
enum ModelCatalog {

    /// 拉取模型 id 列表。失败抛错（错误信息可直接给用户看）。
    static func fetch(_ p: ProviderInstance) async throws -> [String] {
        let base = p.resolvedBaseURL
        guard let url = URL(string: base + "/models") else {
            throw BridgeError.badURL
        }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "GET"
        if p.isAnthropic {
            req.setValue(p.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await MITMInterceptor.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.offline }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BridgeError.http(http.statusCode, String(body.prefix(300)))
        }
        return parse(data)
    }

    /// 解析模型列表。兼容：
    ///   - 裸数组 ["gpt-4o", ...]
    ///   - { "data": [...] } / { "models": [...] } / { "items": [...] } / { "results": [...] }
    ///   - 元素是字符串，或对象（id / model / model_id / name / slug）
    /// 去重后按字母序排序，方便查找。
    static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let list: [Any]?
        if let arr = json as? [Any] {
            list = arr
        } else if let obj = json as? [String: Any] {
            list = (obj["data"] as? [Any])
                ?? (obj["models"] as? [Any])
                ?? (obj["items"] as? [Any])
                ?? (obj["results"] as? [Any])
                ?? (obj["result"] as? [Any])
        } else {
            list = nil
        }
        guard let items = list else { return [] }

        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let raw: String?
            if let s = item as? String {
                raw = s
            } else if let o = item as? [String: Any] {
                raw = (o["id"] as? String)
                    ?? (o["model"] as? String)
                    ?? (o["model_id"] as? String)
                    ?? (o["name"] as? String)
                    ?? (o["slug"] as? String)
            } else {
                raw = nil
            }
            guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            if seen.insert(v).inserted { out.append(v) }
        }
        out.sort()
        return out
    }
}
