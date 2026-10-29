# 小徐TuT —— 手机上的那个

原生 SwiftUI 客户端。给人 iPhone 装的东西，不是网页，不是 PC 工具。

> 工程代号仍叫 NpcLab（目录名、bundle id、target 名都没动）；对外显示名与 ipa 名是 **小徐TuT**。
> 改名的三个落点见文末「改名字 / 换图标」。

```
NpcLab/             Swift 源码 + 内置资源（skills/tools/docs/rootfs/人设）
Extensions/         分享 / 文件 App / 小组件 三个 appex
deps/ish/           iSH 内核源码（上游 vendored，GPLv3）
Vendor/             libishkernel.a —— 编完才有，.gitignore 里
Tools/              build_ish.sh（编内核）/ build_ipa.sh（出包）/ 数据打包 / 工程生成
Tools/rootfs_parts/ alpine-rootfs.zip 的 14 段（各 10MB，build 时拼回）
NpcLab.xcodeproj/   直接 open 的工程（脚本生成，别手改）
.github/workflows/  云编译：编内核 → 出 unsigned ipa → 传 artifact
```

> **rootfs 为什么要切段**：`alpine-rootfs.zip` 有 138.7MB，GitHub 对单个文件卡 100MB，普通 git 推送会被直接拒。
> 所以仓库里存的是 `Tools/rootfs_parts/*.part-000..013`（10MB×13 + 8.7MB），加一张 `manifest.txt`。
> `build_ipa.sh` 和 CI 都会自动调 `Tools/join_rootfs.sh` 拼回来，克隆完不用手动做什么。
>
> 拼接有三道闸，任何一道不过就 `exit 1`，不会静默产出坏包：
>
> | 闸 | 拦什么 | 实测 |
> |---|---|---|
> | 段号来自 `manifest.txt`，不靠 glob 排序 | 文件被改名、多出残留段 | — |
> | 每段字节数比对 | 少下一段、下成半截、网盘截断 | 少 002 → `缺段 002`；截到 40MB → `大小不对` |
> | 拼完算 sha256 | 段内任意一个字节被改、顺序被对调 | 改 1 字节 / 000·001 对调 → `sha256 不符` |
>
> 换 rootfs 时：`python3 Tools/split_rootfs.py` 重切 + 重生成清单，再 `bash Tools/join_rootfs.sh` 自检回来。

---

## 一、先说清楚定位（这是关键）

| 东西 | 跑在哪 | 干什么 |
|---|---|---|
| **小徐TuT.app（本工程）** | iPhone | 对话、人设注入、897 条技能、73 项工具、47 篇文档、设置面板、**内置 Alpine Linux 终端** |
| **npclab 服务（PC）** | 电脑 | radare2 伪代码、MITM 抓包、GitHub 写仓库（重活仍建议连 PC） |

**为什么能在手机上跑 Linux**：`deps/ish/` 是 iSH 的内核源码，交叉编译成 `Vendor/libishkernel.a` 后链进 App，再配上从 Minis 包里抽出来的 Alpine rootfs（139MB），本机就有完整的 POSIX 环境——不连任何服务器。

iOS 不允许 App `fork` 任意可执行文件，所以走的是 iSH 那条路：把 x86 模拟器 + 系统调用翻译层编进同一个进程，Linux 内核以为自己在一块裸机上，实际每个 syscall 都被翻成 Darwin 调用。Minis 干的也是这件事（它的包里躺着 `alpine-rootfs.zip`、`ISHKernel`、`libiosexec`）。

- **本地跑**：人设、技能、文档、注入拼装、shell、apk、python —— 断网可用；
- **连 PC**：r2 反编译、流量抓包 —— 手机上跑得动但慢，重活还是扔给节点。

---

## 二、三种出 ipa 的路子

### 1. GitHub Actions（Windows 上唯一省事的路）

本地已经是 git 仓库，首次提交也做完了。只剩挂远端：

```bash
cd npclab-ios
git remote add origin git@github.com:<你>/<仓库名>.git
git push -u origin main
```

push 完去 Actions 页面等：
- **首次** 25–45 分钟（含 iSH 内核交叉编译），
- **之后**（命中 `deps/ish/build-ios` 缓存）6–12 分钟。

