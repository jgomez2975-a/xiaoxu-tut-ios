//
//  Attachment.swift
//  NpcLab
//
//  对话里的图片附件：存盘、压缩、转 base64、给两套协议拼格式。
//
//  为什么不把 base64 直接存在消息里：一条 2000 万像素的原图转 base64 是 10MB+ 字符串，
//  UserDefaults 存不下，而且每次列表滚动都要解码。这里只在沙箱里留一个文件，
//  消息里只记路径，真发请求时才读出来编码。
//
//  放在 Documents/attachments/ 而不是 tmp：tmp 会被系统随手清掉，
//  用户回头翻聊天记录发现图没了。
//

import Foundation
import UIKit

enum Attachment {

    /// 长边压到多少像素。4.0 够看清截图里的字，又不至于让一次请求冲到几 MB。
    static let maxEdge: CGFloat = 1600
    /// JPEG 质量
    static let quality: CGFloat = 0.82
    /// 单次最多带几张。多图很贵，也没必要。
    static let maxPerMessage = 4

    // MARK: 目录

    static var dir: URL {
        let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    // MARK: 存 / 读 / 删

    /// 把 UIImage 压好存盘，返回消息里要记的相对路径（只有文件名）
    @discardableResult
    static func save(_ image: UIImage) -> String? {
        let scaled = resize(image, maxEdge: maxEdge)
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        let name = "img-\(UUID().uuidString.prefix(8)).jpg"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func url(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    static func image(_ name: String) -> UIImage? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return UIImage(data: d)
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// 清掉没被任何消息引用的图（设置页「清理缓存」用）
    static func gc(keeping names: Set<String>) -> Int {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var n = 0
        for f in all where !names.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            n += 1
        }
        return n
    }

    static func totalBytes() -> Int64 {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return all.reduce(Int64(0)) { acc, f in
            let p = dir.appendingPathComponent(f).path
            let s = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
            return acc + (s ?? 0)
        }
    }

    // MARK: 缩放

    static func resize(_ img: UIImage, maxEdge: CGFloat) -> UIImage {
        let w = img.size.width, h = img.size.height
        let longest = max(w, h)
        guard longest > maxEdge, longest > 0 else { return img }
        let k = maxEdge / longest
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1                     // 按像素算，别叠 @2x/@3x
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: 编码

    static func base64(_ name: String) -> String? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return d.base64EncodedString()
    }

    static func dataURL(_ name: String) -> String? {
        guard let b = base64(name) else { return nil }
        return "data:image/jpeg;base64,\(b)"
    }

    // MARK: 两套协议的 content 片段

    /// OpenAI 兼容：{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}
    static func openAIPart(_ name: String) -> [String: Any]? {
        guard let u = dataURL(name) else { return nil }
        return ["type": "image_url", "image_url": ["url": u, "detail": "auto"]]
    }

    /// Anthropic：{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"..."}}
    static func anthropicPart(_ name: String) -> [String: Any]? {
        guard let b = base64(name) else { return nil }
        return ["type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": b]]
    }

    /// 消息里存的所有图都还在不在（有缺失就跳过，不至于整个请求失败）
    static func alive(_ names: [String]) -> [String] {
        names.filter { exists($0) }
    }
}
