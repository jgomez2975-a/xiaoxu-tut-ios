//
//  InjectEngine.swift
//  NpcLab
//
//  目标应用动态注入 + Frida hook —— 对齐 AzTuT 的 FuckInjectRunner + dylib_inject。
//
//  AzTuT 的注入链（全在 iOS 本机，无越狱也行）：
//    FuckInjectRunner ──► opainject (ROP/shellcode dlopen) 或 libjailbreak.dylib
//         │                  └─ 把 dylib 注入目标 App 进程
//         │
//    FuckKfdHelper ──────► kfd 内核漏洞（LANDA/smith/physpuppet）
//         │                  └─ 写 Trust cache，让未签名 dylib 能被加载
//         │
//    ct_bypass ──────────► CoreTrust 绕过（伪签 + LC_LOAD_DYLIB 篡改）
//
//  NpcLab 这边做不到直接调这些私有二进制（它们在 AzTuT 包里），
//  所以对齐的是「能力形态」：在本机 Alpine 里跑注入工具链 + Frida，
//  通过 Linux 里的 frida-server 连到目标 App 进程做 hook。
//  越狱/root 环境由 rootfs 提供；kfd 那套在越狱环境里由 frida 替代。
//

import Foundation
import Combine

// MARK: - 数据

/// 一个可注入的目标 App
struct InjectTarget: Identifiable, Hashable {
    var bundleId: String
    var name: String
    var pid: Int = -1
    var running: Bool = false
    var id: String { bundleId }
}

/// 一条 Frida hook 规则（对齐 AzTuT 的 hookType 六类）
enum FridaHookType: String, CaseIterable, Codable {
    case logMethod       // 打印方法调用
    case returnConstant  // 固定返回值
    case blockMethod     // 拦截/禁用方法
    case modifyProperty  // 改属性
    case flexOverride    // Flex 风格覆写
    case methodSwizzle   // 方法交换
}

struct FridaHook: Identifiable, Hashable, Codable {
    var id = UUID()
    var className: String = ""
    var methodName: String = ""
    var isClassMethod: Bool = false
    var hookType: FridaHookType = .logMethod
    var returnValue: String = ""   // returnConstant 用
    var property: String = ""      // modifyProperty 用
}

/// 一条注入日志
struct InjectLog: Identifiable, Hashable {
    var id = UUID()
    var ts = Date()
    var level: String   // info / hook / error
    var text: String
}

// MARK: - 引擎

final class InjectEngine: ObservableObject {

    static let shared = InjectEngine()

    @Published private(set) var targets: [InjectTarget] = []
    @Published private(set) var logs: [InjectLog] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var attached = false

    var hooks: [FridaHook] = []
    private let maxLogs = 2000

    private var rt: LinuxRuntime { .shared }

    private func log(_ s: String) { NpcLog.write("[inject] " + s) }

    private func push(_ level: String, _ text: String) {
        DispatchQueue.main.async {
            self.logs.append(InjectLog(ts: Date(), level: level, text: text))
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
        }
    }

    // MARK: 探活 + 列目标

    /// 列出本机可注入的 App（对齐 FridaAppsView）
    func scan() {
        guard rt.stage.isReady else { status = "Linux 未启动"; return }
        busy = true; status = "扫描可注入 App…"
        Task {
            // frida-ps 列出所有进程；没有 frida 就退 ps
            let r = await rt.exec(
                "frida-ps -Uai 2>/dev/null || frida-ps -ai 2>/dev/null || ps -A 2>/dev/null",
                timeout: 30)
            let lines = r.out.split(separator: "\n").map(String.init)
            var built: [InjectTarget] = []
            for ln in lines {
                let t = ln.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("PID") { continue }
                // frida-ps -ai 输出形如 "1234  com.example.app  Name"
                let cols = t.split(separator: " ", maxSplits: 2).map(String.init)
                if cols.count >= 2, let pid = Int(cols[0]) {
                    let bid = cols[1]
                    let name = cols.count > 2 ? cols[2] : bid
                    built.append(InjectTarget(bundleId: bid, name: name, pid: pid, running: true))
                }
            }
            let result = built
            await MainActor.run {
                self.targets = result
                self.busy = false
                self.status = result.isEmpty ? "没扫到进程（frida-server 是否已起？）" : ""
            }
            self.log("scan \(result.count) procs")
        }
    }

    // MARK: 注入 dylib

    /// 把 dylib 注入目标进程（对齐 dylib_inject）
    func injectDylib(_ dylibPath: String, into bundleId: String, pid: Int) {
        guard rt.stage.isReady else { status = "Linux 未启动"; return }
        busy = true; status = "注入 \(bundleId)…"
        push("info", "注入 \(dylibPath) → \(bundleId)")

        Task {
            // 优先 frida 的 dlopen 注入，退 opainject（如果 rootfs 里有）
            let cmd: String
            if pid > 0 {
                cmd = """
                frida -p \(pid) -l /usr/share/npc/inject_loader.js 2>&1 \
                || (opainject \(pid) '\(esc(dylibPath))' 2>&1) \
                || echo "INJECT_FAILED"
                """
            } else {
                cmd = """
                frida -U -f \(bundleId) -l /usr/share/npc/inject_loader.js 2>&1 \
                || echo "INJECT_FAILED"
                """
            }
            let r = await rt.exec(cmd, timeout: 60)
            let ok = !r.out.contains("INJECT_FAILED") && r.code == 0
            let finalOut = r.out
            await MainActor.run {
                self.busy = false
                self.status = ok ? "注入完成" : "注入失败"
                self.push(ok ? "info" : "error", ok ? "注入成功：\(bundleId)" : "注入失败：\(finalOut.prefix(200))")
            }
            self.log("inject \(bundleId) \(ok)")
        }
    }