跑完在 run 页面底部下载 artifact `小徐TuT-ipa`，解压得到 `小徐TuT.ipa`。

两个坑先说：

| 坑 | 说明 |
|---|---|
| 仓库别设成 private 省钱 | macOS runner 按 10 倍计费，private 仓库 2000 分钟免费额度 = 200 分钟 macOS；public 仓库免费不限量 |
| 单文件 100MB | rootfs 已切成 14 段提交，别再把整包 `alpine-rootfs.zip` 提交进去 |

装法：
- **TrollStore**（越狱 / 有内核漏洞的机器）：直接点 ipa 安装，免签。
- **AltStore / Sideloadly**：用你自己的 Apple ID 重签，7 天有效期。
- **企业证书**：`codesign -f -s "证书" --entitlements ...` 后打包。

### 2. 有 Mac

**一条命令**（推荐）：

```bash
bash Tools/build_ipa.sh --with-kernel   # 首次：编内核 + 出包，20-40 分钟
bash Tools/build_ipa.sh                 # 之后：只出包，2-3 分钟
```

产物在 `dist/小徐TuT.ipa`。脚本会在打包前后做自检，任何一项不过都会明确报出来而不是静默出个坏包：

| 自检 | 查什么 | 不过会怎样 |
|---|---|---|
| 显示名 | `CFBundleDisplayName` 是否等于 `IPA_NAME` | 桌面上还是旧名字 |
| 扩展嵌入 | `PlugIns/` 下三个 `.appex` 是否都在 | 分享 / 文件 App / 小组件全哑 |
| rootfs | `alpine-rootfs.zip` 是否进了 bundle | 终端首启解压失败 |
| 内核符号 | `_npc_linux_boot` / `_run_kernel` / `_actuate_kernel` 是否在可执行文件里 | `-force_load` 没生效，启动崩 |
| 权限文案 | 21 项 `NS*UsageDescription` 是否都填了 | 触发权限时闪退 |
| 本地化 | 18 个 `.lproj` 是否都在 | 界面回落中文 |

没有 `Vendor/libishkernel.a` 也能出包，只是自动走 stub 模式，终端页显示「未编译内核」。

**用 Xcode 跑**：

```bash
open NpcLab.xcodeproj
# 选自己的 Team，Bundle ID 改成自己的，Run
```

**手动出 unsigned**（不想用脚本时）：

```bash
xcodebuild -project NpcLab.xcodeproj -scheme NpcLab -configuration Release \
  -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/NpcLab.app Payload/
zip -qry 小徐TuT.ipa Payload
```

### 3. 改完源码后重生成工程

```bash
python Tools/gen_data.py        # 重新从 npclab/data + npc_src/skills 打包资源
python Tools/gen_xcodeproj.py   # 重新扫目录生成 pbxproj
```

新增 `.swift` 文件不用手动改工程——重跑一次 `gen_xcodeproj.py` 就进 Sources 了。

---

## 三、装上之后怎么用

1. **设置 → 模型**：接口地址（`https://api.openai.com/v1` 或自建中转）、API Key、模型名。Anthropic 协议在服务商那一栏切。
2. **对话页左上角**的数字是当前 SYSTEM 的体积，点开能看五层原文，能按层拆。
3. **思维 → 人设**：直接改 SOUL.md，改完立刻生效。超 800 汉字 / 500 英文词只留身份句（对齐 Minis 的 SoulStore 行为）。
4. **技能**：897 条，按方向分 9 类；长按置顶，置顶的进 `<available_skills>` 前排，也用于「全文注入」。
5. **终端页**：第一次进去解压 rootfs（10–20 秒，等进度条走完），然后就是本机 Alpine。`uname -a`、`apk info`、`python3` 都能跑。全屏程序（vi/top）会花屏，这是没有完整 VT100 的代价。
6. **设置 → 算力节点**：填 PC 的 `http://192.168.x.x:8790`，点探活。逆向 / 抓包要它；终端不依赖它。
7. **抓包**：节点启动代理后，手机浏览器打开 `http://<PC-IP>:<端口>/api/proxy/ca.crt` 装描述文件 → 设置里打开「证书信任设置」→ WiFi 代理指向 PC。

---

## 四、注入的五层（和 PC 版逐条对齐）

