//
//  LinuxTypes.swift
//  NpcLab
//
//  LinuxRuntime 的真假两版（有内核 / 没内核）共用这些类型，
//  所以必须单独一个文件，否则两份实现会重复定义。
//

import SwiftUI

// MARK: - 终端行

struct TermLine: Identifiable, Hashable {
    enum Kind { case out, system, command, error }
    let id = UUID()
    var text: String
    var kind: Kind = .out
}

// MARK: - 运行状态

enum LinuxStage: Equatable {
    case idle
    case unpacking(Double)
    case booting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .idle:             return "未启动"
        case .unpacking(let p): return "解压 rootfs \(Int(p * 100))%"
        case .booting:          return "内核启动中"
        case .ready:            return "运行中"
        case .failed(let m):    return "失败：\(m)"
        }
    }

    var isReady: Bool { self == .ready }
}
