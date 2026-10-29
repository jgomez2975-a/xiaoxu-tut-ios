//
//  AppInventory.swift
//  NpcLab
//
//  列出本机已安装 App，并把「目标 App」的主二进制 + 数据容器定位出来，
//  交给 RevLocal 送进 guest 做逆向。对齐 AzTuT 的「逆向分析的目标应用」：
//  点中某个 App → 拉它的可执行文件 + 沙盒数据容器（含 sqlite）→ radare2 分析。
//
//  iOS 沙箱（非越狱）里 App 之间互相不可见，所以枚举走两条路，能拿到哪条用哪条：
//    1) LSApplicationWorkspace（私有 API）—— 宿主侧直接列 bundleId + 显示名；
//       设备里 main executable 路径用 NSBundle 的私有路径推断不了，只能拿 bundleId。
//    2) guest Linux 里枚举文件系统 —— iSH fakefs 若映射了宿主 FS，则能直接
//       ls /var/containers/Bundle/Application 拿到 .app 目录与 Info.plist 里的
//       CFBundleExecutable，这才是 AzTuT 真正走的「文件系统直读」路线。
//
//  无论哪条路拿到的结果，都统一成 InstalledApp 结构给 UI 展示。
//

import Foundation

// MARK: - 数据

struct InstalledApp: Identifiable, Hashable {
    var bundleId: String
    var name: String
    var executable: String       // CFBundleExecutable 名（如 MyApp）
    var appPath: String          // .app 目录（guest 或宿主路径）
    var dataContainer: String    // 数据容器路径（/var/mobile/Containers/Data/Application/<uuid>）
    var version: String = ""
    var id: String { bundleId }

    /// 主二进制完整路径（.app 目录 + 可执行文件名）
    var binaryPath: String {
        appPath.hasSuffix("/") ? appPath + executable : appPath + "/" + executable
    }
}

// MARK: - 引擎

final class AppInventory: ObservableObject {

    static let shared = AppInventory()

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    private var rt: LinuxRuntime { .shared }

    // MARK: 宿主侧枚举（LSApplicationWorkspace 私有 API）

    /// 私有 API 列 bundleId + 显示名。审核环境用不到，但这是 AzTuT 同款能力，
    /// 越狱/侧载环境下真实可用。拿不到就用 guest 文件系统枚举兜底。
    func scanHost() {
        busy = true
        status = "枚举已安装 App…"
        var built: [InstalledApp] = []

        // LSApplicationWorkspace 是私有 API：NSClassFromString 动态取，编译期不依赖头文件
        guard let cls: AnyClass = NSClassFromString("LSApplicationWorkspace") else {
            // 私有类不存在（普通 App Store 环境），交给 guest 枚举
            scanGuest()
            return
        }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        let selAll = NSSelectorFromString("allApplications")
        guard let ws = (cls as AnyObject).perform?(selDefault)?.takeUnretainedValue() else {
            scanGuest()
            return
        }
        guard let arr = (ws as AnyObject).perform?(selAll)?.takeUnretainedValue() as? [AnyObject] else {
            scanGuest()
            return
        }

        for app in arr {
            var bid = ""
            var name = ""
            var exe = ""
            if let v = app.perform?(NSSelectorFromString("bundleIdentifier"))?
                .takeUnretainedValue() as? String { bid = v }
            if let v = app.perform?(NSSelectorFromString("localizedName"))?
                .takeUnretainedValue() as? String { name = v }
            if let v = app.perform?(NSSelectorFromString("bundleExecutable"))?
                .takeUnretainedValue() as? String { exe = v }
            if bid.isEmpty { continue }
            // 宿主侧拿不到 .app 绝对路径，标记为空，等 guest 侧补
            built.append(InstalledApp(bundleId: bid, name: name.isEmpty ? bid : name,
                                      executable: exe, appPath: "", dataContainer: ""))
        }

        let result = built.sorted { $0.name < $1.name }
        DispatchQueue.main.async {
            self.apps = result
            self.busy = false
            self.status = result.isEmpty ? "没枚举到 App" : ""
        }
    }

    // MARK: guest 文件系统枚举（AzTuT 直读路线）

