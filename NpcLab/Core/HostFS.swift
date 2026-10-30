import Foundation

/// 本机（iPhone）文件系统访问层 —— 对齐 AzTuT 的「设置 → 开发者 → 宿主访问」。
///
/// 跟 `st.hostRoots` 是**两套完全不同的东西**，别混：
///   · hostRoots    PC 节点上的授权根，走 `/api/host/*`，读写发生在电脑上
///   · HostFS（这里）手机上真实的路径，/var/mobile、App 容器、越狱目录
///
/// 所以这一层的「授权」是真正决定 AI 能不能读你手机文件的东西；hostRoots 只决定
/// AI 能不能读你电脑上的文件。
///
/// 沙盒边界由 iOS 内核强制：非越狱设备读 /var/mobile 会 EPERM，这里如实返回错误，
/// 不假装成功。
enum HostFS {

    // MARK: - 内置位置

    struct Preset {
        let title: String
        let path: String
    }

    /// 内置候选位置。真正加进来之前会逐个探活，不存在就跳过 ——
    /// 对齐 AzTuT 那句「不存在的路径会自动跳过，不影响其它项」。
    static var presets: [Preset] {
        var out: [Preset] = []

        // 本 App 沙盒。这个永远存在，也永远可读写，是唯一 100% 可靠的入口。
        out.append(Preset(title: "本 App 沙盒", path: NSHomeDirectory()))

        // App Group 共享容器（装了扩展就有）
        if let g = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.npclab.client")?
            .path, !g.isEmpty {
            out.append(Preset(title: "App Group 共享容器", path: g))
        }

        // 系统公共目录
        out.append(Preset(title: "/var/mobile", path: "/var/mobile"))
        out.append(Preset(title: "/var/mobile/Documents", path: "/var/mobile/Documents"))
        out.append(Preset(title: "/var/mobile/Media", path: "/var/mobile/Media"))

        // 已装 App（逆向目标就住这儿）
        out.append(Preset(title: "已安装 App（Bundle）",
                          path: "/var/containers/Bundle/Application"))
        out.append(Preset(title: "App 数据容器",
                          path: "/var/mobile/Containers/Data/Application"))

        // 越狱根。非越狱设备探活会失败，自动跳过。
        out.append(Preset(title: "根目录 /", path: "/"))
        return out
    }

    /// 探活：能 stat 到才算存在。
    static func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ok
    }

    // MARK: - 路径规范化

    /// 折叠 `..`、`//`、结尾斜杠，但**不解析软链**（软链留给 variants 处理）。
    static func canonical(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // 允许 "~" 代表沙盒
        if s == "~" { return NSHomeDirectory() }
        if s.hasPrefix("~/") {
            s = NSHomeDirectory() + String(s.dropFirst(1))
        }
        guard s.hasPrefix("/") else { return "" }

        s = URL(fileURLWithPath: s).standardizedFileURL.path
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 同一个路径的几种写法。iOS 上 `/var` 是指向 `/private/var` 的软链，
    /// 用户填 /var/mobile、系统返回 /private/var/mobile，不折叠就会判成没授权。
    static func variants(_ path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        var out: [String] = [path]

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved != path { out.append(resolved) }

        for p in [path, resolved] {
            if p.hasPrefix("/private/") {
                out.append(String(p.dropFirst("/private".count)))
            } else {
                out.append("/private" + p)
            }
        }
        // 去重，保序
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// `path` 是否落在 `root` 里面（含 `root` 本身）。
    static func isUnder(_ path: String, root: String) -> Bool {
        if root == "/" { return true }
        for p in variants(path) {
            for r in variants(root) {
                if p == r { return true }
                if p.hasPrefix(r + "/") { return true }
            }
        }
        return false
    }

    // MARK: - 权限判定

    enum Access {
        case none       // 拒绝
        case ro
        case rw
    }

    /// 判定对某个路径的权限。`wantWrite` 为 true 时要求 rw。
    ///
    /// 规则（对应 UI 上那三档 + 全盘访问 + 写保护）：
    ///   模式 off      → 一律拒绝
    ///   全盘访问开     → 读写全放（写保护开着时，写只放给已授权 rw 的位置）
    ///   否则          → 看是否落在某个授权项里；rw 项才能写
    static func access(for rawPath: String,
                       wantWrite: Bool,
                       mode: String,
                       fullDisk: Bool,
                       writeProtect: Bool,
                       grants: [HostGrant]) -> Access {
        guard mode != "off" else { return .none }

        let path = canonical(rawPath)
        guard !path.isEmpty else { return .none }

        // 已授权项优先（ro 项即使开了全盘也不给写）
        for g in grants {
            guard isUnder(path, root: g.path) else { continue }
            if wantWrite { return g.mode == "rw" ? .rw : .none }
            return g.mode == "rw" ? .rw : .ro
        }

        if fullDisk {
            if wantWrite && writeProtect { return .none }
            return .rw
        }
        return .none
    }

    /// 给 AI 看的权限说明，避免它乱试。
    static func denyReason(mode: String) -> String {
        if mode == "off" {
            return "宿主访问总开关是「全部关闭」，AI 现在读不到任何宿主文件。"
                + "需要用户到「设置 → 开发者 → 宿主访问」打开。"
        }
        return "这个路径没有授权。让用户到「设置 → 开发者 → 宿主访问 → 自定义路径」"
            + "加上它，或者直接开启「全盘访问（读写）」。"
    }

    // MARK: - 操作

    struct Entry {
        let name: String
        let isDir: Bool
        let size: Int64
    }

    static func ls(_ path: String) throws -> [Entry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        return items.compactMap { u -> Entry? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Entry(name: u.lastPathComponent,
                         isDir: v?.isDirectory ?? false,
                         size: Int64(v?.fileSize ?? 0))
        }
        .sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 读文件。超过 `maxBytes` 直接截断并标注 —— 免得把上下文打爆。
    static func read(_ path: String, maxBytes: Int = 256 * 1024) throws -> (text: String, truncated: Bool) {
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: min(size, maxBytes)) ?? Data()

        // 二进制就别硬当文本塞给模型了
        if data.contains(0) {
            return ("[二进制文件，\(size) 字节] 前 64 字节 hex: "
                    + data.prefix(64).map { String(format: "%02x", $0) }.joined(),
                    truncated: size > maxBytes)
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "[无法解码]"
        return (text, truncated: size > maxBytes)
    }

    static func write(_ path: String, text: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 人读的字节数
    static func sizeText(_ n: Int64) -> String {
        let d = Double(n)
        if d < 1024 { return "\(n) B" }
        if d < 1024 * 1024 { return String(format: "%.1f KB", d / 1024) }
        if d < 1024 * 1024 * 1024 { return String(format: "%.1f MB", d / 1024 / 1024) }
        return String(format: "%.1f GB", d / 1024 / 1024 / 1024)
    }
}

/// 一条已授权位置。跟 `HostRoot`（节点侧）分开，别共用类型 ——
/// 混用迟早会有人把手机路径塞进节点 hostfs，然后两边都莫名其妙。
struct HostGrant: Identifiable, Hashable, Codable {
    var id = UUID()
    var path: String = ""
    var mode: String = "rw"      // ro / rw
    var builtin: Bool = false    // 内置位置（列表里显示标题）
    var title: String = ""       // 内置位置的人读名字
}
