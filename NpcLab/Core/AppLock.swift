//
//  AppLock.swift
//  NpcLab
//
//  Face ID / Touch ID / 密码门禁。
//
//  设置页那个「Face ID 保护」开关以前只存了个 bool，什么都不做。这里是真接上：
//  冷启动、以及退到后台超过 `graceSeconds` 再回来，都会挡住界面。
//
//  为什么用 `.deviceOwnerAuthentication` 而不是 `.deviceOwnerAuthenticationWithBiometrics`：
//  后者在没录面容的设备上直接失败，用户就永远进不来了。前者会回落到锁屏密码，
//  这是 Apple 的推荐用法（见 LAContext 文档）。
//
//  注意：这个门禁只挡「看界面」，不加密数据。真要加密得把 rootfs 和 key 走
//  Keychain + kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly，那是另一件事。
//

import Foundation
import SwiftUI
import LocalAuthentication

@MainActor
final class AppLock: ObservableObject {

    enum State: Equatable {
        case unlocked                 // 放行
        case locked                   // 挡住，等验证
        case checking                 // 正在弹 Face ID
        case unavailable(String)      // 设备不支持 / 没设密码，只能放行
    }

    @Published private(set) var state: State = .unlocked
    @Published private(set) var lastError: String?

    /// 退后台多久之后回来要重新验。太短会很烦（切个微信回来就要刷脸）。
    var graceSeconds: TimeInterval = 60

    private var leftAt: Date?
    private var enabled = false

    /// 由 RootView 在首帧和 scenePhase 变化时喂进来
    func sync(enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            state = .unlocked
            return
        }
        if state == .unlocked && leftAt == nil {
            // 冷启动：直接从 locked 开始，等 RootView 触发 verify
            state = .locked
        }
    }

    // MARK: 前后台

    func didEnterBackground() {
        leftAt = Date()
    }

    func willEnterForeground() {
        guard enabled else { return }
        guard let t = leftAt else { return }
        leftAt = nil
        if Date().timeIntervalSince(t) >= graceSeconds {
            state = .locked
        }
    }

    // MARK: 验证

    /// 弹系统验证。成功置 unlocked，取消/失败保持 locked。
    func verify() async {
        guard enabled, state == .locked else { return }

        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        ctx.localizedFallbackTitle = "用密码"

        var err: NSError?
        // 先探一下有没有可用的验证方式。没有就放行 ——
        // 锁不住的前提下把人关在外面，比不锁更糟。
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lastError = (err?.localizedDescription) ?? "设备未设置密码"
            state = .unlocked
            return
        }

        state = .checking
        lastError = nil
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "解锁 小徐TuT"
            )
            state = ok ? .unlocked : .locked
            if !ok { lastError = "验证未通过" }
        } catch {
            // LAError.userCancel 是用户主动取消，不该报错刷屏
            let code = (error as NSError).code
            if code == LAError.userCancel.rawValue || code == LAError.appCancel.rawValue {
                state = .locked
            } else {
                state = .locked
                lastError = error.localizedDescription
            }
        }
    }

    /// 用户在设置里关掉开关时直接放行
    func forceUnlock() {
        state = .unlocked
    }
}

// MARK: - 遮罩

/// 挡住整个 App 的一层。不放任何真实内容，只给一个「解锁」按钮。
struct LockScreen: View {

    @ObservedObject var lock: AppLock

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(T.accent)

                VStack(spacing: 5) {
                    Text("小徐TuT 已锁定")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(T.txt)
                    subtitle
                        .font(.system(size: 12))
                        .foregroundColor(T.txt2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 36)
                }

                if case .checking = lock.state {
                    ProgressView().tint(T.accent).padding(.top, 4)
                } else {
                    Button {
                        Task { await lock.verify() }
                    } label: {
                        Text("解锁")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 150, height: 40)
                            .background(T.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                if let e = lock.lastError {
                    Text(verbatim: e)
                        .font(.system(size: 11))
                        .foregroundColor(T.red)
                }
            }
        }
        .onAppear {
            Task { await lock.verify() }
        }
    }

    /// 返回 Text 而不是 String —— 这样 "正在验证身份…" 这类串是
    /// LocalizedStringKey，能被 gen_l10n.py 抽到并翻译。
    /// 错误信息那条走 Text(verbatim:)，系统抛的本地化文案不该再被我们包一层。
    private var subtitle: Text {
        switch lock.state {
        case .checking:
            return Text("正在验证身份…")
        case .unavailable(let m):
            return Text(verbatim: m)
        default:
            return Text("用 Face ID 或设备密码继续")
        }
    }
}