| 层 | 内容 | 关闭方式 |
|---|---|---|
| L1 人设 | `persona.md` 的 YAML 头 + 正文 + style | 人设清空 |
| L2 技能 | `<available_skills>`，最多 20 条元数据，描述截 200 字 | 技能模式 = 关闭 |
| L3 工具链 | 73 项工具，分随包 / 按需取回 / 外部自备 | 工具模式 = 关闭 |
| L4 运行时 | 设备型号、iOS 版本、节点在线状态、授权情况 | 恒开（保真） |
| L5 思维 | 12 条 ops-notes 模板取其一，包在 `<!-- ops-notes -->` 里 | 思维模板关 |
| 尾注 | 指令优先级声明 | 尾注关 |

拼装顺序三选一：`人设 → 技能 → 工具 → 运行时 → 模板`（默认）/ 模板前置 / 只留模板。

实测体积：人设约 0.8KB + 技能约 9KB + 工具约 0.9KB + 运行时约 1KB + 模板约 0.5KB ≈ **11–12KB，约 6.5–7k token**。

---

## 五、内置 Linux（iSH 内核）

终端页跑的是真 Linux，不是远程 shell。

### 它从哪来

| 部件 | 来源 | 体积 |
|---|---|---|
| 内核 + x86 模拟器 | `deps/ish`（iSH 上游源码） | 编出 60–90MB 静态库 |
| Alpine 根文件系统 | 从 `Alpine-rootfs.zip` 提取（iSH 的 fakefs 格式：`meta.db` + `data/`） | 139MB（解开 406MB） |
| 胶水层 | `NpcLab/Core/NpcLinux.c`（手写） | 400 行 |

iSH 上游编译完是个"半成品"——它不知道 rootfs 在哪、输出给谁，还缺 4 个 `Terminal_*` 符号（原本由 iSH 自己的 UIKit 终端实现）。`NpcLinux.c` 就是补这一层的：一个 8 槽的静态终端表顶掉 UIKit，输出走回调，输入走 pty 主端。

### 怎么编

**只能在 macOS 上编**（要 iPhoneOS SDK）：

```bash
brew install meson ninja
bash Tools/build_ish.sh          # 首次 20–40 分钟
python3 Tools/gen_xcodeproj.py   # 重新生成工程，自动切到真实现
```

`build_ish.sh` 干四件事：
1. `deps/clone-linux.sh` 拉 Linux 头文件（sparse checkout）
2. 给 `app/LinuxPTY.c` 打补丁，加一个 `npc_pty_write()`（从 App 侧写 pty，幂等）
3. `meson` 交叉编译 `liblinux.a` + `libfakefs.a` + `libish_emu.a`
4. 用 `app/StaticLibLinux.xcconfig` 的参数手工编 6 个 App 层文件，最后 `libtool` 合成 `Vendor/libishkernel.a`

**没有这个 `.a` 会怎样**：`gen_xcodeproj.py` 检测不到就自动切到 `LinuxRuntimeStub.swift`，工程照样能编译能跑界面，终端页只显示"未编译内核"的提示。不会满屏链接错误。

### 链接时的一个坑

`OTHER_LDFLAGS` 里必须 `-force_load libishkernel.a`。内核里的 `rootfs_initcall`、`device_initcall` 这些初始化段没有任何代码显式引用它们，普通链接会把整段裁掉，结果就是启动到一半空指针崩。

### 首启与磁盘

第一次进终端页要解压 rootfs，10–20 秒，占 406MB（App 沙箱 `Application Support/NpcLab/rootfs`）。之后每次秒开。设置页可以重建。

### 能力边界（说清楚，别指望）

- ✅ `sh` / `busybox` / `apk` / `python3` / `grep` / `awk` / 编译小工具
- ❌ `vi` / `top` / `less` —— 这里没有完整 VT100 光标定位，全屏程序会花屏
- ❌ 访问系统目录、提权、碰别的 App —— iOS 沙箱照旧
- ❌ 真网卡 —— 走 App 的网络权限

要全屏终端，得把 xterm.js 塞进 WKWebView（iSH 自己就是这么做的），那是另一件事。

### 许可证