    /// 在 guest Linux 里枚举 iOS 的应用安装目录。iSH 的 fakefs 默认不挂宿主 FS，
    /// 但只要 rootfs 里映射了 /var/containers 就能拿到真实 App 清单。
    func scanGuest() {
        guard rt.stage.isReady else {
            status = "Linux 未启动（先到终端页启内核）"
            busy = false
            return
        }
        busy = true
        status = "在 Linux 里枚举 /var/containers…"
        Task {
            // 逐个候选目录找。iOS 装 App 的位置：
            //   /var/containers/Bundle/Application/<uuid>/*.app
            //   /private/var/containers/Bundle/Application/<uuid>/*.app
            let bases = [
                "/var/containers/Bundle/Application",
                "/private/var/containers/Bundle/Application",
                "/var/mobile/Containers/Bundle/Application",
            ]
            var found: [InstalledApp] = []
            for base in bases {
                let r = await rt.exec(
                    "for d in '\(base)'/*/; do "
                    + "app=$(ls -d \"$d\"*.app 2>/dev/null | head -1); "
                    + "[ -n \"$app\" ] || continue; "
                    + "plist=\"$app/Info.plist\"; "
                    + "[ -f \"$plist\" ] || continue; "
                    + "echo \"$app\"; "
                    + "done 2>/dev/null",
                    timeout: 60)
                for line in r.out.split(separator: "\n") {
                    let appDir = String(line).trimmingCharacters(in: .whitespaces)
                    if appDir.isEmpty || !appDir.hasSuffix(".app") { continue }
                    if let info = await parseAppInfo(appDir) {
                        found.append(info)
                    }
                }
                if !found.isEmpty { break }
            }

            let result = found.sorted { $0.name < $1.name }
            await MainActor.run {
                self.apps = result
                self.busy = false
                self.status = result.isEmpty
                    ? "文件系统里没读到 /var/containers（本机非越狱时需先挂宿主 FS）"
                    : ""
            }
        }
    }

    /// 读 .app/Info.plist 里的 CFBundleIdentifier / CFBundleExecutable / 显示名，
    /// 并顺带定位数据容器。
    private func parseAppInfo(_ appDir: String) async -> InstalledApp? {
        let plist = "\(appDir)/Info.plist"
        let r = await rt.exec(
            "python3 -c 'import plistlib,sys; "
            + "d=plistlib.load(open(sys.argv[1],\"rb\")); "
            + "print(d.get(\"CFBundleIdentifier\",\"\")); "
            + "print(d.get(\"CFBundleExecutable\",\"\")); "
            + "print(d.get(\"CFBundleDisplayName\", d.get(\"CFBundleName\",\"\"))); "
            + "print(d.get(\"CFBundleShortVersionString\",\"\"))' '\(plist)' 2>/dev/null",
            timeout: 30)
        let lines = r.out.split(separator: "\n").map(String.init)
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        let bid = lines[0]
        let exe = lines[1]
        let name = lines.count > 2 && !lines[2].isEmpty ? lines[2] : bid
        let ver = lines.count > 3 ? lines[3] : ""

        // 数据容器：bundleId 的沙盒数据通常在 /var/mobile/Containers/Data/Application/<uuid>
        // 用 .com.apple.mobile_container_manager.metadata.plist 反查
        let dc = await findDataContainer(bid)

        return InstalledApp(bundleId: bid, name: name, executable: exe,
                            appPath: appDir, dataContainer: dc, version: ver)
    }

    /// 在数据容器目录里按 bundleId 反查 uuid
    private func findDataContainer(_ bundleId: String) async -> String {
        let r = await rt.exec(
            "for d in /var/mobile/Containers/Data/Application/*/ "
            + "/private/var/mobile/Containers/Data/Application/*/; do "
            + "p=\"$d/.com.apple.mobile_container_manager.metadata.plist\"; "
            + "[ -f \"$p\" ] || continue; "
            + "if python3 -c 'import plistlib,sys; "
            + "d=plistlib.load(open(sys.argv[1],\"rb\")); "
            + "sys.exit(0 if d.get(\"MCMMetadataIdentifier\",\"\")==sys.argv[2] else 1)' "
            + "'$p' '\(bundleId)' 2>/dev/null; then echo \"$d\"; break; fi; "
            + "done 2>/dev/null",
            timeout: 60)
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    // MARK: 拉目标 App 进 guest（供逆向用）

    /// 把目标 App 主二进制灌进 guest 的 /root/npc/apps/<bundleId>/，
    /// 返回 guest 内二进制路径，供 RevLocal.analyze 直接分析。
    func importAppBinary(_ app: InstalledApp) async -> String? {
        guard rt.stage.isReady else { return nil }
        let src = app.binaryPath
        let dir = "/root/npc/apps/\(app.bundleId)"
        let dst = "\(dir)/\(app.executable)"

        // 先看 guest 里能不能直接读（fakefs 映射宿主 FS 的情况），能读就零拷贝
        let probe = await rt.exec("ls -l '\(src)' 2>/dev/null && echo OK", timeout: 20)
        if probe.out.contains("OK") {
            _ = await rt.exec("mkdir -p '\(dir)'; ln -sf '\(src)' '\(dst)' 2>/dev/null || cp '\(src)' '\(dst)'", timeout: 60)
            return dst
        }
        return nil
    }
}
