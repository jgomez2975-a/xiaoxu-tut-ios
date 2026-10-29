//
//  Workspace.swift
//  NpcLab
//
//  App Group 里的共享工作区。三个扩展和主 App 都从这里读写：
//
//      group.com.npclab.client/
//        ├── Inbox/      别的 App 分享进来的（Share 扩展写，主 App 扫）
//        ├── Workspace/  用户自己的文件（文件 App 里能看到）
//        └── w.*         Widget 用的状态键
//
//  没有 App Group 的时候（免签装、没配 profile）整个功能会静默降级：
//  Inbox 退回临时目录，文件 App 那个位置不出来，Widget 显示"未启动"。
//  不会崩，也不会假装能用。
//

import Foundation
import FileProvider

enum Workspace {

    static let groupID = "group.com.npclab.client"
    static let providerDomain = "com.npclab.client.workspace"

    /// App Group 容器根。没配通就是 nil。
    static var groupURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// 分享收件箱
    static var inbox: URL? {
        guard let g = groupURL else { return nil }
        let u = g.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 用户工作区（文件 App 里看到的那个位置）
    static var work: URL? {
        guard let g = groupURL else { return nil }
        let u = g.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: - 收件箱

    /// Inbox 里当前的条目
    static func inboxItems() -> [URL] {
        guard let d = inbox else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: d, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    /// 把一个收件箱文件搬进工作区，返回落地路径
    @discardableResult
    static func adopt(_ src: URL) -> URL? {
        guard let w = work else { return nil }
        let dst = unique(in: w, name: src.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: src, to: dst)
            return dst
        } catch {
            // 跨卷时 move 会失败，退回拷贝
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                try? FileManager.default.removeItem(at: src)
                return dst
            }
            return nil
        }
    }

    private static func unique(in dir: URL, name: String) -> URL {
        var dst = dir.appendingPathComponent(name)
        var i = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dst.path) {
            let n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            dst = dir.appendingPathComponent(n)
            i += 1
        }
        return dst
    }

    // MARK: - 文件 App 里的那个位置

    /// 注册 File Provider domain。重复调用无副作用。
    /// 系统「文件」App → 浏览 → 位置 → 会出现 "小徐TuT 工作区"。
    static func registerFileProvider() {
        guard groupURL != nil else { return }   // 没有 App Group 就没意义

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: providerDomain),
            displayName: "小徐TuT 工作区")

        NSFileProviderManager.getDomains { list in
            if list.contains(where: { $0.identifier == domain.identifier }) {
                return
            }
            NSFileProviderManager.add(domain) { err in
                if let err = err {
                    NSLog("[NpcLab] FileProvider 注册失败: \(err.localizedDescription)")
                }
            }
        }
    }

    static func unregisterFileProvider() {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: providerDomain),
            displayName: "小徐TuT 工作区")
        NSFileProviderManager.remove(domain) { _ in }
    }
}