iSH 是 **GPLv3**。把 `libishkernel.a` 链进 App 分发，整个 App 就得按 GPLv3 开源。自己装着玩无所谓，要上架或闭源分发，这个约束跑不掉。

---

## 六、目录

```
NpcLab/
  App/NpcLabApp.swift        @main + TabView + 首次引导
  Core/Theme.swift           深色玻璃配色
  Core/Models.swift          Skill / Tool / Preset / Doc / ChatMessage / Rule
  Core/Store.swift           资源加载 + 配置持久化（UserDefaults）
  Core/Soul.swift            SOUL.md 解析、注入清洗、字数上限
  Core/PromptBuilder.swift   五层拼装
  Core/ChatEngine.swift      SSE 流式（OpenAI / Anthropic）
  Core/Bridge.swift          节点桥：探活 / 终端 / 逆向 / 抓包
  Core/LinuxTypes.swift      终端行 / 运行状态（真假两版共用）
  Core/LinuxRuntime.swift    内核实封装：解压 / 启动 / exec / pty（有内核时编这个）
  Core/LinuxRuntimeStub.swift 没内核时的占位实现（二选一）
  Core/NpcLinux.c            iSH 胶水层：补 Terminal_* 符号 + boot/exec
  Core/NpcUnzip.c            最小 zip 解压（保住符号链接，Alpine 全靠它）
  Views/TerminalView.swift   终端页
  Views/ChatView.swift       对话 + 注入预览
  Views/ThoughtView.swift    人设 / 模板 / 拼装顺序 / 前缀尾注
  Views/LibraryView.swift    技能 / 工具 / 文档
  Views/SettingsView.swift   设置主页（模型 / 节点 / 权限 / 开发者 / 逆向 / 日志）
  Views/Panels.swift         权限 / 宿主 / 终端 / GitHub / 上下文 / 日志
  Views/PanelsRev.swift      逆向分析 / 抓包与改写
  Views/Components.swift     卡片、代码块、Markdown、弹窗
  Resources/                 skills.json 等内置数据 + Assets + icon + alpine-rootfs.zip
deps/ish/                    iSH 内核源码（GPLv3，编译用，不进 ipa）
Vendor/libishkernel.a        编译产物，60–90MB（.gitignore 掉了，自己编）
```

资源 10MB（技能 / 工具 / 文档）+ rootfs 139MB。没编内核时 ipa 约 12MB，编了之后约 155MB。

---

## 七、已知边界

- **终端**：本地 Alpine 全能跑，但只支持行式输出——`vi` / `top` / `less` 这类要光标定位的全屏程序会花屏。要完整仿真得把 xterm.js 塞进 WKWebView。
- **逆向 / 抓包**仍依赖节点；节点不在，L4 会明确写「没有 shell」，模型不会假装能执行。
- 内核是 iSH（GPLv3），链进 App 分发就等于整个 App 走 GPLv3。
- Face ID 开关已接 UI，但工程里没写 LocalAuthentication 调用——开关只存状态。要真锁，在 `RootView` 启动时加 `LAContext.evaluatePolicy`，工程已带 `NSFaceIDUsageDescription`。
- 大文件（>50MB Mach-O）在节点侧走 `rabin2 -s` 符号表，函数列表是符号不是反编译结果，属正常降级。

---

## 八、跟 AzTuT_1.14.ipa 的对齐状态

拿到的原始包是 `AzTuT_1.14_20261019_035050.ipa`（Minis 换壳，TrollStore 渠道，无 `_CodeSignature`）。
下面按「同一个东西 / 差在哪」分开列，别混着看。

### 设计上一样（代码已就位，等内核编出来才对得上）

| 项 | 说明 |
|---|---|
| 技术路线 | 原生 SwiftUI（不是网页套壳），链接 SwiftUI / UIKit / WebKit |
| Linux 运行方式 | iSH 内核编进 App：`kernel=linux` + `-Dengine=asbestos`（x86 模拟）+ fakefs rootfs |
| 启动序列 | `actuate_kernel()` → `rootfs_initcall ish_rootfs()` → `DefaultRootPath()` → `do_mount(fakefs, "/root")` → `init_chroot` |
| rootfs | 就是它包里那个 `alpine-rootfs.zip`，139MB，`meta.db` + `data/` |
| 内核入口符号 | `actuate_kernel` / `LinuxInterop` / `ios_pty_open` / `Terminal_*` 四个桥接符号 |
| 链接方式 | `-force_load libishkernel.a`（`rootfs_initcall` 段没人引用，不强制加载会被裁） |
| 设置页四组 | 权限 / 开发者 / 逆向工具 / 日志 |
| 人设注入 | SOUL.md 解析 + 超限截断 + 注入行清洗 |

