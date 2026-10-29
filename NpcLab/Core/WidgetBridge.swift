//
//  WidgetBridge.swift
//  NpcLab
//
//  主 App 往 App Group 的 UserDefaults 里写状态，桌面小组件读它。
//
//  键名必须跟 Extensions/NpcLabWidget/NpcWidget.swift 里的 K 枚举一致，
//  两边是独立 target，没法共享常量，改的时候要一起改。
//

import Foundation
import WidgetKit

enum WidgetBridge {

    static let group = "group.com.npclab.client"

    private enum K {
        static let kernel = "w.kernel"      // 0 未启动 1 就绪 2 失败
        static let node = "w.node"
        static let lastCmd = "w.lastCmd"
        static let lastOut = "w.lastOut"
        static let stage = "w.stage"
        static let updated = "w.updated"
    }

    private static var store: UserDefaults {
        UserDefaults(suiteName: group) ?? .standard
    }

    /// 内核状态：0 未启动 / 1 就绪 / 2 失败
    static func setKernel(_ state: Int, stage: String) {
        let d = store
        d.set(state, forKey: K.kernel)
        d.set(stage, forKey: K.stage)
        d.set(Date(), forKey: K.updated)
        reload()
    }

    static func setNode(_ online: Bool) {
        store.set(online, forKey: K.node)
        reload()
    }

    /// 记一条命令和它的输出（只留前 300 字，Widget 也放不下更多）
    static func setLast(cmd: String, out: String) {
        let d = store
        d.set(cmd, forKey: K.lastCmd)
        d.set(String(out.prefix(300)), forKey: K.lastOut)
        d.set(Date(), forKey: K.updated)
        reload()
    }

    /// 主动让 Widget 重画（不然要等 5 分钟的下一次时间线）
    private static func reload() {
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
