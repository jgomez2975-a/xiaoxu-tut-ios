//
//  LinuxRuntime.swift
//  NpcLab
//
//  把 iSH 内核包成一个 ObservableObject。iOS 沙箱里跑 Linux 的全部复杂度
//  都收在这一个文件里：解 rootfs、起内核、收输出、敲键盘。
//
//  线程约定（照抄 iSH 的规矩）：
//    · 内核自己吃一个线程，进去不出来
//    · 任何"进内核"的动作都要排队，不能直接调
//    · 输出回调发生在内核线程，必须自己切主线程
//

import Foundation
import Combine

// MARK: - Runtime

final class LinuxRuntime: ObservableObject {

    static let shared = LinuxRuntime()

    @Published private(set) var stage: LinuxStage = .idle
    @Published private(set) var lines: [TermLine] = []
    @Published private(set) var busy = false
    @Published var commandHistory: [String] = []

    /// 终端里发起的打开请求（OSC 1337），终端页监听后弹原生界面
    @Published var openRequest: OpenRequest?

    /// rootfs 解压目录（zip 解到这个目录下）
    private(set) var rootfsDir: URL

    /// 交给内核挂载的那个根。zip 里带了一层 alpine-rootfs/，所以真根在第二层：
    ///   <rootfsDir>/alpine-rootfs/{meta.db,data}
    /// 以前直接把 rootfsDir 传进去，meta.db 找不到 → fakefs 打不开 →
    /// 内核 die() 把整个进程带走，表现就是「点终端闪退」。这里两个布局都认。
    var rootfsRoot: URL {
        let nested = rootfsDir.appendingPathComponent("alpine-rootfs", isDirectory: true)
        if FileManager.default.fileExists(atPath: nested.appendingPathComponent("meta.db").path) {
            return nested
        }
        return rootfsDir
    }

    private var booted = false
    private var pending = Data()
    private var osc = OSCScanner()
    private var started = false

    private let maxLines = 3000
    private let ioQueue = DispatchQueue(label: "npclab.linux.io", qos: .userInitiated)

