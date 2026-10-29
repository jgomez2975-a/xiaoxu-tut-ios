//
//  NpcLog.swift
//  NpcLab
//
//  落盘日志。闪退这类问题，内存里的日志随进程一起没了，只有文件能留下痕迹：
//  下次启动把 Documents/npclab.log 发出来就能定位到停在哪一步。
//
//  写入频率不高（启动流程 + 关键操作），直接 append 就够，不搞 ring buffer。
//

import Foundation

enum NpcLog {

    /// 单文件上限，超了就从中间截断一次，避免无限长
    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "npclab.log")

    static var url: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return d.appendingPathComponent("npclab.log")
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ s: String) {
        let line = fmt.string(from: Date()) + "  " + s + "\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? data.write(to: url)
                return
            }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            }
        }
    }

    /// 读末尾若干行，给日志页展示
    static func tail(_ lines: Int = 200) -> String {
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let arr = all.split(separator: "\n", omittingEmptySubsequences: false)
        let n = max(0, arr.count - lines)
        return arr[n...].joined(separator: "\n")
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// 超过上限时把前半截丢掉
    static func trimIfNeeded() {
        queue.async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size > maxBytes,
                  let all = try? String(contentsOf: url, encoding: .utf8) else { return }
            let keep = all.suffix(maxBytes / 2)
            try? String(keep).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
