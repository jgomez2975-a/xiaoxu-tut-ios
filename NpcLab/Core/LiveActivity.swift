//
//  LiveActivity.swift
//  NpcLab
//
//  锁屏/灵动岛的启停。真正画界面的是 NpcLabWidget 扩展里的 NpcLiveActivityWidget，
//  这里只负责要不要起、什么时候更、什么时候收。
//
//  什么时候起：内核解压 / 启动 / 跑超过 3 秒的命令。
//  什么时候收：就绪后 2 秒、命令跑完、或用户手动关。
//
//  为什么不一直挂着：Live Activity 占锁屏空间，用户开一次终端就留一张卡片在锁屏上
//  会烦。Minis 只在后台任务时挂，我们照做。
//
//  iOS 16.1 以下没有 ActivityKit —— 所有入口都静默 return，不报错不崩。
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)

@available(iOS 16.2, *)
final class LiveActivityController {

    static let shared = LiveActivityController()
    private init() {}

    private var activity: Activity<NpcActivityAttributes>?
    private var lastUpdate = Date.distantPast

    /// 同一个活动 1.5 秒内不重复 update，避免刷屏（系统对更新频率也有限制）
    private let minInterval: TimeInterval = 1.5

    // MARK: 生命周期

    /// 清掉上次被系统杀进程时留下的孤儿活动。App 启动时叫一次。
    func reconcile() {
        let stale = Activity<NpcActivityAttributes>.activities
        guard !stale.isEmpty else { return }
        for a in stale {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    /// 起活动。已经有一个就不重复起，直接更新。
    /// - Parameters:
    ///   - title: 卡片抬头，一般传「小徐TuT」
    ///   - state: 初始状态
    func start(title: String = "小徐TuT",
               state: NpcActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if activity != nil {
            update(state, force: true)
            return
        }

        // 先清掉可能存在的孤儿，否则会同时挂两张卡
        for old in Activity<NpcActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }

        let attrs = NpcActivityAttributes(title: title)
        do {
            activity = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            lastUpdate = Date()
        } catch {
            // 用户关了「设置 → 通知 → 实时活动」时会抛，属于正常情况
            activity = nil
        }
    }

    /// 更内容。默认自带频率限制，`force` 可绕过。
    func update(_ state: NpcActivityAttributes.ContentState, force: Bool = false) {
        guard let a = activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= minInterval else { return }
        lastUpdate = now
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    /// 收活动。先给 1.5 秒让用户看到「完成」，再移出锁屏。
    func end(_ final: NpcActivityAttributes.ContentState? = nil,
             immediately: Bool = false) {
        guard let a = activity else { return }
        activity = nil
        Task {
            if let f = final {
                await a.end(.init(state: f, staleDate: Date()),
                            dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(1.5)))
            } else {
                await a.end(nil, dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(1.5)))
            }
        }
    }

    var isActive: Bool { activity != nil }
}

/// 全局小门面。不是 16.1 时全是空操作，调用方不用到处写 @available。
enum LiveActivity {

    static func reconcile() {
        if #available(iOS 16.2, *) {
            LiveActivityController.shared.reconcile()
        }
    }

    /// 内核在解压 rootfs
    static func unpacking(_ pct: Double) {
        guard #available(iOS 16.2, *) else { return }
        LiveActivityController.shared.start(state: .unpacking(pct))
    }

    /// 内核在启动
    static func booting(_ detail: String) {
        guard #available(iOS 16.2, *) else { return }
        LiveActivityController.shared.start(state: .booting(detail))
    }

    /// 就绪了 —— 收掉卡片
    static func ready() {
        guard #available(iOS 16.2, *) else { return }
        LiveActivityController.shared.end()
    }

    /// 在跑命令
    static func running(_ cmd: String, lines: Int) {
        guard #available(iOS 16.2, *) else { return }
        LiveActivityController.shared.update(.running(cmd, lines: lines))
    }

    /// 命令跑完
    static func finished(_ cmd: String, lines: Int) {
        guard #available(iOS 16.2, *) else { return }
        var s = NpcActivityAttributes.ContentState.running(cmd, lines: lines)
        s.phase = "完成"
        s.progress = 1
        LiveActivityController.shared.end(s)
    }

    static func stop() {
        if #available(iOS 16.2, *) {
            LiveActivityController.shared.end(nil, immediately: true)
        }
    }
}

#else

// 没有 ActivityKit 的 SDK（Xcode 14.0 及更早）下给一套空壳，
// 让调用方照常写 LiveActivity.xxx()，不用到处包 #if。
enum LiveActivity {
    static func reconcile() {}
    static func unpacking(_ pct: Double) {}
    static func booting(_ detail: String) {}
    static func ready() {}
    static func running(_ cmd: String, lines: Int) {}
    static func finished(_ cmd: String, lines: Int) {}
    static func stop() {}
}

#endif
