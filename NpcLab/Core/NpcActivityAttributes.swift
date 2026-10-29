//
//  NpcActivityAttributes.swift
//  NpcLab
//
//  Live Activity 的数据契约。**这个文件同时编进主 App 和 NpcLabWidget 扩展**
//  （见 Tools/gen_xcodeproj.py 的 SHARED_SOURCES）。
//
//  为什么必须共享：主 App 拿它 Activity.request() 起活动，扩展拿它渲染锁屏卡片，
//  两边 struct 字段必须逐字一致，否则解不出来就直接不显示。
//  Apple 自己的 Food Truck 示例也是这么放的，靠 Codable 过 XPC，不需要 framework。
//
//  16.1 才有 ActivityKit，16.0 的设备静默跳过（见 LiveActivityController）。
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)

/// 活动的不变部分：创建时定死，之后不能改。
struct NpcActivityAttributes: ActivityAttributes {

    /// 会变的部分。每次 update 传一个新的。
    struct ContentState: Codable, Hashable {
        /// 粗粒度阶段，显示在标题位：解压 / 启动 / 就绪 / 执行
        var phase: String
        /// 细一行，显示在副标题：具体在干什么
        var detail: String
        /// 0...1；负数表示不确定进度（跑长命令时不知道还剩多少）
        var progress: Double
        /// 内核是否已就绪
        var kernelReady: Bool
        /// 已产出的行数，用来让用户知道还在动
        var lineCount: Int
        /// 开始时间，锁屏上用 Text(timerInterval:) 走秒
        var startedAt: Date

        static func unpacking(_ pct: Double) -> ContentState {
            ContentState(phase: "解压 rootfs",
                         detail: "\(Int(pct * 100))%",
                         progress: pct, kernelReady: false,
                         lineCount: 0, startedAt: Date())
        }

        static func booting(_ detail: String) -> ContentState {
            ContentState(phase: "内核启动", detail: detail,
                         progress: -1, kernelReady: false,
                         lineCount: 0, startedAt: Date())
        }

        static func running(_ cmd: String, lines: Int) -> ContentState {
            ContentState(phase: "执行中", detail: cmd,
                         progress: -1, kernelReady: true,
                         lineCount: lines, startedAt: Date())
        }
    }

    /// 固定标题，一般是「小徐TuT」或任务名
    var title: String
}

#endif