### 已经补齐的（上一版 README 写「无」，实际已有）

| 项 | AzTuT | 本工程 |
|---|---|---|
| 分享扩展 | `MinisShare.appex` | ✅ `NpcLabShare.appex`（target + Embed 阶段都在） |
| 文件扩展 | `MinisFileProvider.appex` | ✅ `NpcLabFileProvider.appex` |
| 小组件 | `AgentWidgetExtension.appex` | ✅ `NpcLabWidget.appex` |
| 扩展嵌入方式 | `dstSubfolderSpec=13` | ✅ 同 |
| 系统权限 | 20+ | ✅ 20 条 usage string 全填（Info.plist 共 52 键） |
| 后台模式 | audio / fetch / location / remote-notification | ✅ 四项一致 |
| URL scheme | `minis://` | ✅ `npclab://` + `npclab-mcp://` |
| Live Activity 开关 | 开 | ✅ `NSSupportsLiveActivities` 两个键都开 |
| 文件 App 接入 | 有 | ✅ `UIFileSharingEnabled` + 文档类型 + UTI |
| OSC 1337 全链路 | `minis-open` | ✅ `npclab-open`（脚本 → default_mount → RootfsOverlay → OSC.swift → OpenSheet） |
| 人设注入 | SOUL.md + 截断 | ✅ 加注入行清洗 |
| 设置页四组 | 权限 / 开发者 / 逆向 / 日志 | ✅ 同 |

### 第二轮补齐（这一版新加的）

上一版这几项还写着「不做」，现在都做了。

| 项 | 落点 | 说明 |
|---|---|---|
| **Live Activity 实体** | `Core/NpcActivityAttributes.swift`（两 target 共享）+ `Core/LiveActivity.swift` + `Extensions/NpcLabWidget/NpcLiveActivity.swift` | 锁屏卡片 + 灵动岛四态全做。内核解压时显示百分比、启动时显示阶段、跑长命令时显示行数走秒。16.1 以下整套静默降级 |
| **18 种语言** | `Tools/l10n_pack.py` + `Tools/gen_l10n.py` | zh-Hans / zh-Hant / en 全量，ja ko de fr es ru pt-BR it 短串全译，nl tr ar th vi id hi 核心 25 条。`CFBundleLocalizations` 自动同步 |
| **`default_mount` 19 项** | `Tools/default_mount/` | 补到 19 项，跟 Minis 数目一致。新加：`apk` 镜像源、自己写的 motd（**原包里那行 `Welcome to MinisApp Linux Shell` 是被我们覆盖掉的**）、`npclab-pkg` / `npclab-net` / `npclab-sysinfo` / `npclab-help` / `npclab-edit`、`/etc/npclab/version` |
| **Face ID 真门禁** | `Core/AppLock.swift` | 用 `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`，冷启动和退后台超 60 秒回来都要验。设备没设密码时自动放行，不把人关在外面 |
| **技能触发词自动匹配** | `Core/SkillMatcher.swift` | 按用户这句话从 897 条里挑 20 条，不再固定按「方向+体量」。中文 bigram + 英文词边界，trigger 整句命中 +200、分词重叠 +40/个。没输入时退回老排序 |
| **对话内工具调用** | `Core/ToolAgent.swift` | 8 个工具：`read_skill` / `search_skills` / `read_doc`（纯本地）+ `node_exec` / `rev_targets` / `rev_funcs` / `rev_pseudo` / `proxy_add_rule`（走节点）。OpenAI 与 Anthropic 两套协议都实现，最多往返 6 轮。设置 → 开发者 → 对话内工具 开关 |
| **抓包过滤器完整语法** | `Views/PanelsRev.swift` 的 `RuleEditor` | 四处补全：正则实时校验（`NSRegularExpression` 真编译）、4 个模板（抓接口 / 改 VIP 字段 / 换 UA / 加鉴权头）、7 条写法要点、非法正则时禁用保存 |
| **相册 / 相机进对话** | `Core/Attachment.swift` + `Views/ImagePicker.swift` | 长边压到 1600、JPEG 0.82，存 `Documents/attachments/`，消息里只记文件名。发送时两套协议分别拼 `image_url` / `image` block。单条最多 4 张 |
| **语音输入** | `Core/VoiceInput.swift` | `SFSpeechRecognizer` + `AVAudioEngine`，按住说话边识别边上屏，支持离线识别（`requiresOnDeviceRecognition`）。中文识别器 |

