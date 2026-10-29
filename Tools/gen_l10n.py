#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 Swift 源码里抽中文界面串，生成 Localizable.strings。

机制：SwiftUI 的 Text("中文字面量") 会自动当 LocalizedStringKey 查表，
所以只要在 en.lproj/Localizable.strings 里写 `"中文" = "English";`，
不用改一行代码就能切换语言。

目前做 zh-Hans（原文）/ zh-Hant（简繁映射）/ en（人工译）三套。
再加语言只需要在 LANGS 里添一行 + 补翻译。
"""

import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "NpcLab", "Resources")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from l10n_pack import TABLES, ALL_LANGS, COVERAGE   # noqa: E402

# ---------------------------------------------------------------- 提取

PAT = re.compile(
    r'(?:Text|Label|navigationTitle|Button|Pill\(text:|EmptyHint\(title:'
    r'|SectionTitle\(title:|placeholder:)\s*\(?\s*"([^"\\]{2,})"'
)


# 品牌名不翻译：各语言都显示同一个字，干脆不进 .strings（SwiftUI 找不到 key 时用字面量）
BRAND = {"小徐TuT", "小徐TuT iOS", "NpcLab"}


def extract():
    found = set()
    for f in glob.glob(os.path.join(ROOT, "NpcLab", "**", "*.swift"), recursive=True):
        s = io.open(f, encoding="utf-8").read()
        for m in PAT.finditer(s):
            t = m.group(1)
            if t in BRAND:
                continue
            if any("\u4e00" <= c <= "\u9fff" for c in t):
                found.add(t)
    return sorted(found)


# ---------------------------------------------------------------- 英文

EN = {
 "从模板起手": "Start from a template",
 "写法要点": "Syntax notes",
 "名字（只给列表显示用）": "Name (shown in the list only)",
 "图没了（可能被清理过）": "Image is gone (may have been cleaned up)",
 "整条 URL 匹配，不带 /.../ 分隔符。留空 = 命中所有请求，慎用。":
   "Matches the whole URL. No /.../ delimiters. Empty = every request, use with care.",
 "替换串可以用 $1 / ${1} 引用分组。":
   "The replacement can reference groups with $1 / ${1}.",
 "知道了": "Got it",
 "空行和 # 开头的行会被忽略。": "Blank lines and lines starting with # are ignored.",
 "语音输入用不了": "Voice input unavailable",
 "小徐TuT 已锁定": "小徐TuT is locked",
 "解锁": "Unlock",
 "正在验证身份…": "Verifying…",
 "用 Face ID 或设备密码继续": "Continue with Face ID or your passcode",
 "Face ID 需要工程里配 NSFaceIDUsageDescription；不填也不会崩，只是拿不到结果。":
   "Face ID needs NSFaceIDUsageDescription in the project. Without it nothing crashes, you just get no result.",
 "SYSTEM 合计": "SYSTEM total",
 "iOS 沙箱不允许 App fork 进程、也不允许执行 App 外的可执行文件。Minis 之所以能在手机上跑 shell，是把 iSH 内核和 Alpine rootfs 一起编译进了 App。本工程不带内核，所以终端 / radare2 / MITM 走局域网节点，其余全部本地。":
   "The iOS sandbox forbids forking processes or running executables outside the app. Minis can run a shell on the phone because it compiles the iSH kernel and an Alpine rootfs into the app. This build ships without a kernel, so terminal / radare2 / MITM go through a LAN node; everything else is local.",
 "id / 描述 / 触发词": "id / description / triggers",
 "上限": "Limit",
 "不能干什么": "What it can't do",
 "为什么执行能力要接节点": "Why execution needs a node",
 "伪代码引擎按 pdg → pdd → pdc → pdf 自动降级，节点返回哪个就用哪个。":
   "The decompiler falls back pdg → pdd → pdc → pdf; whichever the node returns is what you get.",
 "保存": "Save",
 "保存到节点": "Save to node",
 "全文": "Full text",
 "全文模式需要至少置顶一条技能（技能库 → 长按 → 置顶）。":
   "Full-text mode needs at least one pinned skill (Skills → long press → Pin).",
 "全量": "Full",
 "关于终端": "About the terminal",
 "关闭": "Close",
 "列出": "List",
 "刷新": "Refresh",
 "前缀": "Prefix",
 "匹配（正则）": "Match (regex)",
 "取消": "Cancel",
 "只响应": "Response only",
 "只请求": "Request only",
 "启用": "Enable",
 "复制": "Copy",
 "复制 ID": "Copy ID",
 "复制全文": "Copy all",
 "安装 / 取回": "Install / fetch",
 "完成": "Done",
 "对话": "Chat",
 "尾注": "Tail note",
 "工具": "Tools",
 "工具名 / 用途": "Tool name / purpose",
 "已超上限 —— 注入时只会保留身份句，人设不生效。":
   "Over the limit — only the identity sentence is kept when injecting; the persona is dropped.",
 "常见值：GPT-4o 128k / Claude 200k / 本地小模型 8k–32k。":
   "Typical values: GPT-4o 128k / Claude 200k / small local models 8k–32k.",
 "开始": "Start",
 "思维": "Reasoning",
 "思维模板": "Reasoning presets",
 "思考中…": "Thinking…",
 "恢复内置": "Restore defaults",
 "执行身份": "Execution identity",
 "技能": "Skills",
 "技能库 / 工具链": "Skills / toolchain",
 "拼好的全文": "Assembled prompt",
 "按层拆开": "Split by layer",
 "按类型或内容过滤": "Filter by type or content",
 "探活": "Ping",
 "探活节点": "Ping node",
 "改写规则": "Rewrite rules",
 "改头（每行 Key: Value）": "Set headers (Key: Value per line)",
 "文档": "Docs",
 "文档名 / 路径": "Doc name / path",
 "新增规则": "New rule",
 "普通": "Standard",
 "服务商": "Provider",
 "未授权执行：设置 → 权限 → 命令执行":
   "Execution not authorized: Settings → Permissions → Command execution",
 "未授权：设置 → 权限 → 抓包代理":
   "Not authorized: Settings → Permissions → Intercept proxy",
 "正文替换": "Body replacement",
 "没有规则。规则用正则匹配 URL，命中才改写，其余流量原样放过。":
   "No rules. Rules match the URL with a regex; only hits get rewritten, everything else passes through.",
 "注入预览": "Prompt preview",
 "流式": "Streaming",
 "清屏": "Clear screen",
 "清空会话": "Clear chat",
 "清空会话记录": "Clear chat history",
 "清空日志": "Clear logs",
 "温度": "Temperature",
 "独立客户端：注入、人设、技能库、文档全部本地；执行能力接节点。":
   "Standalone client: prompt assembly, persona, skills and docs are all local; execution goes to a node.",
 "留空 = 命中所有请求，慎用。": "Empty = matches every request. Use with care.",
 "目标管理、伪代码、抓包都在节点上执行；此页只做控制面。":
   "Binary targets, decompilation and interception all run on the node; this page is control-plane only.",
 "确定": "OK",
 "第一次启动": "First launch",
 "管理员": "Admin",
 "索引 20 条": "Index, 20 entries",
 "索引只发 name / description / path，正文按需读；全文把置顶技能的 SKILL.md 整段塞进 system。":
   "Index mode sends only name / description / path and reads bodies on demand; full-text mode stuffs the whole SKILL.md of pinned skills into the system prompt.",
 "终端": "Terminal",
 "编辑": "Edit",
 "编辑尾注": "Edit tail note",
 "能干什么": "What it can do",
 "节点侧用 Contents API，能读树、读文件、写提交；写操作要 repo 权限的 token。":
   "The node uses the Contents API: read trees, read files, write commits. Writes need a token with repo scope.",
 "节点启动代理后生成自签 CA。手机浏览器打开下面地址装描述文件，再到「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任。":
   "Starting the proxy on the node generates a self-signed CA. Open the address below in mobile Safari to install the profile, then enable full trust under Settings → General → About → Certificate Trust Settings.",
 "节点在算；首次分析大文件要几十秒": "Node is working; the first pass on a large binary takes a while",
 "节点就是 PC 上那个 npclab 服务（server.py）。手机与 PC 同一局域网，填 PC 的 IP:8790。":
   "The node is the npclab service on your PC (server.py). Keep phone and PC on the same LAN and enter the PC's IP:8790.",
 "解压 139MB 的 rootfs，大概 10–20 秒，之后每次秒开。":
   "Unpacking the 139MB rootfs takes about 10–20s; after that it opens instantly.",
 "触发词：": "Triggers: ",
 "设置": "Settings",
 "说明": "Help",
 "请求+响应": "Request + response",
 "读取状态": "Read status",
 "还没有目标。填节点上的一个二进制路径（.app 主程序、.so、.exe 都行）。":
   "No targets yet. Enter a binary path on the node (.app executable, .so, .exe all work).",
 "这是什么": "What is this",
 "逆向只能在节点上跑：iOS 沙箱不能 fork 进程，也不允许执行 App 之外的可执行文件。":
   "Reversing only runs on the node: the iOS sandbox can't fork processes or execute binaries outside the app.",
 "长按置顶 / 取消": "Long press to pin / unpin",
 "随包": "Bundled",
}

# ---------------------------------------------------------------- 简体→繁体

# 只收界面里真会出现的字，没覆盖的保持原样。
# 用逐字映射而不是 opencc：这里只有 90 多句话，够用且不用装依赖。
S2T_MAP = {
    "声": "聲", "为": "為", "体": "體", "个": "個", "会": "會", "话": "話",
    "务": "務", "执": "執", "关": "關", "闭": "閉", "确": "確", "认": "認",
    "设": "設", "置": "置", "项": "項", "发": "發", "开": "開", "动": "動",
    "网": "網", "络": "絡", "终": "終", "链": "鏈", "接": "接", "错": "錯",
    "误": "誤", "状": "狀", "态": "態", "时": "時", "间": "間", "线": "線",
    "读": "讀", "写": "寫", "删": "刪", "除": "除", "添": "添", "加": "加",
    "编": "編", "辑": "輯", "复": "複", "制": "制", "粘": "粘", "贴": "貼",
    "刷": "刷", "新": "新", "权": "權", "限": "限", "制": "制", "开": "開",
    "启": "啟", "用": "用", "禁": "禁", "图": "圖", "标": "標", "记": "記",
    "录": "錄", "载": "載", "统": "統", "导": "導", "选": "選", "择": "擇",
    "取": "取", "输": "輸", "净": "淨", "检": "檢", "查": "查", "测": "測",
    "试": "試", "验": "驗", "证": "證", "分": "分", "析": "析", "响": "響",
    "应": "應", "请": "請", "求": "求", "数": "數", "据": "據", "包": "包",
    "代": "代", "理": "理", "服": "服", "环": "環", "境": "境", "进": "進",
    "程": "程", "文": "文", "件": "件", "档": "檔", "库": "庫", "级": "級",
    "页": "頁", "设": "設", "备": "備", "机": "機", "主": "主", "记": "記",
    "忆": "憶", "识": "識", "别": "別", "风": "風", "险": "險", "规": "規",
    "则": "則", "厂": "廠", "商": "商", "注": "註", "释": "釋", "译": "譯",
    "协": "協", "议": "議", "价": "價", "额": "額", "软": "軟", "硬": "硬",
    "键": "鍵", "盘": "盤", "鼠": "鼠", "标": "標", "结": "結", "构": "構",
    "重": "重", "计": "計", "算": "算", "统": "統", "显": "顯", "示": "示",
    "说": "說", "明": "明", "这": "這", "是": "是", "什": "什", "么": "麼",
    "还": "還", "没": "沒", "有": "有", "目": "目", "填": "填", "路": "路",
    "径": "徑", "都": "都", "行": "行", "节": "節", "超": "超", "只": "只",
    "保": "保", "留": "留", "身": "身", "份": "份", "句": "句", "不": "不",
    "生": "生", "效": "效", "常": "常", "见": "見", "值": "值", "本": "本",
    "地": "地", "小": "小", "模": "模", "型": "型", "开": "開", "始": "始",
    "思": "思", "维": "維", "恢": "恢", "内": "內", "执": "執", "技": "技",
    "能": "能", "库": "庫", "工": "工", "具": "具", "链": "鏈", "拼": "拼",
    "好": "好", "全": "全", "按": "按", "层": "層", "拆": "拆", "类": "類",
    "容": "容", "过": "過", "滤": "濾", "探": "探", "活": "活", "节": "節",
    "点": "點", "改": "改", "规": "規", "则": "則", "头": "頭", "每": "每",
    "新": "新", "增": "增", "普": "普", "通": "通", "服": "服", "务": "務",
    "商": "商", "未": "未", "授": "授", "权": "權", "代": "代", "正": "正",
    "文": "文", "替": "替", "换": "換", "没": "沒", "有": "有", "流": "流",
    "式": "式", "清": "清", "空": "空", "日": "日", "志": "誌", "温": "溫",
    "度": "度", "独": "獨", "立": "立", "客": "客", "户": "戶", "端": "端",
    "部": "部", "留": "留", "命": "命", "中": "中", "所": "所", "慎": "慎",
    "定": "定", "第": "第", "一": "一", "次": "次", "启": "啟", "动": "動",
    "管": "管", "理": "理", "员": "員", "索": "索", "引": "引", "条": "條",
    "整": "整", "段": "段", "塞": "塞", "编": "編", "辑": "輯", "尾": "尾",
    "干": "幹", "节": "節", "侧": "側", "树": "樹", "提": "提", "交": "交",
    "权": "權", "限": "限", "签": "簽", "证": "證", "描": "描", "述": "述",
    "信": "信", "任": "任", "算": "算", "首": "首", "几": "幾", "十": "十",
    "秒": "秒", "那": "那", "服": "服", "同": "同", "局": "局", "域": "域",
    "解": "解", "压": "壓", "大": "大", "概": "概", "之": "之", "后": "後",
    "触": "觸", "词": "詞", "帮": "幫", "助": "助", "逆": "逆", "向": "向",
    "跑": "跑", "允": "允", "许": "許", "长": "長", "置": "置", "顶": "頂",
    "取": "取", "消": "消", "随": "隨", "说": "說",
}

S2T = str.maketrans(S2T_MAP)


def to_hant(s):
    return s.translate(S2T)


# ---------------------------------------------------------------- 输出

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def write(lang, table):
    d = os.path.join(RES, lang + ".lproj")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "Localizable.strings")
    lines = ["/* NpcLab · %s */" % lang, ""]
    for k in sorted(table):
        if k == table[k]:
            # 跟原文一样就不写，省得 strings 文件里全是废行
            continue
        lines.append('"%s" = "%s";' % (esc(k), esc(table[k])))
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return p, len(lines) - 2


def main():
    keys = extract()
    print("界面中文串：%d 条" % len(keys))

    # zh-Hans 用原文，不生成映射（SwiftUI 找不到 key 时直接用字面量）
    # 但还是要建目录，否则系统认为没有中文资源
    d = os.path.join(RES, "zh-Hans.lproj")
    os.makedirs(d, exist_ok=True)
    io.open(os.path.join(d, "Localizable.strings"), "w",
            encoding="utf-8", newline="\n").write("/* NpcLab · 原文就是键 */\n")

    miss = [k for k in keys if k not in EN]
    en_table = {k: EN.get(k, k) for k in keys}
    p, n = write("en", en_table)
    print("  + en.lproj/Localizable.strings        %d 条" % n)

    hant = {k: to_hant(k) for k in keys}
    p, n = write("zh-Hant", hant)
    print("  + zh-Hant.lproj/Localizable.strings   %d 条" % n)

    # 其余 15 种。没翻的条目回退英文；英文也没翻的回退中文原文（write 里会跳过）。
    for lang in sorted(TABLES):
        table = TABLES[lang]
        merged = {}
        for k in keys:
            if k in table:
                merged[k] = table[k]
            elif k in EN:
                merged[k] = EN[k]
            else:
                merged[k] = k          # 退到中文原文
        p, n = write(lang, merged)
        cov = COVERAGE.get(lang, "")
        print("  + %-34s %3d 条  %s" % (lang + ".lproj/Localizable.strings", n, cov))

    print("\n合计 %d 种语言" % len(ALL_LANGS))
    print("  " + " / ".join(ALL_LANGS))

    # Info.plist 的 CFBundleLocalizations 要跟这里一致，
    # 否则 App Store 里不会显示这些语言，系统也不会主动挑 .lproj
    sync_infoplist(ALL_LANGS)

    if miss:
        print("\n英文没覆盖的 %d 条（会回退中文）：" % len(miss))
        for m in miss[:10]:
            print("   ", m[:60])
    return 0


def sync_infoplist(langs):
    """把 CFBundleLocalizations 写进 NpcLab/Info.plist（纯文本编辑，不依赖 plistlib 的格式）"""
    path = os.path.join(ROOT, "NpcLab", "Info.plist")
    if not os.path.isfile(path):
        print("  ! 找不到 Info.plist，跳过 CFBundleLocalizations")
        return

    s = io.open(path, encoding="utf-8").read()
    block = ("\t<key>CFBundleLocalizations</key>\n\t<array>\n"
             + "".join("\t\t<string>%s</string>\n" % l for l in langs)
             + "\t</array>\n")

    if "<key>CFBundleLocalizations</key>" in s:
        # 替换已有块
        s2 = re.sub(
            r"[ \t]*<key>CFBundleLocalizations</key>\s*<array>.*?</array>\n",
            block, s, count=1, flags=re.S)
    else:
        # 插在 CFBundleDevelopmentRegion 后面，Apple 的惯例位置
        anchor = re.search(r"[ \t]*<key>CFBundleDevelopmentRegion</key>\s*<string>[^<]*</string>\n", s)
        if anchor:
            s2 = s[:anchor.end()] + block + s[anchor.end():]
        else:
            s2 = s.replace("\t<dict>\n", "\t<dict>\n" + block, 1)

    if s2 != s:
        io.open(path, "w", encoding="utf-8", newline="\n").write(s2)
        print("  + Info.plist CFBundleLocalizations = %d 种" % len(langs))
    else:
        print("  = Info.plist CFBundleLocalizations 已是 %d 种" % len(langs))


if __name__ == "__main__":
    sys.exit(main())
