//
//  RootfsOverlay.swift
//  NpcLab
//
//  把 default_mount.json 里的文件写进 rootfs。
//
//  为什么不直接把文件拷到 rootfs/data/ 下面：
//    fakefs 的 readdir 是拿文件名去 meta.db 查 inode 的（linux/fakefs.c:415），
//    查不到就 continue 跳过。从外面拷进去的文件根本没有 db 记录，
//    在内核眼里等于不存在，ls 看不到、也打不开。
//
//  所以只能反过来：让内核自己写。App 把内容 base64 编好，拼成一条 shell
//  命令交给 /bin/sh 执行，写入路径经过 VFS → fakefs，meta.db 自然被更新。
//     · 一条命令写完所有文件（10 个文件约 30KB，远低于 MAX_ARG_STRLEN 128KB）
//     · 用版本号标记，装过一次就跳过
//

import Foundation

// MARK: - JSON 结构

struct MountFile: Decodable {
    let path: String
    let mode: String
    let b64: String
}

struct MountManifest: Decodable {
    let version: Int
    let files: [MountFile]
}

// MARK: - 安装

enum RootfsOverlay {

    static let markerPrefix = "/root/.npclab-mount-v"

    /// 读出 bundle 里的清单
    static func manifest() -> MountManifest? {
        guard let url = Bundle.main.url(forResource: "default_mount", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(MountManifest.self, from: data)
        else { return nil }
        return m
    }

    /// 文件清单（给设置页显示）
    static func filePaths() -> [String] {
        manifest()?.files.map { $0.path } ?? []
    }

    /// 拼一条 shell 脚本：已装过就 exit 0，否则全量写一遍
    static func installScript() -> String? {
        guard let m = manifest(), !m.files.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("MARK=" + markerPrefix + "\(m.version)")
        lines.append("[ -f \"$MARK\" ] && exit 0")

        // 目录先去重建好，省得每个文件都 mkdir -p
        var seen = Set<String>()
        for f in m.files {
            let dir = (f.path as NSString).deletingLastPathComponent
            if seen.insert(dir).inserted {
                lines.append("mkdir -p \(quote(dir))")
            }
        }

        for f in m.files {
            let p = quote(f.path)
            // base64 字符集不含单引号，直接单引号包住是安全的
            lines.append("printf '%s' '\(f.b64)' | base64 -d > \(p)")
            lines.append("chmod \(f.mode) \(p) 2>/dev/null")
        }

        lines.append("echo \(m.version) > \"$MARK\"")
        lines.append("echo npclab-mount-ok")
        return lines.joined(separator: "\n")
    }

    /// 单引号包裹；路径都是自己定的，不含特殊字符，只做基本防护
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
