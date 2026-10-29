//
//  LinuxRuntimeStub.swift
//  NpcLab
//
//  没有 libishkernel.a 时的替身。存在的意义只有一个：让工程在没编内核的机器上
//  也能编译、能跑界面、能调 UI——而不是满屏 "symbol not found"。
//
//  Tools/gen_xcodeproj.py 会在 Vendor/libishkernel.a 存在时自动把本文件踢出编译，
//  换成真的 LinuxRuntime.swift。两个文件永远只会进一个。
//

import Foundation
import Combine

final class LinuxRuntime: ObservableObject {

    static let shared = LinuxRuntime()

    @Published private(set) var stage: LinuxStage = .failed("未编译 iSH 内核")
    @Published private(set) var lines: [TermLine] = []
    @Published private(set) var busy = false
    @Published var commandHistory: [String] = []
    /// 没有内核时永远不会有打开请求，但终端页要能编译，所以字段得在
    @Published var openRequest: OpenRequest?

    private(set) var rootfsDir: URL = URL(fileURLWithPath: NSTemporaryDirectory())

    private init() {}

    func bootIfNeeded() {
        guard lines.isEmpty else { return }
        lines = [
            TermLine(text: "这个包里没有 Linux 内核。", kind: .error),
            TermLine(text: "", kind: .out),
            TermLine(text: "终端功能需要先把 iSH 内核交叉编译成静态库：", kind: .system),
            TermLine(text: "    bash Tools/build_ish.sh", kind: .command),
            TermLine(text: "", kind: .out),
            TermLine(text: "这一步必须在 macOS 上跑（要 iPhoneOS SDK + meson + ninja）。", kind: .system),
            TermLine(text: "编完之后重新生成工程：", kind: .system),
            TermLine(text: "    python3 Tools/gen_xcodeproj.py", kind: .command),
        ]
    }

    func exec(_ cmd: String, timeout: Double = 60) async -> (out: String, code: Int32) {
        ("没有内核，命令执行不了。先跑 Tools/build_ish.sh。", -1)
    }

    func runInTerminal(_ cmd: String) {
        lines.append(TermLine(text: "root@npclab:~# \(cmd)", kind: .command))
        lines.append(TermLine(text: "没有内核，命令执行不了。", kind: .error))
    }

    func send(_ bytes: String) {}
    func resize(cols: Int, rows: Int) {}
    func clear() { lines.removeAll() }
    func rebuildRootfs() {}

    /// 真实现里这两个是把一行命令送进 pty；没有内核时只留一行提示
    var sessionAlive: Bool { false }
    @discardableResult
    func sendLine(_ cmd: String) -> Bool {
        lines.append(TermLine(text: "$ \(cmd)", kind: .command))
        lines.append(TermLine(text: "没有内核，命令执行不了。", kind: .error))
        return false
    }
    func restartSession() {}
}
