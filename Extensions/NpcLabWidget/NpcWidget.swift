//
//  NpcWidget.swift
//  NpcLabWidget
//
//  桌面小组件：一眼看到内核在不在跑、节点通不通、最近一条命令是什么。
//
//  数据来自 App Group 的 UserDefaults。主 App 侧由 WidgetBridge 写入，
//  键名两边必须一致（见 NpcLab/Core/WidgetBridge.swift）。
//

import WidgetKit
import SwiftUI

// MARK: - 共享键

private enum K {
    static let group = "group.com.npclab.client"
    static let kernel = "w.kernel"      // 0 未启动 1 就绪 2 失败
    static let node = "w.node"          // 0 离线 1 在线
    static let lastCmd = "w.lastCmd"
    static let lastOut = "w.lastOut"
    static let updated = "w.updated"
    static let stageText = "w.stage"
}

// MARK: - 时间线

struct NpcEntry: TimelineEntry {
    let date: Date
    let kernelState: Int
    let nodeOnline: Bool
    let stage: String
    let lastCmd: String
    let lastOut: String
}

struct NpcProvider: TimelineProvider {

    func placeholder(in context: Context) -> NpcEntry {
        NpcEntry(date: Date(), kernelState: 1, nodeOnline: true,
                 stage: "运行中", lastCmd: "uname -a",
                 lastOut: "Linux npclab 5.15 aarch64")
    }

    func getSnapshot(in context: Context, completion: @escaping (NpcEntry) -> Void) {
        completion(read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NpcEntry>) -> Void) {
        let e = read()
        // 5 分钟刷一次就够了，Widget 本来也不该高频跑
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
        completion(Timeline(entries: [e], policy: .after(next)))
    }

    private func read() -> NpcEntry {
        let d = UserDefaults(suiteName: K.group) ?? .standard
        return NpcEntry(
            date: Date(),
            kernelState: d.integer(forKey: K.kernel),
            nodeOnline: d.bool(forKey: K.node),
            stage: d.string(forKey: K.stageText) ?? "未启动",
            lastCmd: d.string(forKey: K.lastCmd) ?? "—",
            lastOut: d.string(forKey: K.lastOut) ?? "还没有执行过命令"
        )
    }
}

// MARK: - 配色（跟主 App 的 Theme 对齐，但 Widget 不能引用主 target）

private enum C {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.063)
    static let bg2 = Color(red: 0.075, green: 0.082, blue: 0.106)
    static let txt = Color(red: 0.95, green: 0.955, blue: 0.97)
    static let txt2 = Color.white.opacity(0.58)
    static let txt3 = Color.white.opacity(0.34)
    static let accent = Color(red: 0.39, green: 0.55, blue: 1.0)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.45)
    static let red = Color(red: 1.0, green: 0.32, blue: 0.28)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let teal = Color(red: 0.20, green: 0.78, blue: 0.78)
}

// MARK: - 视图

struct NpcWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NpcEntry

    private var kernelColor: Color {
        switch entry.kernelState {
        case 1:  return C.green
        case 2:  return C.red
        default: return C.txt3
        }
    }

    private var kernelLabel: String {
        switch entry.kernelState {
        case 1:  return entry.stage
        case 2:  return "启动失败"
        default: return "未启动"
        }
    }

    var body: some View {
        ZStack {
            C.bg
            switch family {
            case .systemSmall:  small
            default:            medium
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(kernelColor).frame(width: 6, height: 6)
                Text("Linux").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(C.txt)
                Spacer()
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9)).foregroundColor(C.accent)
            }
            Text(kernelLabel)
                .font(.system(size: 9.5))
                .foregroundColor(C.txt2)
                .lineLimit(1)

            Divider().overlay(Color.white.opacity(0.1))

            Text(entry.lastCmd)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(C.teal)
                .lineLimit(2)

            Text(entry.lastOut)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundColor(C.txt3)
                .lineLimit(3)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Circle()
                    .fill(entry.nodeOnline ? C.green : C.txt3)
                    .frame(width: 4, height: 4)
                Text(entry.nodeOnline ? "节点在线" : "节点离线")
                    .font(.system(size: 8)).foregroundColor(C.txt3)
            }
        }
        .padding(11)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(kernelColor).frame(width: 7, height: 7)
                    Text("小徐TuT").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(C.txt)
                }
                Text(kernelLabel)
                    .font(.system(size: 10)).foregroundColor(C.txt2)
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.nodeOnline ? C.green : C.txt3)
                        .frame(width: 5, height: 5)
                    Text(entry.nodeOnline ? "节点在线" : "节点离线")
                        .font(.system(size: 9)).foregroundColor(C.txt3)
                }
            }
            .frame(width: 92, alignment: .leading)

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.lastCmd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(C.teal)
                    .lineLimit(1)
                Text(entry.lastOut)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(C.txt2)
                    .lineLimit(7)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }
}

// MARK: - 入口

@main
struct NpcWidgetBundle: WidgetBundle {
    var body: some Widget {
        NpcWidget()
        #if canImport(ActivityKit)
        // 16.1 才有 ActivityKit，以下机型不编进来
        if #available(iOSApplicationExtension 16.1, *) {
            NpcLiveActivityWidget()
        }
        #endif
    }
}

struct NpcWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NpcLabWidget", provider: NpcProvider()) { entry in
            NpcWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("小徐TuT")
        .description("看内核在不在跑、节点通不通、最近执行了什么。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