### 真差在哪（只剩三条硬的）

| 项 | AzTuT | 本工程 | 卡点 |
|---|---|---|---|
| **内核静态库 `libishkernel.a`** | 编好的 | **没编**（`Vendor/` 不存在） | 只能在 macOS 上 `bash Tools/build_ish.sh`，首次 20-40 分钟。Windows 上无解 |
| **出过 ipa** | 是，能装 | 没出过 | 同上；脚本与 CI 都已就绪，缺的是「在 Mac 上跑一次」 |
| `libiosexec.1.dylib` | 有 | 无 | 独立仓库（ish-app/libiosexec），要单独编。缺它的话 `chroot` 后部分命令的 `exec` 走不通，靠 `NpcLinux.c` 里直调 `run_kernel` 绕过去了 |

### 还是没做的（就这三项）

| 项 | AzTuT | 为什么不做 |
|---|---|---|
| FFmpeg 八件套 | 有，视频处理 | 跟「终端 + 对话 + 逆向」不搭。要加也是下 xcframework 挂进链接，不是代码问题，是 200MB 的包体问题 |
| `RootfsPatch.bundle` | — | Minis 用来热修 rootfs 的（它自己带 JS 运行时需要 polyfill）。我们直接重打 rootfs，不需要 |
| 全屏 xterm.js 终端 | — | 现有 `TerminalView` 已经能滚、能敲、能收 OSC。换 xterm.js 要往 bundle 里塞 300KB JS + 做 PTY 双向桥，收益不抵复杂度 |

### Minis 那个 `minis-open` 是什么

它不是「打开浏览器」那么简单。核心是**借 iTerm2 的 OSC 1337 转义序列**给宿主播信号：

```
ESC ] 1337 ; MinisOpenURL = <url> BEL
```

Linux 里任何命令打这段字节到 stdout，宿主的终端解析器把它**从显示内容里剥掉**，然后按 URL 类型路由到原生界面（http → WKWebView、图片 → 图片查看器、pdf/office → QuickLook、其它 → 分享面板）。`xdg-open` / `sensible-browser` / `$BROWSER` 全是它的软链。

这套东西的价值：**Linux 里的程序能驱动 iPhone 的原生 UI**，而不是只能打印文本。本工程还没做，要做分三块：

1. `Resources/default_mount/usr/local/bin/npclab-open`（shell 脚本，照抄改前缀）
2. Boot 后把 `default_mount/` 里的文件覆盖进 rootfs（写文件，不用 bind mount）
3. `LinuxRuntime` 的输出回调里解析 OSC 1337，剥掉序列，`DispatchQueue.main` 上调 SwiftUI

### 说白了

> 上面这张表是核查当时的状态。**本轮已按 AzTuT 补齐，见第九章。**

**技术骨架一模一样，成品程度不一样。** 差的是一次 macOS 上的编译，加上几个扩展 target。前者是硬卡点（Windows 上做不了），后者是体力活（能做，但要新 target，pbxproj 手写风险高，建议在 Xcode 里点）。

### 顺带挖出来的几个事实

从 AzTuT 包的 Info.plist 和二进制里对出来的：

- `NSLocalNetworkUsageDescription` 原文是 "VM requires network access for SLIRP networking" —— 但 iSH 这份源码里 `fs/sock.c` 是**直接调 Darwin socket**（`connect(sock->real_fd, ...)`），不走 SLIRP。所以它的网络能用，但那是宿主网络直通，不是 NAT 层。
- `MinimumOSVersion = 10.0` 但用了 `AlarmKit` / `Live Activities`（iOS 16+/26），说明 `MinimumOSVersion` 是抄来的没改。
- `DTSDKName = iphoneos26.5`、`DTXcode = 2660` —— 用 Xcode 26 编的。


