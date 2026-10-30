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
            let perms = lines[0]
            var t = LocalTarget(path: p)
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
            let result = t

            await MainActor.run {
                if !self.targets.contains(where: { $0.path == p }) {
                    self.targets.append(result)
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
            var failAt = 0
            while idx < b64.endIndex {
                let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
                let piece = String(b64[idx..<end])
                let cmd = "printf '%s' '\(piece)' >> \(Self.guestDir)/.up.b64"
                let r = await rt.exec(cmd, timeout: 30)
                if r.code != 0 {
                    failAt = sent
                    break
                }
                sent += 1
                idx = end
                let p = Double(idx.utf16Offset(in: b64)) / Double(total)
                await MainActor.run { self.progress = p }
            }
            let sentFinal = sent

            if failAt != 0 || sentFinal != (b64.count + chunk - 1) / chunk {
                await MainActor.run {
                    self.busy = false
                    self.status = "传输失败，第 \(sentFinal) 块"
                }
                _ = await rt.exec("rm -f \(Self.guestDir)/.up.b64", timeout: 10)
                return
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

            var built: [LocalFunc] = []
            if let d = json.data(using: .utf8),
               let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
                for f in arr {
                    let name = (f["name"] as? String) ?? "?"
                    // aflj 出来的已经是真函数；把导入桩（sym.imp.*）排掉，
                    // 它们没函数体，点进去只会得到空伪代码
                    if name.hasPrefix("sym.imp.") { continue }
                    let off = (f["offset"] as? Int) ?? Int((f["offset"] as? NSNumber)?.int64Value ?? 0)
                    let size = (f["size"] as? Int) ?? Int((f["size"] as? NSNumber)?.int64Value ?? 0)
                    built.append(LocalFunc(name: name, offset: off, size: size))
                }
            }
            built.sort { $0.offset < $1.offset }
            let out = built

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
            // pdg 是 r2ghidra 的 Ghidra 级伪代码（rootfs 已内置 r2ghidra 6.2.4，
            // 装好后 pdgj 可用）。万一插件加载失败，退 pdc（r2 自带基础伪代码），
            // 最后退反汇编。判"这次算不算成功"不能只看输出非空 —— ERROR: 也是非空。
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
            let textFinal = text
            let engineFinal = engine
            await MainActor.run {
                self.pseudo = textFinal.isEmpty ? "（没有输出：r2 在这个地址上没认出函数）" : textFinal
                self.pseudoEngine = engineFinal
                self.busy = false
                self.status = ""
            }
            self.log("pseudo \(f.name) \(engineFinal) \(textFinal.count)字")
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

    // MARK: - 深度分析（对齐 AzTuT 的 binutils_query / file_query / capstone）

    /// 文件元信息：file -b 输出（对齐 AzTuT 的 file_query）
    /// 可选 sql：当文件是 SQLite 库时跑 SQL（.tables / sqlite_master 等），
    /// 这是 AzTuT file_query 的核心能力——探索目标 App 数据容器里的数据库。
    func fileQuery(_ t: LocalTarget, sql: String = "") {
        guard rt.stage.isReady, !busy else { return }
        setBusy(true, sql.isEmpty ? "file 识别…" : "SQLite 查询…")
        Task {
            let cmd: String
            if sql.isEmpty {
                cmd = "file -b '\(esc(t.path))' 2>&1"
            } else {
                cmd = "sqlite3 -header -column '\(esc(t.path))' \(shellQuote(sql)) 2>&1"
            }
            let r = await rt.exec(cmd, timeout: 30)
            let out = r.out
            await MainActor.run {
                self.busy = false
                self.pseudo = out.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pseudoEngine = sql.isEmpty ? "file" : "sqlite"
                self.status = ""
            }
            self.log("file \(t.path)\(sql.isEmpty ? "" : " sql")")
        }
    }

    /// binutils 查询（对齐 AzTuT 的 binutils_query）：Mach-O 用 llvm-otool，
    /// ELF 用 readelf/objdump。输出完整落到 workspace/binutils 文件。
    func binutilsQuery(_ t: LocalTarget, tool: String = "auto",
                       offset: Int = 0, limit: Int = 0) {
        guard rt.stage.isReady, !busy else { return }
        setBusy(true, "binutils 分析…")

        let toolSel = tool == "auto" ? "headers" : tool
        let cmd: String
        switch toolSel {
        case "headers":
            cmd = "(llvm-otool -h -l '\(esc(t.path))' 2>/dev/null || readelf -h -l '\(esc(t.path))' 2>/dev/null) | head -300"
        case "deps":
            cmd = "(llvm-otool -L '\(esc(t.path))' 2>/dev/null || readelf -d '\(esc(t.path))' 2>/dev/null) | head -300"
        case "objc":
            cmd = "llvm-otool -o '\(esc(t.path))' 2>/dev/null | head -400"
        case "symbols":
            cmd = "(llvm-nm '\(esc(t.path))' 2>/dev/null || nm '\(esc(t.path))' 2>/dev/null) | head -400"
        case "strings":
            cmd = "strings -a '\(esc(t.path))' 2>/dev/null | head -400"
        case "sections":
            cmd = "(llvm-otool -l '\(esc(t.path))' 2>/dev/null | grep -A2 -i sectname || readelf -S '\(esc(t.path))' 2>/dev/null) | head -300"
        default:
            cmd = "(llvm-otool -\(toolSel) '\(esc(t.path))' 2>/dev/null || readelf -\(toolSel) '\(esc(t.path))' 2>/dev/null) | head -300"
        }

        Task {
            let r = await rt.exec(cmd, timeout: 60)
            var out = r.out
            if limit > 0 && out.count > limit {
                out = String(out.prefix(limit))
            }
            let final = out
            // 完整输出写到 /root/npc/binutils，跟 AzTuT 一样不截断
            _ = await rt.exec("mkdir -p \(Self.guestDir)/binutils 2>/dev/null; "
                + "echo \"$1\" > \(Self.guestDir)/binutils/.out 2>/dev/null", timeout: 10)
            await MainActor.run {
                self.busy = false
                self.pseudo = final.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pseudoEngine = "binutils:\(toolSel)"
                self.status = ""
            }
            self.log("binutils \(toolSel) \(t.path)")
        }
    }

    /// capstone 反汇编（对齐 AzTuT 的 capstone 工具）：Python 绑定，指令级。
    /// 需要 rootfs 里有 py3-capstone。
    func capstoneDisasm(_ t: LocalTarget, arch: String = "auto",
                        offset: Int = 0, count: Int = 64) {
        guard rt.stage.isReady, !busy else { return }
        setBusy(true, "capstone 反汇编…")

        let archSel = arch == "auto" ? Self.archFromKind(t.arch) : arch
        let csArch: String
        let csMode: String
        switch archSel {
        case "arm64", "aarch64": csArch = "CS_ARCH_ARM64"; csMode = "CS_MODE_ARM"
        case "arm": csArch = "CS_ARCH_ARM"; csMode = "CS_MODE_ARM"
        default: csArch = "CS_ARCH_X86"; csMode = "CS_MODE_32"
        }

        let py = """
        import capstone, sys
        from capstone import *
        try:
            d = open('\(esc(t.path))','rb').read()
        except Exception as e:
            print('open error:', e); sys.exit(1)
        off = \(offset)
        if off < 0 or off >= len(d):
            off = 0
        md = Cs(\(csArch), \(csMode))
        md.detail = True
        n = 0
        for ins in md.disasm(d[off:off+\(max(count*8, 256))], off):
            print('0x%x:\\t%s\\t%s' % (ins.address, ins.mnemonic, ins.op_str))
            n += 1
            if n >= \(count): break
        """
        let cmd = "python3 -c " + shellQuote(py)

        Task {
            let r = await rt.exec(cmd, timeout: 60)
            let final = r.out
            await MainActor.run {
                self.busy = false
                self.pseudo = final.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pseudoEngine = "capstone:\(archSel)"
                self.status = ""
            }
            self.log("capstone \(t.path) \(archSel)")
        }
    }

    /// capstone 自由脚本（对齐 AzTuT 的 capstone 工具语义）：
    /// AzTuT 是「让 LLM 直接写 capstone Python 代码并打印结果」，支持
    /// CS_ARCH_ARM64/ARM/X86，从文件或 hex 字符串读字节。这里对等同款。
    func capstoneScript(_ code: String, guestPath: String = "") {
        guard rt.stage.isReady, !busy else { return }
        setBusy(true, "capstone 脚本…")
        // 把 guestPath 注入为脚本里可用的 PATH 变量（可选）
        let pre = guestPath.isEmpty ? "" : "PATH='\(esc(guestPath))'\n"
        let py = pre + code
        let cmd = "python3 -c " + shellQuote(py)
        Task {
            let r = await rt.exec(cmd, timeout: 120)
            let final = r.out
            await MainActor.run {
                self.busy = false
                self.pseudo = final.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pseudoEngine = "capstone"
                self.status = ""
            }
            self.log("capstone script \(final.count)字")
        }
    }

    // MARK: - 给 AI 用的接口（ToolAgent 调）
    //
    // 上面那些 func 是「点了按钮 → 改 @Published → UI 显示」的交互式流程，
    // AI 拿不到结果。这里另开一组 async -> String 的：跑命令、直接返回文本，
    // 不碰 busy/status/pseudo，避免 AI 调用把界面搅乱。
    //
    // 输出统一截断到 8KB —— 伪代码和符号表动辄几十万字符，全塞进上下文会
    // 直接把 token 打爆。

    private static let aiMaxChars = 8000

    private func aiClip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= Self.aiMaxChars { return t.isEmpty ? "（没有输出）" : t }
        return String(t.prefix(Self.aiMaxChars)) + "\n…（已截断，原长 \(t.count) 字符）"
    }

    /// 本机目标清单（AI 用 rev_local_targets 拿路径，后续工具都按路径传参）
    @MainActor
    func aiTargetsText() -> String {
        guard rt.stage.isReady else { return "本机 Linux 未启动：先到「终端」页把 Alpine 起起来。" }
        if targets.isEmpty {
            return "还没有加载任何目标。可以让用户在「逆向 → 目标 App 管理」里选一个 App，或直接用 guest 里的路径（例如 /usr/bin/python3.12）。"
        }
        var lines = ["已加载 \(targets.count) 个目标："]
        for t in targets {
            var seg = ["path=\(t.path)"]
            if !t.arch.isEmpty { seg.append("arch=\(t.arch)") }
            if !t.size.isEmpty { seg.append("size=\(t.size)") }
            if !t.kind.isEmpty { seg.append("kind=\(t.kind)") }
            lines.append("  " + seg.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    /// 在本机 radare2 上跑任意 r2 命令（对齐 AzTuT 的 r2_execute）。
    /// cmd 是 r2 内部命令，例如 `afl` / `pdf @ main` / `izz~http` / `axt @ 0x1234`。
    @MainActor
    func aiR2(cmd: String, target: String, timeout: Double = 120) async -> String {
        guard rt.stage.isReady else { return "本机 Linux 未启动，radare2 跑不了。" }
        let p = target.isEmpty ? (current?.path ?? "") : target
        guard !p.isEmpty else { return "缺少 target 参数：先用 rev_local_targets 拿一个路径，或让用户在逆向页选目标。" }

        // r2 命令里单引号会截断我们的 shell 引号，统一转义掉
        let safe = cmd.replacingOccurrences(of: "'", with: "'\\''")
        let full = "radare2 -q -e scr.color=0 -e bin.cache=true "
            + "-c '\(safe)' -c 'q' -- '\(esc(p))' 2>&1"
        let r = await rt.exec(full, timeout: timeout)
        return aiClip(r.out)
    }

    /// binutils（对齐 AzTuT 的 binutils_query）
    @MainActor
    func aiBinutils(tool: String, target: String) async -> String {
        guard rt.stage.isReady else { return "本机 Linux 未启动，binutils 跑不了。" }
        guard !target.isEmpty else { return "缺少 target 参数。" }

        let cmd: String
        switch tool {
        case "headers":  cmd = "(llvm-otool -h -l '\(esc(target))' 2>/dev/null || readelf -h -l '\(esc(target))' 2>/dev/null) | head -300"
        case "deps":     cmd = "(llvm-otool -L '\(esc(target))' 2>/dev/null || readelf -d '\(esc(target))' 2>/dev/null) | head -300"
        case "objc":     cmd = "llvm-otool -o '\(esc(target))' 2>/dev/null | head -300"
        case "symbols":  cmd = "(llvm-nm '\(esc(target))' 2>/dev/null || nm '\(esc(target))' 2>/dev/null) | head -400"
        case "strings":  cmd = "strings -a '\(esc(target))' 2>/dev/null | head -500"
        case "sections": cmd = "(llvm-otool -l '\(esc(target))' 2>/dev/null | grep -A2 -i sectname || readelf -S '\(esc(target))' 2>/dev/null) | head -300"
        default:         cmd = "(llvm-otool -\(tool) '\(esc(target))' 2>/dev/null || readelf -\(tool) '\(esc(target))' 2>/dev/null) | head -300"
        }
        let r = await rt.exec(cmd, timeout: 90)
        var out = aiClip(r.out)
        if out.contains("（没有输出）") {
            out = "tool=\(tool) 没有输出。可能：这个文件不是 Mach-O/ELF，或 rootfs 里缺 llvm/readelf。"
        }
        return out
    }

    /// file 类型识别 + sqlite3 读库（对齐 AzTuT 的 file_query）
    @MainActor
    func aiFileDb(target: String, sql: String) async -> String {
        guard rt.stage.isReady else { return "本机 Linux 未启动，file/sqlite3 跑不了。" }
        guard !target.isEmpty else { return "缺少 target 参数。" }

        let cmd: String
        if sql.isEmpty {
            cmd = "file -b '\(esc(target))' 2>&1"
        } else {
            cmd = "sqlite3 -header -column '\(esc(target))' \(shellQuote(sql)) 2>&1"
        }
        let r = await rt.exec(cmd, timeout: 60)
        return aiClip(r.out)
    }

    /// capstone 指令级反汇编（对齐 AzTuT 的 capstone 工具）
    @MainActor
    func aiCapstone(target: String, arch: String, offset: Int, count: Int) async -> String {
        guard rt.stage.isReady else { return "本机 Linux 未启动，capstone 跑不了。" }
        guard !target.isEmpty else { return "缺少 target 参数。" }

        let csArch: String
        let csMode: String
        switch arch.lowercased() {
        case "arm64", "aarch64": csArch = "CS_ARCH_ARM64"; csMode = "CS_MODE_ARM"
        case "arm":              csArch = "CS_ARCH_ARM";   csMode = "CS_MODE_ARM"
        case "x86_64", "x86-64": csArch = "CS_ARCH_X86";   csMode = "CS_MODE_64"
        default:                 csArch = "CS_ARCH_X86";   csMode = "CS_MODE_32"
        }
        let n = max(1, min(count, 400))
        let py = """
        import capstone, sys
        from capstone import *
        try:
            d = open('\(esc(target))','rb').read()
        except Exception as e:
            print('open error:', e); sys.exit(1)
        off = \(max(offset, 0))
        if off >= len(d):
            print('offset 越界，文件只有 %d 字节' % len(d)); sys.exit(1)
        md = Cs(\(csArch), \(csMode))
        md.detail = True
        n = 0
        for ins in md.disasm(d[off:off+\(n * 8)], off):
            print('0x%x:\\t%s\\t%s' % (ins.address, ins.mnemonic, ins.op_str))
            n += 1
            if n >= \(n): break
        if n == 0:
            print('这个偏移上没有解出指令；可能架构选错了（试试 arch=x86 / arm64 / arm）')
        """
        let r = await rt.exec("python3 -c " + shellQuote(py), timeout: 90)
        return aiClip(r.out)
    }

    /// r2ghidra 伪代码（对齐 AzTuT 的 r2ghidra 插件能力）：
    /// pdgj（Ghidra 级）→ pdc（r2 自带）→ pdf（反汇编）自动降级。
    @MainActor
    func aiPseudo(target: String, off: String, timeout: Double = 240) async -> String {
        guard rt.stage.isReady else { return "本机 Linux 未启动，r2ghidra 跑不了。" }
        guard !target.isEmpty else { return "缺少 target 参数。" }

        let addr = off.isEmpty ? "main" : off
        let cmds: [(String, String)] = [("pdgj", "r2ghidra"), ("pdc", "r2pdc"), ("pdf", "asm")]
        for (c, name) in cmds {
            let full = "radare2 -q -e scr.color=0 -e bin.cache=true "
                + "-c 's \(esc(addr))' -c 'af' -c '\(c)' -c 'q' -- '\(esc(target))' 2>&1"
            let r = await rt.exec(full, timeout: timeout)
            let body = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.badOutput(body) { continue }
            return "[\(name)]\n" + aiClip(body)
        }
        return "三种引擎都没能在这个地址上出结果（pdgj / pdc / pdf 全部失败）。先用 rev_local_funcs 或 r2_execute 的 afl 确认函数地址。"
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