    // MARK: Frida hook

    /// 把一组 hook 规则编译成 Frida 脚本并注入（对齐 hookType 六类）
    func applyHooks(to bundleId: String, pid: Int) {
        guard rt.stage.isReady else { status = "Linux 未启动"; return }
        guard !hooks.isEmpty else { status = "没有 hook 规则"; return }
        busy = true; status = "应用 \(hooks.count) 条 hook…"

        let script = buildFridaScript(hooks)
        push("info", "应用 \(hooks.count) 条 hook → \(bundleId)")

        Task {
            // 先把脚本写进 guest，再让 frida 加载
            let b64 = script.data(using: .utf8)!.base64EncodedString()
            _ = await rt.exec("mkdir -p /usr/share/npc && echo '\(b64)' | base64 -d > /usr/share/npc/hook.js", timeout: 20)

            let target = pid > 0 ? "-p \(pid)" : "-U -f \(bundleId)"
            let r = await rt.exec("frida \(target) -l /usr/share/npc/hook.js 2>&1", timeout: 120)
            let out = r.out
            // frida 脚本里的 console.log / send 会出来，解析成日志
            await MainActor.run {
                self.busy = false
                self.status = ""
                for line in out.split(separator: "\n") {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { self.push("hook", s) }
                }
            }
            self.log("hooks \(bundleId) done")
        }
    }

    /// 把 hook 规则翻译成 Frida JavaScript
    func buildFridaScript(_ hooks: [FridaHook]) -> String {
        var js = """
        // NpcLab Frida hook —— 生成时间 \(Date())
        if (ObjC.available) {
          var count = 0;
        """
        for h in hooks {
            let cls = h.className.replacingOccurrences(of: "\"", with: "\\\"")
            let m = h.methodName.replacingOccurrences(of: "\"", with: "\\\"")
            let clsExpr = h.isClassMethod ? "ObjC.classes.\(cls)" : "ObjC.classes.\(cls)"
            let methodExpr = h.isClassMethod
                ? "\"+\(m)\"" : "\"-\(m)\""
            let rv = h.returnValue.replacingOccurrences(of: "\"", with: "\\\"")

            switch h.hookType {
            case .logMethod:
                js += """
                  try {
                    var m = \(clsExpr)[\(methodExpr)];
                    if (m) { Interceptor.attach(m.implementation, {
                      onEnter: function(a){ send({t:'call', c:'\(cls)', m:'\(m)'}); },
                      onLeave: function(r){ send({t:'ret', c:'\(cls)', m:'\(m)', v:String(r.retval)}); }
                    }); count++; }
                  } catch(e){}

                """
            case .returnConstant:
                js += """
                  try {
                    var m = \(clsExpr)[\(methodExpr)];
                    if (m) { Interceptor.replace(m.implementation, new NativeCallback(function(){
                      return \(rv.isEmpty ? "0" : rv);
                    }, 'void', [])); count++; }
                  } catch(e){}

                """
            case .blockMethod:
                js += """
                  try {
                    var m = \(clsExpr)[\(methodExpr)];
                    if (m) { Interceptor.replace(m.implementation, new NativeCallback(function(){
                      send({t:'block', c:'\(cls)', m:'\(m)'}); return 0;
                    }, 'void', [])); count++; }
                  } catch(e){}

                """
            case .modifyProperty:
                js += """
                  try {
                    var clsObj = \(clsExpr);
                    if (clsObj) { try { clsObj['\(h.property)'] = \(rv.isEmpty ? "0" : rv); } catch(e){} count++; }
                  } catch(e){}

                """
            case .flexOverride:
                js += """
                  try {
                    var m = \(clsExpr)[\(methodExpr)];
                    if (m) { var orig = m.implementation;
                      Interceptor.replace(orig, new NativeCallback(function(){
                        send({t:'flex', c:'\(cls)', m:'\(m)'});
                        return \(rv.isEmpty ? "0" : rv);
                      }, 'void', [])); count++; }
                  } catch(e){}

                """
            case .methodSwizzle:
                js += """
                  try {
                    var m = \(clsExpr)[\(methodExpr)];
                    if (m) { var orig = m.implementation;
                      Interceptor.attach(orig, { onEnter:function(){ send({t:'swizzle-in', c:'\(cls)', m:'\(m)'}); } });
                      count++; }
                  } catch(e){}

                """
            }
        }
        js += "  send({t:'done', count:count});\n}\n"
        return js
    }

    // MARK: 日志

    func clearLogs() { logs.removeAll() }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