---

## 九、照 AzTuT 补齐（本轮）

用户要求「除了工具包内容不一样，其他按它的来」。逐项落地如下。

### 1. 三个扩展（对应 Minis 的 PlugIns）

| 目录 | 类型 | 干什么 |
|---|---|---|
| `Extensions/NpcLabShare` | Share Extension | 任何 App 里分享文件/图片/链接 → 落进 App Group 的 `Inbox/` |
| `Extensions/NpcLabFileProvider` | File Provider | 系统「文件」App 里出现「NpcLab 工作区」，浏览 Inbox + Workspace（只读） |
| `Extensions/NpcLabWidget` | WidgetKit | 桌面小组件：内核状态、节点在线、最近一条命令与输出 |

`gen_xcodeproj.py` 已支持多 target：生成 4 个 `PBXNativeTarget`、`Embed Foundation Extensions`（`dstSubfolderSpec = 13`）、3 个 `PBXTargetDependency` + `PBXContainerItemProxy`。实测 147 个对象、0 悬空引用。

App Group 用 `group.com.npclab.client`，四份 `.entitlements` 都写好了。**没有签名 profile 时这些会被忽略**，代码里全部做了降级：Inbox 退临时目录、文件 App 位置不出现、Widget 显示"未启动"。不会崩，也不会假装能用。

### 2. OSC 1337 通道（Minis 最巧的那一手）

| 部件 | 文件 |
|---|---|
| Linux 侧脚本 | `Tools/default_mount/usr/local/bin/npclab-open`（兼 `xdg-open` / `sensible-browser` / `$BROWSER`） |
| 打包装进 bundle | `Tools/gen_mount.py` → `Resources/default_mount.json`（base64，10 个文件） |
| 开机写进 rootfs | `NpcLab/Core/RootfsOverlay.swift` |
| 字节流解析 | `NpcLab/Core/OSC.swift`（跨 chunk 状态机） |
| 原生落地 | `NpcLab/Views/OpenSheet.swift`（WKWebView / QuickLook / 图片 / 分享） |

协议就是 iTerm2 那套：

```
ESC ] 1337 ; NpcLabOpenURL = <url> BEL
```

终端里 `npclab-open https://example.com` 会把这段打给宿主，宿主剥掉后弹原生 WKWebView，屏幕上不会出现乱码。

**为什么不能直接拷进 rootfs**：fakefs 的 `readdir` 拿文件名去 `meta.db` 查 inode（`linux/fakefs.c:415`），查不到就 `continue`。外部拷进去的文件在内核眼里等于不存在。所以只能让内核自己写——把内容 base64 编好，拼一条 shell 命令交给 `/bin/sh`，走 VFS 写入，`meta.db` 自然被更新。

### 3. Info.plist 对齐

52 个键：21 条权限描述（相机/麦克风/语音/相册/FaceID/局域网/定位×2/蓝牙×2/日历×2/提醒×2/健康×2/HomeKit/AppleMusic/NFC/AlarmKit）、`UIBackgroundModes` 全套四项、`npclab://` 与 `npclab-mcp://` 两个 URL scheme、`.npclab` 备份 UTI、`NSSupportsLiveActivities`、`UIApplicationSceneManifest`、文件 App 接入、`LSSupportsOpeningDocumentsInPlace`。

权限描述按 NpcLab 自己的场景重写，没照抄 kyTuT 的文案。

### 4. 本地化

`Tools/gen_l10n.py` 从 Swift 源码里抽中文界面串（92 条），生成：

| 语言 | 覆盖 |
|---|---|
| `zh-Hans.lproj` | 原文就是键，不写映射 |
| `zh-Hant.lproj` | 73 条（逐字简繁映射，19 条繁简同形省掉） |
| `en.lproj` | 92 条，全部人工译 |

机制吃的是 SwiftUI 的便利：`Text("中文")` 本身就是 `LocalizedStringKey`，查表命中就换语言，**代码一行没改**。再加语言只要扩 `gen_l10n.py` 的翻译表。

### 5. bashism 检测

