//
//  NpcLiveActivity.swift
//  NpcLabWidget
//
//  锁屏卡片 + 灵动岛。内核在解压 / 启动 / 跑长命令时显示，
//  干完自动消失，不会一直挂在锁屏上。
//
//  数据来自主 App 的 LiveActivityController（NpcLab/Core/LiveActivity.swift）。
//  Attributes 定义在共享文件 NpcLab/Core/NpcActivityAttributes.swift，两边都编。
//
//  iOS 16.1 才有 ActivityKit。整个 struct 用 @available 兜住，
//  16.0 的设备这段代码完全不参与编译产物。
//

import WidgetKit
import SwiftUI

#if canImport(ActivityKit)
import ActivityKit

// MARK: - 配色（跟主 App 的 Theme / NpcWidget 的 C 对齐，但各 target 不能互相引用）

private enum LC {
    static let accent = Color(red: 0.39, green: 0.55, blue: 1.0)
    static let green  = Color(red: 0.19, green: 0.82, blue: 0.45)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let red    = Color(red: 1.0, green: 0.32, blue: 0.28)
    static let teal   = Color(red: 0.20, green: 0.78, blue: 0.78)
    static let dim    = Color.white.opacity(0.42)
}

// MARK: - 锁屏 / 灵动岛

@available(iOSApplicationExtension 16.1, *)
struct NpcLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NpcActivityAttributes.self) { context in
            // 锁屏（以及不支持灵动岛机型的横幅）
            lockScreen(context.state, title: context.attributes.title)
                .activityBackgroundTint(Color(red: 0.043, green: 0.047, blue: 0.063))
                .activitySystemActionForegroundColor(LC.accent)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(s.kernelReady ? LC.green : LC.orange)
                            .frame(width: 7, height: 7)
                        Text(s.phase)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.kernelReady {
                        Text("\(s.lineCount) 行")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(LC.dim)
                    } else if s.progress >= 0 {
                        Text("\(Int(s.progress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(LC.orange)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LC.dim)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.progress >= 0 {
                        ProgressView(value: max(0, min(1, s.progress)))
                            .progressViewStyle(.linear)
                            .tint(LC.orange)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                            Text(s.detail.isEmpty ? "等待输出" : s.detail)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundColor(LC.dim)
                    }
                }
            } compactLeading: {
                Image(systemName: s.kernelReady ? "terminal.fill" : "hourglass")
                    .font(.system(size: 12))
                    .foregroundColor(s.kernelReady ? LC.green : LC.orange)
            } compactTrailing: {
                if s.progress >= 0 {
                    Text("\(Int(s.progress * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LC.orange)
                } else {
                    Text("\(s.lineCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LC.teal)
                }
            } minimal: {
                Image(systemName: s.kernelReady ? "terminal.fill" : "hourglass")
                    .font(.system(size: 11))
                    .foregroundColor(s.kernelReady ? LC.green : LC.orange)
            }
            .keylineTint(s.kernelReady ? LC.green : LC.orange)
        }
    }

    // MARK: 锁屏卡片

    @ViewBuilder
    private func lockScreen(_ s: NpcActivityAttributes.ContentState,
                            title: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(s.kernelReady ? LC.green : LC.orange)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if s.kernelReady {
                    // 走秒，让用户看到"还在跑"而不是"卡住了"
                    Text(timerInterval: s.startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LC.dim)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            HStack(spacing: 6) {
                Text(s.phase)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(s.kernelReady ? LC.green : LC.orange)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(LC.dim)
                Text(s.detail.isEmpty ? "—" : s.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(LC.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if s.progress >= 0 {
                ProgressView(value: max(0, min(1, s.progress)))
                    .progressViewStyle(.linear)
                    .tint(LC.orange)
            } else if s.kernelReady {
                HStack(spacing: 4) {
                    Text("\(s.lineCount)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(LC.teal)
                    Text("行输出")
                        .font(.system(size: 10))
                        .foregroundColor(LC.dim)
                    Spacer()
                }
            }
        }
        .padding(14)
    }
}

#endif
