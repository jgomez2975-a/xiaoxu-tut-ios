//
//  RevLocal.swift
//  NpcLab
//
//  本机逆向：不连 PC，直接在 App 内置的那个 Alpine 里跑 radare2。
//
//  rootfs 里装的是 Alpine 的 radare2（5.9.x）。r2ghidra 那个插件是单独
//  一份 core_ghidra.so，Alpine 的包不带 —— 所以伪代码按下面顺序降级，
//  有 ghidra 就用 ghidra，没有就 r2pdc，再不行就反汇编，绝不空着：
//
//      选目标 → （必要时）把文件送进 Linux → r2 -A 出函数表 → 点函数 → pdgj/pdc/pdf
//
//  为什么要“送进 Linux”：iOS 沙箱里的文件在 guest 里看不见，fakefs 只认
//  自己 meta.db 里的 inode。小文件（≤32MB）用 base64 分块灌进去，已经在
//  guest 里的路径（/usr/bin/xxx）则零拷贝直接用。
//

import Foundation
import Combine

// MARK: - 数据

struct LocalTarget: Identifiable, Hashable {
    var path: String            // guest 内路径
    var label: String = ""
    var arch: String = ""
    var size: String = ""
    var kind: String = ""
    var id: String { path }
}

struct LocalFunc: Identifiable, Hashable {
    var name: String
    var offset: Int
    var size: Int
    var id: String { "\(name)@\(offset)" }
    var hex: String { String(format: "0x%llx", Int64(offset)) }
}

// MARK: - 引擎

final class RevLocal: ObservableObject {

    static let shared = RevLocal()

    @Published private(set) var r2Version = ""
    @Published private(set) var r2Ready = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var targets: [LocalTarget] = []
    @Published private(set) var funcs: [LocalFunc] = []
    @Published private(set) var pseudo = ""
    @Published private(set) var pseudoEngine = ""
    @Published private(set) var current: LocalTarget?
    @Published private(set) var progress: Double = 0

    /// 灌进 guest 的文件都放这儿，省得跟系统目录混
    static let guestDir = "/root/npc"
    private let maxImport = 32 * 1024 * 1024

    private var rt: LinuxRuntime { .shared }

    private func setBusy(_ b: Bool, _ s: String = "") {
        DispatchQueue.main.async {
            self.busy = b
            self.status = s
        }
    }

    private func log(_ s: String) { NpcLog.write("[rev] " + s) }

    // MARK: 探活

    func probe() {
        guard !busy else { return }
        guard rt.stage.isReady else {
            DispatchQueue.main.async {
                self.r2Ready = false
                self.r2Version = "Linux 未启动"
            }
            return
        }
        setBusy(true, "检查 radare2…")
        Task {
            let r = await rt.exec("radare2 -v 2>&1 | head -2", timeout: 20)
            let first = r.out.split(separator: "\n").first.map(String.init) ?? ""
            let ok = first.contains("radare2")
            await MainActor.run {
                self.r2Ready = ok
                self.r2Version = ok ? first : (r.out.isEmpty ? "未安装" : String(r.out.prefix(60)))
                self.busy = false
                self.status = ok ? "" : "rootfs 里没找到 radare2"
            }
            self.log("probe \(ok) \(first)")
        }
    }

    // MARK: 目标