终端里贴 bash 脚本进来是最常见的翻车点，而且在 busybox ash 下有一类**不报错但算错**的（`${var^^}` 会变空串、`[[ ]]` 条件判断结果相反）。

`Resources/bashism_rules.json` 27 条规则，分三级：

- **S**（静默算错，最危险）：`[[ ]]`、`${var^^}`、`${var,,}`、`let`、extglob
- **E**（直接报错）：`(( ))`、数组、`<<<`、`&>`、`$'...'`、进程替换、`mapfile`、`coproc`
- **T1**（语义微妙）：`function` 关键字、`echo -e`、`source`、`{1..10}`、`pushd`

命中只提示不拦截——用户可能真装了 bash。提示里带行号和改法。

### 6. 还差的

| 项 | 状态 |
|---|---|
| `libishkernel.a` | **仍未编**。要 macOS + Xcode，Windows 上做不了。这是唯一的硬卡点 |
| FFmpeg 八件套 | 没做。它是给视频处理用的（`RealTimeCutVADCXXLibrary`），跟本工程场景无关 |
| Live Activity | Info.plist 开了 `NSSupportsLiveActivities`，但没写 ActivityKit 的 widget |
| 18 种语言 | 做了 3 种（zh-Hans / zh-Hant / en），机制通了，剩下的纯翻译活 |
| `RootfsPatch.bundle` | 没做。Minis 往 rootfs `/lib` 塞了 `wasm-polyfill.js` / `fetch-polyfill.js`，是给它自己的 JS 运行时用的 |
| `libiosexec.1.dylib` | 没做。这是独立仓库 `ish-app/libiosexec`，不在 iSH 主仓库里，要单独拉来编 |

### 7. 工程现状

```
4 个 target          主 App + Share + FileProvider + Widget
37 个 Swift 文件     括号 / 字符串 / #if / 代码区全角符号 全过
32 个主 target 源文件 无内核时 32（含 LinuxRuntimeStub），有内核时换成 LinuxRuntime + 2 个 .c
31 个资源            skills / tools / docs / presets / skillbody / pack / stats
                     + persona.md / tail.md / alpine-rootfs.zip(139MB)
                     + default_mount.json / bashism_rules.json
                     + Assets.xcassets(含 1024 图标) / 18 个 .lproj
196 个 pbxproj 对象   零悬空引用
```

生成流程：

```bash
python Tools/gen_data.py       # skills/tools/docs/presets JSON
python Tools/gen_mount.py      # default_mount.json
python Tools/gen_l10n.py       # 18 个 .lproj
python Tools/make_icon.py      # 从 Tools/artwork/icon-source.jpg 出 1024 图标
python Tools/split_rootfs.py   # rootfs 切段 + 重写 manifest（换 rootfs 时才需要）
python Tools/gen_xcodeproj.py  # 4 target 工程（自动判断内核在不在）

bash Tools/join_rootfs.sh      # 分段拼回 alpine-rootfs.zip（build_ipa.sh 会自动调）
```

---

## 十、改名字 / 换图标

名字有**三个落点**，改一处不够：

| 落点 | 文件 | 改什么 |
|---|---|---|
| 桌面图标下的名字 | `NpcLab/Info.plist` | `CFBundleDisplayName`（`CFBundleName` 一起） |
| ipa 文件名 | `Tools/build_ipa.sh` | `IPA_NAME="小徐TuT"`；CI 走同一脚本，无需另改 |
| 扩展在系统里的名字 | `Extensions/*/Info.plist` | 三个 `CFBundleDisplayName` |

`.app` 与可执行文件仍叫 `NpcLab`（`PRODUCT_NAME` 保持 ASCII，避免脚本和无签名工具踩非 ASCII 可执行名的坑），这不影响桌面显示。

换图标：

```bash
# 1. 把新图覆盖到 Tools/artwork/icon-source.jpg（正方形最好，非正方形会居中裁）
# 2. 出图
python3 Tools/make_icon.py                  # 需要 pip install pillow
# 3. 重生成工程（Assets 是目录引用，一般不用，保险起见跑一次）
python3 Tools/gen_xcodeproj.py
```

图标要求：1024×1024、无 alpha、不预切圆角（系统自己遮罩）。`make_icon.py` 已经处理这三条。
