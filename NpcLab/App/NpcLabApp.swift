import SwiftUI

@main
struct NpcLabApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var hub = NodeHub()
    @StateObject private var engine = ChatEngine()
    @StateObject private var agent = ToolAgent()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(hub)
                .environmentObject(engine)
                .environmentObject(agent)
                .preferredColorScheme(.dark)
                .tint(T.accent)
                .onAppear {
                    // 首帧就把节点状态拉一次，Layer 4 才不会写错
                    if settings.bridgeOn { hub.refresh(settings) }

                    // 上次被系统杀进程时可能留了张锁屏卡，先收掉
                    LiveActivity.reconcile()

                    // 文件 App 里挂一个 NpcLab 位置（没有 App Group 时静默跳过）
                    Workspace.registerFileProvider()

                    // 分享扩展收进来的东西搬进工作区
                    let n = Workspace.inboxItems().compactMap { Workspace.adopt($0) }.count
                    if n > 0 {
                        NSLog("[NpcLab] 从分享收件箱导入 \(n) 个文件")
                    }

                    WidgetBridge.setKernel(LinuxRuntime.shared.stage.isReady ? 1 : 0,
                                           stage: LinuxRuntime.shared.stage.label)
                    WidgetBridge.setNode(hub.state.online)

                    // 本机真 MITM 抓包拦截器（对齐 AzTuT 的 URLProtocol 拦截）。
                    // 授权打开时注册，App 内所有走 URLSession 的请求都能被抓到解密。
                    MITMInterceptor.shared.setEnabled(settings.allowProxy)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub
    @Environment(\.scenePhase) private var phase

    @StateObject private var lock = AppLock()

    @State private var tab = 0
    @State private var showWelcome = false

    var body: some View {
        ZStack {
            if lock.state == .unlocked {
                tabs
            } else {
                LockScreen(lock: lock)
                    .transition(.opacity)
            }
        }
        .onAppear {
            lock.sync(enabled: st.faceIDLock)
            // 锁屏挡着的时候别弹欢迎页，等解锁再说
            if lock.state == .unlocked,
               !UserDefaults.standard.bool(forKey: "npclab.welcomed") {
                showWelcome = true
                UserDefaults.standard.set(true, forKey: "npclab.welcomed")
            }
        }
        .onChange(of: phase) { p in
            switch p {
            case .background: lock.didEnterBackground()
            case .active:     lock.willEnterForeground()
            default:          break
            }
        }
        .onChange(of: st.faceIDLock) { on in
            lock.sync(enabled: on)
            if !on { lock.forceUnlock() }
        }
        .sheet(isPresented: $showWelcome) {
            Welcome()
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ChatView()
            }
            .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right.fill") }
            .tag(0)

            NavigationStack {
                ThoughtView()
            }
            .tabItem { Label("思维", systemImage: "brain.head.profile") }
            .tag(1)

            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("技能", systemImage: "square.stack.3d.up.fill") }
            .tag(2)

            NavigationStack {
                TerminalView()
            }
            .tabItem { Label("终端", systemImage: "terminal.fill") }
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
            .tag(4)
        }
    }
}

struct Welcome: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var st: AppSettings

    private let steps: [(String, String, String)] = [
        ("1", "填模型", "设置 → 模型：接口地址、API Key、模型名。OpenAI 兼容与 Anthropic 两套协议都吃。"),
        ("2", "看注入", "对话页左上角那个数字是当前 SYSTEM 的体积，点开能看到五层原文。"),
        ("3", "用终端", "终端页第一次进来会解 rootfs（139MB，约十几秒），之后秒开。里面是真的 Alpine：sh、python3、radare2 都有。"),
        ("4", "接节点（可选）", "设置 → 算力节点：填 PC 上 npclab 的 IP:8790。逆向和抓包的本机模式不接也能用。")
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("小徐TuT").font(.system(size: 26, weight: .bold)).foregroundColor(T.txt)
                        Text("装在手机上的那个。人设、\(PackData.shared.skills.count) 条技能、\(PackData.shared.tools.count) 项工具全在本地，断网也能看。")
                            .font(.system(size: 12.5)).foregroundColor(T.txt2)
                    }
                    .padding(.bottom, 4)

                    ForEach(steps.indices, id: \.self) { i in
                        Card {
                            HStack(alignment: .top, spacing: 10) {
                                Text(steps[i].0)
                                    .font(T.mono(11, .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 20, height: 20)
                                    .background(T.accent)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(steps[i].1).font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(T.txt)
                                    Text(steps[i].2).font(.system(size: 11.5))
                                        .foregroundColor(T.txt2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Card {
                        Text("执行能力从哪来").font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(T.orange)
                        Text("终端是一个真的 Linux：iSH 内核 + Alpine rootfs 都编译进了 App，sh、python3、radare2 5.9.8 直接在里面跑。逆向分析调的就是它；抓包是本机 HTTP 代理。节点只是可选增强，不开也能用。")
                            .font(.system(size: 11.5)).foregroundColor(T.txt2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .background(Backdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