    // MARK: 生命周期

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        rootfsDir = base.appendingPathComponent("NpcLab/rootfs", isDirectory: true)
    }

    /// App 启动时叫一次。重复调用无副作用。
    func bootIfNeeded() {
        guard !started else { return }
        started = true

        npc_linux_set_output(npcOutputTrampoline,
                             Unmanaged.passUnretained(self).toOpaque())

        ioQueue.async { [weak self] in
            self?.prepareAndBoot()
        }
    }

    private func prepareAndBoot() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootfsDir.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        NpcLog.write("boot: 开始 · dir=\(rootfsDir.path)")

        // 1. rootfs：已经解过就跳过
        if npc_unzip_is_done(rootfsDir.path) == 1 {
            emit(.system, "[rootfs] 已存在，跳过解压")
            NpcLog.write("boot: rootfs 已存在")
        } else {
            guard let zip = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
                fail("bundle 里找不到 alpine-rootfs.zip")
                return
            }
            setStage(.unpacking(0))
            emit(.system, "[rootfs] 开始解压 \(byteText(fileSize(zip)))")
            NpcLog.write("boot: 解压开始")

            let rc = npc_unzip(zip.path, rootfsDir.path,
                               npcUnzipTrampoline,
                               Unmanaged.passUnretained(self).toOpaque())
            guard rc == 0 else {
                fail("解压失败（code \(rc)）")
                return
            }
            emit(.system, "[rootfs] 解压完成")
            NpcLog.write("boot: 解压完成")
        }

        let sub = rootfsRoot.path
        if !fm.fileExists(atPath: sub + "/meta.db") {
            fail("rootfs 结构不对：\(sub) 下没有 meta.db")
            return
        }
        NpcLog.write("boot: 内核根 = \(sub)")

        // 2. 起内核
        setStage(.booting)
        emit(.system, "[kernel] 正在启动 iSH/Linux…")

        let rc = npc_linux_boot(sub)
        guard rc == 0 else {
            fail("内核启动失败（code \(rc)）：\(String(cString: npc_linux_last_error()))")
            return
        }

        // 内核在独立线程里起：npc_linux_boot 会等到 fakefs 挂载 + pid 1 exec
        // 都做完（最多 20 秒）才返回，再用 /bin/true 实测。
        // 真就绪 = fakefs 挂上 + 能 fork + 能执行 aarch64 二进制。
        emit(.system, "[kernel] 等待挂载 rootfs…")
        var ready = false
        for i in 0..<45 {
            if npc_linux_ready() == 1 { ready = true; break }
            if i % 5 == 4 {
                emit(.system, "[kernel] 仍在等待… \(i + 1)s")
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard ready else {
            fail("内核 45 秒内未就绪：\(String(cString: npc_linux_last_error()))")
            return
        }
        booted = true
        setStage(.ready)
        emit(.system, "[kernel] 就绪 · \(String(cString: npc_linux_version()))")
        NpcLog.write("boot: 内核就绪")
        WidgetBridge.setKernel(1, stage: "运行中")

        // 3. 铺 default_mount（npclab-open / profile.d / pip.conf …）
        installOverlay()

        // 4. 拉一个登录 shell 出来
        let s = npc_linux_session_open()
        if s == 0 {
            emit(.system, "[sh] /bin/sh 已挂到 pty，可以直接敲命令")
            NpcLog.write("boot: 会话已建立")
            DispatchQueue.main.async { npc_linux_session_resize(96, 30) }
        } else {
            emit(.error, "[sh] 会话启动失败（code \(s)）")
            NpcLog.write("boot: 会话启动失败 code=\(s)")
        }
    }

    /// 把 default_mount.json 里的东西写进 rootfs。
    /// 只能让内核自己写（fakefs 的 meta.db 不认外部拷入的文件），
    /// 所以拼一条 shell 命令丢给 /bin/sh。
    private func installOverlay() {
        guard let script = RootfsOverlay.installScript() else {
            emit(.system, "[overlay] 没有 default_mount.json，跳过")
            return
        }

        var outPtr: UnsafeMutablePointer<CChar>?
        var outLen: Int32 = 0
        var code: Int32 = -1
        let rc = npc_linux_exec(script, 60, &outPtr, &outLen, &code)
        defer { if let p = outPtr { npc_linux_free(p) } }

        let text = outPtr.map { String(cString: $0) } ?? ""
        if rc == 0, code == 0 {
            let n = RootfsOverlay.filePaths().count
            emit(.system, "[overlay] 已铺 \(n) 个文件（npclab-open / xdg-open 等）")
        } else if rc == -2 {
            emit(.error, "[overlay] 超时")
        } else {
            let brief = text.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.error, "[overlay] 写入失败 code \(code) \(brief.prefix(200))")
        }
    }

    private func fail(_ msg: String) {
        setStage(.failed(msg))
        emit(.error, msg)
        WidgetBridge.setKernel(2, stage: String(msg.prefix(40)))
    }

    // MARK: 执行

    /// 同步跑一条命令，返回输出和退出码。给工具面板 / 快捷指令用。
    func exec(_ cmd: String, timeout: Double = 60) async -> (out: String, code: Int32) {
        guard booted else { return ("内核未启动", -1) }

        await MainActor.run { busy = true }
        defer { Task { @MainActor in busy = false } }

        return await withCheckedContinuation { cont in
            ioQueue.async {
                var outPtr: UnsafeMutablePointer<CChar>?
                var outLen: Int32 = 0
                var code: Int32 = -1
                let rc = npc_linux_exec(cmd, timeout, &outPtr, &outLen, &code)

                var text = ""
                if let p = outPtr {
                    text = String(cString: p)
                    npc_linux_free(p)
                }
                switch rc {
                case 0:  break
                case -2: text += "\n[超时 \(Int(timeout))s]"
                default: text += "\n[执行失败 code \(rc)]"
                }
                cont.resume(returning: (text, code))
            }
        }
    }

    /// 终端里敲一条命令：显示提示符 + 输出
    func runInTerminal(_ cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        emit(.command, "root@npclab:~# \(c)")
        commandHistory.append(c)

        // 贴进来的 bash 语法在 busybox ash 下会静默算错，先提醒一句
        if let warn = BashismScanner.summary(c) {
            emit(.system, warn)
        }

        Task {
            let r = await exec(c, timeout: 120)
            await MainActor.run {
                if !r.out.isEmpty { append(r.out, kind: r.code == 0 ? .out : .error) }
                WidgetBridge.setLast(cmd: c, out: r.out)
            }
        }
    }

    /// 敲键盘（原始字节，支持转义序列）
    func send(_ bytes: String) {
        guard booted else { return }
        bytes.withCString { p in
            _ = npc_linux_session_write(p, Int32(bytes.utf8.count))
        }
    }

    /// 会话还活着吗。pty 那头 sh 退出后就是 false。
    var sessionAlive: Bool { booted && npc_linux_session_alive() == 1 }

    /// 往真 shell 里送一整行。会话没了就先拉一个新的。
    /// 终端页的输入框走这条路径，输出由 pty 回调直接上屏，提示符也是真的。
    @discardableResult
    func sendLine(_ cmd: String) -> Bool {
        guard booted else { return false }
        if npc_linux_session_alive() == 0 {
            if npc_linux_session_open() != 0 {
                emit(.error, "[sh] 会话已结束，且重建失败")
                return false
            }
            DispatchQueue.main.async { npc_linux_session_resize(96, 30) }
        }
        send(cmd + "\n")
        return true
    }

    /// 重开一个干净会话（清屏后调用，避免上一个 sh 的残留状态）
    func restartSession() {
        guard booted else { return }
        _ = npc_linux_session_open()
        resize(cols: 96, rows: 30)
    }

    func resize(cols: Int, rows: Int) {
        guard booted else { return }
        _ = npc_linux_session_resize(Int32(cols), Int32(rows))
    }

    func clear() {
        lines.removeAll()
    }

    // MARK: 输出处理（内核线程 → 主线程）

    fileprivate func onOutput(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 先剥 OSC 1337 标记（Linux 侧 npclab-open 发上来的打开请求），
            // 剩下的字节才是要上屏的。剥完仍是合法 UTF-8，交给 feed 处理。
            let scanned = self.osc.feed(data)
            for u in scanned.opens {
                self.openRequest = OpenRequest.classify(u)
            }
            let text = self.feed(scanned.clean)
            guard !text.isEmpty else { return }
            self.append(text, kind: .out)
        }
    }

    fileprivate func onUnzipProgress(_ done: Int32, _ total: Int32, _ name: String?) {
        guard total > 0 else { return }
        let p = Double(done) / Double(total)
        // 每 1% 才刷一次 UI，否则 4000 个文件能把主线程刷爆
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if case .unpacking(let old) = self.stage, p - old < 0.01, p < 1 { return }
            self.stage = .unpacking(min(p, 1))
            LiveActivity.unpacking(min(p, 1))
        }
    }

    /// 增量 UTF-8：字节可能被切在多字节字符中间，攒够再解
    private func feed(_ data: Data) -> String {
        pending.append(data)
        var cut = pending.count
        var i = pending.count - 1
        var cont = 0
        while i >= 0 && cont < 3 && (pending[i] & 0xC0) == 0x80 { i -= 1; cont += 1 }
        if i >= 0 {
            let b = pending[i]
            let need: Int
            if b & 0x80 == 0 { need = 1 }
            else if b & 0xE0 == 0xC0 { need = 2 }
            else if b & 0xF0 == 0xE0 { need = 3 }
            else if b & 0xF8 == 0xF0 { need = 4 }
            else { need = 1 }
            if pending.count - i < need { cut = i }
        }
        let complete = pending.prefix(cut)
        pending = Data(pending.dropFirst(cut))
        return String(decoding: complete, as: UTF8.self)
    }

    /// 按 \n 切行、按 \r 归位、剥掉 ANSI
    private func append(_ raw: String, kind: TermLine.Kind) {
        let clean = LinuxRuntime.stripANSI(raw)
        var buf = ""
        var result: [TermLine] = []

        for ch in clean {
            switch ch {
            case "\n":
                result.append(TermLine(text: buf, kind: kind))
                buf = ""
            case "\r":
                buf = ""          // 进度条走 \r，覆盖当前行
            case "\u{08}":
                if !buf.isEmpty { buf.removeLast() }
            default:
                if ch == "\u{07}" { continue }   // 响铃，丢弃
                buf.append(ch)
            }
        }
        if !buf.isEmpty { result.append(TermLine(text: buf, kind: kind)) }
        guard !result.isEmpty else { return }

        lines.append(contentsOf: result)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    // MARK: 小工具

    private func setStage(_ s: LinuxStage) {
        DispatchQueue.main.async {
            self.stage = s
            self.syncLiveActivity(s)
        }
    }

    /// 锁屏/灵动岛跟着内核状态走：解压与启动挂卡，就绪或失败就收。
    /// 16.1 以下 LiveActivity 内部全是空操作，这里不用判。
    private func syncLiveActivity(_ s: LinuxStage) {
        switch s {
        case .unpacking(let p): LiveActivity.unpacking(p)
        case .booting:          LiveActivity.booting("挂载 rootfs")
        case .ready:            LiveActivity.ready()
        case .failed:           LiveActivity.stop()
        case .idle:             break
        }
    }

    private func emit(_ kind: TermLine.Kind, _ text: String) {
        DispatchQueue.main.async {
            self.append(text, kind: kind)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func byteText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// 重装 rootfs（设置页那个按钮）
    func rebuildRootfs() {
        guard !booted else {
            emit(.error, "内核在跑，先重启 App 再重建 rootfs")
            return
        }
        ioQueue.async {
            _ = npc_rmtree(self.rootfsDir.path)
            DispatchQueue.main.async {
                self.started = false
                self.lines.removeAll()
            }
        }
    }

    // MARK: ANSI

    private static let ansiPatterns: [NSRegularExpression] = {
        let pats = [
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",  // OSC
            "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",                  // CSI
            "\u{1B}[()][A-Za-z0-9]",                          // 字符集
            "\u{1B}[=>NOP]",                                  // 单字符
        ]
        return pats.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = s
        for re in ansiPatterns {
            out = re.stringByReplacingMatches(in: out,
                                              range: NSRange(out.startIndex..., in: out),
                                              withTemplate: "")
        }
        return out
    }
}

// MARK: - C 回调蹦床
//
// @convention(c) 闭包不能捕获上下文，所以 self 走 ctx 指针透传。
// 单例的生命周期等于进程，Unmanaged 不会悬空。

private let npcOutputTrampoline: npc_out_cb = { bytes, len, ctx in
    guard let bytes = bytes, len > 0, let ctx = ctx else { return }
    let data = Data(bytes: bytes, count: Int(len))
    Unmanaged<LinuxRuntime>.fromOpaque(ctx).takeUnretainedValue().onOutput(data)
}

private let npcUnzipTrampoline: npc_unzip_progress = { done, total, name, ctx in
    guard let ctx = ctx else { return }
    let n = name.map { String(cString: $0) }
    Unmanaged<LinuxRuntime>.fromOpaque(ctx)
        .takeUnretainedValue()
        .onUnzipProgress(done, total, n)
}