    /// 加一个 guest 里已经存在的路径（/usr/bin/python3.12、/bin/busybox…）
    func addGuestPath(_ raw: String) {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        guard rt.stage.isReady else { status = "先到终端页把 Linux 启起来"; return }

        setBusy(true, "读文件信息…")
        Task {
            // 一条命令拿三样：类型/大小/文件类型描述。ls -l 里那个链接数
            // 也是数字，靠它猜大小会错，所以单独用 wc -c。
            let cmd = "if [ -e '\(esc(p))' ]; then "
                + "ls -ld '\(esc(p))'; wc -c < '\(esc(p))'; file -b '\(esc(p))' 2>&1; "
                + "else echo NOSUCH; fi"
            let info = await rt.exec(cmd, timeout: 25)
            let lines = info.out.split(separator: "\n").map(String.init)
            guard !info.out.contains("NOSUCH"), lines.count >= 2 else {
                await MainActor.run {
                    self.busy = false
                    self.status = "文件不存在或读不了：\(p)"
                }
                return
            }
            var t = LocalTarget(path: p)
            let perms = lines[0]
            if perms.hasPrefix("d") {
                t.kind = "目录"
                t.size = ""
            } else {
                if lines.count >= 3 { t.kind = String(lines[2].prefix(70)) }
                if let n = Int64(lines[1].trimmingCharacters(in: .whitespaces)) {
                    t.size = ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
                }
            }
            t.arch = Self.archFromKind(t.kind)
            t.label = (p as NSString).lastPathComponent

            await MainActor.run {
                if !self.targets.contains(where: { $0.path == p }) {
                    self.targets.append(t)
                }
                self.busy = false
                self.status = ""
            }
        }
    }

    /// 把 App 里的文件灌进 guest，返回 guest 路径
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            status = "读不了这个文件"
            return
        }
        if data.count > maxImport {
            status = "文件 \(data.count / 1048576)MB 超过 \(maxImport / 1048576)MB 上限，先放小一点的样本"
            return
        }
        guard rt.stage.isReady else { status = "先到终端页把 Linux 启起来"; return }

        let name = url.lastPathComponent.replacingOccurrences(of: "'", with: "_")
        let guestPath = "\(Self.guestDir)/\(name)"
        let b64 = data.base64EncodedString()

        setBusy(true, "送入 Linux…")
        DispatchQueue.main.async { self.progress = 0 }

        Task {
            _ = await rt.exec("mkdir -p \(Self.guestDir); rm -f \(Self.guestDir)/.up.b64", timeout: 20)

            // 64KB 一块：guest 的单参数上限是 128KB，留一半余量
            let chunk = 64 * 1024
            var idx = b64.startIndex
            var sent = 0
            let total = b64.count
            while idx < b64.endIndex {
                let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
                let piece = String(b64[idx..<end])
                let cmd = "printf '%s' '\(piece)' >> \(Self.guestDir)/.up.b64"
                let r = await rt.exec(cmd, timeout: 30)
                if r.code != 0 {
                    await MainActor.run {
                        self.busy = false
                        self.status = "传输失败，第 \(sent) 块"
                    }
                    _ = await rt.exec("rm -f \(Self.guestDir)/.up.b64", timeout: 10)
                    return
                }
                sent += 1
                idx = end
                let p = Double(idx.utf16Offset(in: b64)) / Double(total)
                await MainActor.run { self.progress = p }
            }

            let dec = await rt.exec(
                "base64 -d \(Self.guestDir)/.up.b64 > '\(guestPath)' && rm -f \(Self.guestDir)/.up.b64 && chmod 755 '\(guestPath)' && ls -l '\(guestPath)'",
                timeout: 120)
            await MainActor.run {
                self.busy = false
                self.progress = 0
                if dec.code == 0 {
                    self.status = "已送入 \(guestPath)"
                    self.log("import ok \(guestPath) \(data.count)B")
                } else {
                    self.status = "解码失败：\(dec.out.prefix(120))"
                }
            }
            if dec.code == 0 {
                addGuestPath(guestPath)
            }
        }
    }

    func remove(_ t: LocalTarget) {
        targets.removeAll { $0.path == t.path }
        if current?.path == t.path {
            current = nil
            funcs = []
            pseudo = ""
            pseudoEngine = ""
        }
        // 只删我们自己灌进去的，系统文件不动
        if t.path.hasPrefix(Self.guestDir + "/") {
            Task { _ = await rt.exec("rm -f '\(esc(t.path))'", timeout: 10) }
        }
    }

    // MARK: 函数表

    func analyze(_ t: LocalTarget) {
        guard rt.stage.isReady else { status = "Linux 未启动"; return }
        guard !busy else { return }

        current = t
        funcs = []
        pseudo = ""
        pseudoEngine = ""
        setBusy(true, "radare2 正在分析，大文件要几十秒…")
        log("analyze \(t.path)")

        Task {
            let cmd = "radare2 -q -e scr.color=0 -e bin.cache=true -e anal.timeout=180 "
                + "-A -c 'aflj' -c 'q' -- '\(esc(t.path))' 2>/dev/null"
            let r = await rt.exec(cmd, timeout: 600)
            let json = Self.extractJSON(r.out)

            var out: [LocalFunc] = []
            if let d = json.data(using: .utf8),
               let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
                for f in arr {
                    let name = (f["name"] as? String) ?? "?"
                    // aflj 出来的已经是真函数；把导入桩（sym.imp.*）排掉，
                    // 它们没函数体，点进去只会得到空伪代码
                    if name.hasPrefix("sym.imp.") { continue }
                    let off = (f["offset"] as? Int) ?? Int((f["offset"] as? NSNumber)?.int64Value ?? 0)
                    let size = (f["size"] as? Int) ?? Int((f["size"] as? NSNumber)?.int64Value ?? 0)
                    out.append(LocalFunc(name: name, offset: off, size: size))
                }
            }
            out.sort { $0.offset < $1.offset }

            await MainActor.run {
                self.funcs = out
                self.busy = false
                if out.isEmpty {
                    let brief = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.status = brief.isEmpty
                        ? "没解析出函数（可能不是可执行文件，或 r2 分析超时）"
                        : String(brief.suffix(200))
                } else {
                    self.status = ""
                }
            }
            self.log("analyze done \(out.count) funcs")
        }
    }

    // MARK: 伪代码

    func decompile(_ f: LocalFunc) {
        guard let t = current, rt.stage.isReady, !busy else { return }
        setBusy(true, "还原 \(f.name)…")
        Task {
            // pdg 是 r2ghidra（Alpine 包不带，缺了会直接报 Invalid command），
            // 出不了就退 pdc，最后退反汇编。判"这次算不算成功"不能只看
            // 输出非空 —— ERROR: 也是非空。
            let cmds: [(String, String)] = [
                ("pdgj", "ghidra"),
                ("pdc", "r2pdc"),
                ("pdf", "asm"),
            ]
            var text = ""
            var engine = ""
            for (c, name) in cmds {
                let cmd = "radare2 -q -e scr.color=0 -e bin.cache=true "
                    + "-c 's \(f.hex)' -c 'af' -c '\(c)' -c 'q' -- '\(esc(t.path))' 2>&1"
                let r = await rt.exec(cmd, timeout: 420)
                let body = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.badOutput(body) { continue }
                text = body
                engine = name
                break
            }
            await MainActor.run {
                self.pseudo = text.isEmpty ? "（没有输出：r2 在这个地址上没认出函数）" : text
                self.pseudoEngine = engine
                self.busy = false
                self.status = ""
            }
            self.log("pseudo \(f.name) \(engine) \(text.count)字")
        }
    }

    // MARK: 工具

    /// r2 的失败输出也是"非空字符串"，光判非空会把 ERROR 当结果贴给用户
    private static func badOutput(_ s: String) -> Bool {
        if s.isEmpty { return true }
        let low = s.lowercased()
        for bad in ["error:", "cannot find function", "unknown command",
                    "invalid command", "command not found", "unknown plugin"] {
            if low.contains(bad) { return true }
        }
        return false
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// r2 有时候会在 JSON 前面混进警告，从头找一个 [ 到最后一个 ]
    private static func extractJSON(_ s: String) -> String {
        guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b else { return "" }
        return String(s[a...b])
    }

    private static func archFromKind(_ kind: String) -> String {
        let k = kind.lowercased()
        if k.contains("arm64") || k.contains("aarch64") { return "arm64" }
        if k.contains("x86-64") || k.contains("x86_64") { return "x86_64" }
        if k.contains("intel 80386") || k.contains("i386") { return "x86" }
        if k.contains("mach-o") { return "mach-o" }
        if k.contains("elf") { return "elf" }
        if k.contains("dex") { return "dex" }
        if k.contains("pe32") { return "pe" }
        return ""
    }
}
