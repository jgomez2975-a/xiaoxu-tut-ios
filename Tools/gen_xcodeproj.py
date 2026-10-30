#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从目录树生成 NpcLab.xcodeproj（不依赖 mac / xcodegen）。

用法：python Tools/gen_xcodeproj.py

产物：
  NpcLab.xcodeproj/project.pbxproj
  NpcLab.xcodeproj/xcshareddata/xcschemes/NpcLab.xcscheme

结构照 AzTuT/Minis 那个包来：一个主 App + 三个 appex 扩展，
扩展通过 "Embed Foundation Extensions" 阶段塞进 PlugIns/。
"""
import hashlib
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
APP = os.path.join(ROOT, "NpcLab")
EXT = os.path.join(ROOT, "Extensions")
PROJ = os.path.join(ROOT, "NpcLab.xcodeproj")

BUNDLE_ID = "com.npclab.client"
TARGET = "NpcLab"
DEPLOY = "16.0"
SWIFT = "5.0"

# 内核静态库在不在，决定整个工程是"真能跑 Linux"还是"界面占位"。
#
# kernel=ish（对齐 AzTuT/OpenMinis）的产物就是这 4 个：
#   libish.a        iSH 内置内核（kernel/ + fs/ + util/）
#   libish_emu.a    Asbestos 模拟器（guest ARM64 → host ARM64 gadget）
#   libfakefs.a     fakefs 的 sqlite 层
#   libNpcLinux.a   我们的 C 胶水层（NpcLinux.c）
#
# 分开放、不做 libtool 合并：内核里有几十组同名目标文件（fs/proc/version.o
# 与 init/version.o、一堆 util.o / sync.o…），libtool 按成员名去重会丢掉后
# 加入的那份，链接时报 undefined symbol。
KERNEL_LIBS = ["libish.a", "libish_emu.a", "libfakefs.a", "libNpcLinux.a"]
KERNEL_LIB = os.path.join(ROOT, "Vendor", KERNEL_LIBS[0])
HAS_KERNEL = os.path.isfile(KERNEL_LIB)

# 三个扩展，跟 Minis 的 PlugIns 一一对应
EXTENSIONS = [
    {
        "name": "NpcLabShare",
        "suffix": "share",
        "display": "收入 NpcLab",
        "kind": "share",          # 分享扩展
    },
    {
        "name": "NpcLabFileProvider",
        "suffix": "files",
        "display": "NpcLab 工作区",
        "kind": "fileprovider",
    },
    {
        "name": "NpcLabWidget",
        "suffix": "widget",
        "display": "NpcLab",
        "kind": "widget",
    },
]

# 同时编进主 App 和某个扩展的文件。
# Live Activity 的 ActivityAttributes 必须两边都看得见：主 App 拿它 Activity.request()，
# 扩展拿它渲染锁屏/灵动岛。Apple 官方示例（Food Truck）就是放在共享文件里两边都编。
# 容器由 codec 序列化，只要 struct 定义一致就能对上，不需要 framework。
SHARED_SOURCES = {
    "NpcLabWidget": ["NpcLab/Core/NpcActivityAttributes.swift"],
}


def oid(key):
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


def ftype(name):
    low = name.lower()
    if low.endswith(".swift"):
        return "sourcecode.swift"
    if low.endswith(".c"):
        return "sourcecode.c.c"
    if low.endswith(".h"):
        return "sourcecode.c.h"
    if low.endswith(".json"):
        return "text.json"
    if low.endswith(".md"):
        return "net.daringfireball.markdown"
    if low.endswith(".plist"):
        return "text.plist.xml"
    if low.endswith(".zip"):
        return "archive.zip"
    if low.endswith(".xcassets"):
        return "folder.assetcatalog"
    if low.endswith(".lproj"):
        return "folder"
    if low.endswith(".entitlements"):
        return "text.plist.entitlements"
    return "text"


def walk_app():
    """主 App 的 (源文件, 头文件, 资源)。

    内核有没有编进来，决定三件事：
      · LinuxRuntime.swift（真）还是 LinuxRuntimeStub.swift（假）进编译
      · Core/NpcLinux.c、Core/NpcUnzip.c 编不编
      · 链接时带不带 -force_load 那 4 个内核库
    """
    srcs, hdrs, res = [], [], []
    for base, dirs, files in os.walk(APP):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        dirs[:] = [d for d in dirs if not d.endswith(".xcassets")]
        for f in sorted(files):
            if f.startswith("."):
                continue
            full = os.path.join(base, f)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            if rel.endswith("Info.plist"):
                continue
            if ".xcassets/" in rel or rel.endswith(".xcassets"):
                continue

            if f.endswith(".swift"):
                if f == "LinuxRuntimeStub.swift" and HAS_KERNEL:
                    continue
                if f == "LinuxRuntime.swift" and not HAS_KERNEL:
                    continue
                srcs.append(rel)
            elif f.endswith(".c"):
                if HAS_KERNEL:
                    # NpcLinux.c 由 Tools/build_ish.sh 编进 Vendor/libNpcLinux.a，
                    # 工程里再编一次会 duplicate symbol（npc_linux_boot 等）。
                    if f == "NpcLinux.c":
                        continue
                    srcs.append(rel)
            elif f.endswith(".h"):
                hdrs.append(rel)
            elif rel.split("/")[-1].endswith((".json", ".md", ".zip")):
                res.append(rel)

    assets = os.path.join(APP, "Resources", "Assets.xcassets")
    if os.path.isdir(assets):
        a = os.path.relpath(assets, ROOT).replace(os.sep, "/")
        if a not in res:
            res.insert(0, a)

    # .lproj 目录整体拷进 bundle（folder reference），
    # iOS 运行时按 <bundle>/<lang>.lproj/Localizable.strings 去查
    resdir = os.path.join(APP, "Resources")
    if os.path.isdir(resdir):
        for d in sorted(os.listdir(resdir)):
            if not d.endswith(".lproj"):
                continue
            rel = os.path.relpath(os.path.join(resdir, d), ROOT).replace(os.sep, "/")
            if rel not in res:
                res.append(rel)

    return sorted(srcs), sorted(hdrs), sorted(set(res))


def walk_ext(ext):
    """某个扩展的源文件列表（含共享文件）"""
    d = os.path.join(EXT, ext["name"])
    srcs = []
    if os.path.isdir(d):
        for base, dirs, files in os.walk(d):
            dirs[:] = sorted(x for x in dirs if not x.startswith("."))
            for f in sorted(files):
                if not f.endswith(".swift"):
                    continue
                full = os.path.join(base, f)
                srcs.append(os.path.relpath(full, ROOT).replace(os.sep, "/"))
    for p in SHARED_SOURCES.get(ext["name"], []):
        if os.path.isfile(os.path.join(ROOT, p)) and p not in srcs:
            srcs.append(p)
    return sorted(srcs)


def main():
    srcs, hdrs, res = walk_app()
    ext_srcs = {e["name"]: walk_ext(e) for e in EXTENSIONS}

    print("主 Target：源文件 %d / 头文件 %d / 资源 %d" % (len(srcs), len(hdrs), len(res)))
    for e in EXTENSIONS:
        print("扩展 %-20s 源文件 %d" % (e["name"], len(ext_srcs[e["name"]])))
    if HAS_KERNEL:
        print("检测到 Vendor/libish.a 等 4 个内核库 —— 启用内置 Linux 内核（kernel=ish ARM64）")
    else:
        print("没有 Vendor/libish.a —— 终端走占位实现（先跑 Tools/build_ish.sh）")

    L = []
    w = L.append

    # ---------------------------------------------------------------- 头部
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # ------------------------------------------------------- PBXBuildFile
    w("\n/* Begin PBXBuildFile section */")
    for p in srcs:
        w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
          % (oid("bf:" + p), os.path.basename(p), oid("fr:" + p), os.path.basename(p)))
    for p in res:
        w("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
          % (oid("bfr:" + p), os.path.basename(p), oid("fr:" + p), os.path.basename(p)))

    # 扩展自己的源文件（含共享文件）。id 里带扩展名，否则跟主 target 的 build file 撞
    for e in EXTENSIONS:
        for p in ext_srcs[e["name"]]:
            w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
              % (oid("bfx:" + e["name"] + ":" + p), os.path.basename(p),
                 oid("fr:" + p), os.path.basename(p)))

    # 主 target 把三个 appex 嵌进 PlugIns/
    for e in EXTENSIONS:
        w("\t\t%s /* %s.appex in Embed Foundation Extensions */ = "
          "{isa = PBXBuildFile; fileRef = %s /* %s.appex */; "
          "settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };"
          % (oid("embed:" + e["name"]), e["name"], oid("prodx:" + e["name"]), e["name"]))
    w("/* End PBXBuildFile section */")

    # ------------------------------------------------------ PBXFileReference
    w("\n/* Begin PBXFileReference section */")
    w('\t\t%s /* NpcLab.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
      'includeInIndex = 0; path = NpcLab.app; sourceTree = BUILT_PRODUCTS_DIR; };' % oid("product"))

    for e in EXTENSIONS:
        w('\t\t%s /* %s.appex */ = {isa = PBXFileReference; explicitFileType = '
          '"wrapper.app-extension"; includeInIndex = 0; path = %s.appex; '
          'sourceTree = BUILT_PRODUCTS_DIR; };'
          % (oid("prodx:" + e["name"]), e["name"], e["name"]))
        ip = "Extensions/%s/Info.plist" % e["name"]
        w('\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
          'path = %s; sourceTree = "<group>"; };' % (oid("fr:" + ip), ip))

    info = "NpcLab/Info.plist"
    w('\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
      'path = Info.plist; sourceTree = "<group>"; };' % oid("fr:" + info))

    # 去重：共享文件在主 target 和扩展里都出现，PBXFileReference 只能定义一次
    all_files = list(dict.fromkeys(list(srcs) + list(hdrs) + list(res)
                                   + [p for e in EXTENSIONS for p in ext_srcs[e["name"]]]))

    for p in all_files:
        name = os.path.basename(p)
        t = ftype(name)
        if t in ("folder.assetcatalog", "folder"):
            w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; '
              'path = %s; sourceTree = "<group>"; };' % (oid("fr:" + p), name, t, name))
        else:
            w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; '
              'path = %s; sourceTree = "<group>"; };' % (oid("fr:" + p), name, t, name))
    w("/* End PBXFileReference section */")

    # -------------------------------------------------- PBXContainerItemProxy
    w("\n/* Begin PBXContainerItemProxy section */")
    for e in EXTENSIONS:
        w("\t\t%s /* PBXContainerItemProxy */ = {" % oid("proxy:" + e["name"]))
        w("\t\t\tisa = PBXContainerItemProxy;")
        w("\t\t\tcontainerPortal = %s /* Project object */;" % oid("project"))
        w("\t\t\tproxyType = 1;")
        w("\t\t\tremoteGlobalIDString = %s;" % oid("target:" + e["name"]))
        w("\t\t\tremoteInfo = %s;" % e["name"])
        w("\t\t};")
    w("/* End PBXContainerItemProxy section */")

    # ------------------------------------------------ PBXCopyFilesBuildPhase
    # dstSubfolderSpec = 13 → PlugIns；dstPath 留空
    w("\n/* Begin PBXCopyFilesBuildPhase section */")
    w("\t\t%s /* Embed Foundation Extensions */ = {" % oid("phase:embed"))
    w("\t\t\tisa = PBXCopyFilesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tdstPath = \"\";")
    w("\t\t\tdstSubfolderSpec = 13;")
    w("\t\t\tfiles = (")
    for e in EXTENSIONS:
        w("\t\t\t\t%s /* %s.appex in Embed Foundation Extensions */,"
          % (oid("embed:" + e["name"]), e["name"]))
    w("\t\t\t);")
    w("\t\t\tname = \"Embed Foundation Extensions\";")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXCopyFilesBuildPhase section */")

    # ------------------------------------------------ PBXFrameworksBuildPhase
    w("\n/* Begin PBXFrameworksBuildPhase section */")
    for key in ["phase:fw"] + ["phase:fw:" + e["name"] for e in EXTENSIONS]:
        w("\t\t%s /* Frameworks */ = {" % oid(key))
        w("\t\t\tisa = PBXFrameworksBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # ------------------------------------------------------------- PBXGroup
    groups = {}
    all_dirs = set()
    for p in all_files:
        parts = p.split("/")
        for i in range(1, len(parts)):
            all_dirs.add("/".join(parts[:i]))
    all_dirs.add("NpcLab")
    all_dirs.add("Extensions")

    children = {d: [] for d in all_dirs}
    for p in all_files:
        parent = "/".join(p.split("/")[:-1])
        children.setdefault(parent, []).append(("file", p))
    for d in sorted(all_dirs):
        parent = "/".join(d.split("/")[:-1])
        if parent:
            children.setdefault(parent, []).append(("dir", d))

    w("\n/* Begin PBXGroup section */")
    w("\t\t%s = {" % oid("grp:main"))
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w("\t\t\t\t%s /* NpcLab */," % oid("grp:NpcLab"))
    w("\t\t\t\t%s /* Extensions */," % oid("grp:Extensions"))
    w("\t\t\t\t%s /* Products */," % oid("grp:Products"))
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w("\t\t%s /* Products */ = {" % oid("grp:Products"))
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w("\t\t\t\t%s /* NpcLab.app */," % oid("product"))
    for e in EXTENSIONS:
        w("\t\t\t\t%s /* %s.appex */," % (oid("prodx:" + e["name"]), e["name"]))
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    for d in sorted(all_dirs, key=lambda x: (x.count("/"), x)):
        name = d.split("/")[-1]
        w("\t\t%s /* %s */ = {" % (oid("grp:" + d), name))
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for kind, val in sorted(children.get(d, []), key=lambda x: (x[0] != "dir", x[1])):
            if kind == "dir":
                w("\t\t\t\t%s /* %s */," % (oid("grp:" + val), val.split("/")[-1]))
            else:
                w("\t\t\t\t%s /* %s */," % (oid("fr:" + val), os.path.basename(val)))
        if d == "NpcLab":
            w("\t\t\t\t%s /* Info.plist */," % oid("fr:" + info))
        # 扩展目录要带上自己的 Info.plist
        for e in EXTENSIONS:
            if d == "Extensions/" + e["name"]:
                w("\t\t\t\t%s /* Info.plist */,"
                  % oid("fr:Extensions/%s/Info.plist" % e["name"]))
        w("\t\t\t);")
        w("\t\t\tpath = %s;" % name)
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")
    w("/* End PBXGroup section */")

    # ---------------------------------------------------- PBXNativeTarget
    w("\n/* Begin PBXNativeTarget section */")
    # 主 App
    w("\t\t%s /* %s */ = {" % (oid("target"), TARGET))
    w("\t\t\tisa = PBXNativeTarget;")
    w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;"
      % (oid("cfglist:target"), TARGET))
    w("\t\t\tbuildPhases = (")
    w("\t\t\t\t%s /* Sources */," % oid("phase:src"))
    w("\t\t\t\t%s /* Frameworks */," % oid("phase:fw"))
    w("\t\t\t\t%s /* Resources */," % oid("phase:res"))
    w("\t\t\t\t%s /* Embed Foundation Extensions */," % oid("phase:embed"))
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    for e in EXTENSIONS:
        w("\t\t\t\t%s /* PBXTargetDependency */," % oid("dep:" + e["name"]))
    w("\t\t\t);")
    w("\t\t\tname = %s;" % TARGET)
    w("\t\t\tproductName = %s;" % TARGET)
    w("\t\t\tproductReference = %s /* NpcLab.app */;" % oid("product"))
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")

    # 三个扩展
    for e in EXTENSIONS:
        t = "target:" + e["name"]
        w("\t\t%s /* %s */ = {" % (oid(t), e["name"]))
        w("\t\t\tisa = PBXNativeTarget;")
        w("\t\t\tbuildConfigurationList = %s /* Build configuration list for "
          "PBXNativeTarget \"%s\" */;" % (oid("cfglist:" + e["name"]), e["name"]))
        w("\t\t\tbuildPhases = (")
        w("\t\t\t\t%s /* Sources */," % oid("phase:src:" + e["name"]))
        w("\t\t\t\t%s /* Frameworks */," % oid("phase:fw:" + e["name"]))
        w("\t\t\t);")
        w("\t\t\tbuildRules = (")
        w("\t\t\t);")
        w("\t\t\tdependencies = (")
        w("\t\t\t);")
        w("\t\t\tname = %s;" % e["name"])
        w("\t\t\tproductName = %s;" % e["name"])
        w("\t\t\tproductReference = %s /* %s.appex */;"
          % (oid("prodx:" + e["name"]), e["name"]))
        w("\t\t\tproductType = \"com.apple.product-type.app-extension\";")
        w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # ---------------------------------------------------------- PBXProject
    w("\n/* Begin PBXProject section */")
    w("\t\t%s /* Project object */ = {" % oid("project"))
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    w("\t\t\t\tLastUpgradeCheck = 1500;")
    w("\t\t\t\tTargetAttributes = {")
    w("\t\t\t\t\t%s = {" % oid("target"))
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    w("\t\t\t\t\t};")
    for e in EXTENSIONS:
        w("\t\t\t\t\t%s = {" % oid("target:" + e["name"]))
        w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
        w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"%s\" */;"
      % (oid("cfglist:project"), TARGET))
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = zh_CN;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\tzh_CN,")
    w("\t\t\t\tzh-Hans,")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w("\t\t\tmainGroup = %s;" % oid("grp:main"))
    w("\t\t\tproductRefGroup = %s /* Products */;" % oid("grp:Products"))
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w("\t\t\t\t%s /* %s */," % (oid("target"), TARGET))
    for e in EXTENSIONS:
        w("\t\t\t\t%s /* %s */," % (oid("target:" + e["name"]), e["name"]))
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # ------------------------------------------------ PBXResourcesBuildPhase
    w("\n/* Begin PBXResourcesBuildPhase section */")
    w("\t\t%s /* Resources */ = {" % oid("phase:res"))
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for p in res:
        w("\t\t\t\t%s /* %s in Resources */," % (oid("bfr:" + p), os.path.basename(p)))
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # --------------------------------------------------- PBXSourcesBuildPhase
    w("\n/* Begin PBXSourcesBuildPhase section */")
    w("\t\t%s /* Sources */ = {" % oid("phase:src"))
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for p in srcs:
        w("\t\t\t\t%s /* %s in Sources */," % (oid("bf:" + p), os.path.basename(p)))
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")

    for e in EXTENSIONS:
        w("\t\t%s /* Sources */ = {" % oid("phase:src:" + e["name"]))
        w("\t\t\tisa = PBXSourcesBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        for p in ext_srcs[e["name"]]:
            w("\t\t\t\t%s /* %s in Sources */," % (oid("bfx:" + e["name"] + ":" + p), os.path.basename(p)))
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # ---------------------------------------------------- PBXTargetDependency
    w("\n/* Begin PBXTargetDependency section */")
    for e in EXTENSIONS:
        w("\t\t%s /* PBXTargetDependency */ = {" % oid("dep:" + e["name"]))
        w("\t\t\tisa = PBXTargetDependency;")
        w("\t\t\ttarget = %s /* %s */;" % (oid("target:" + e["name"]), e["name"]))
        w("\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;" % oid("proxy:" + e["name"]))
        w("\t\t};")
    w("/* End PBXTargetDependency section */")

    # --------------------------------------------------- XCBuildConfiguration
    def cfg(key, name, settings):
        w("\t\t%s /* %s */ = {" % (oid(key), name))
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        for k in sorted(settings):
            w("\t\t\t\t%s = %s;" % (k, settings[k]))
        w("\t\t\t};")
        w("\t\t\tname = %s;" % name)
        w("\t\t};")

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT,
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    }
    dbg = dict(common)
    dbg.update({
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": "(\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t)",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\"",
    })
    rel = dict(common)
    rel.update({
        "DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "\"-O\"",
        "VALIDATE_PRODUCT": "YES",
    })

    tgt = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "\"\"",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "NpcLab/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "LD_RUNPATH_SEARCH_PATHS": "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t)",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "\"$(TARGET_NAME)\"",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": SWIFT,
        "TARGETED_DEVICE_FAMILY": "\"1,2\"",
    }
    tgt["SWIFT_OBJC_BRIDGING_HEADER"] = "\"NpcLab/NpcLab-Bridging-Header.h\""
    # App Group：分享扩展往 Inbox 里放文件，主 App 和小组件都要读得到。
    # TrollStore 安装时会带上这份 entitlements；普通免签构建里它被忽略。
    tgt["CODE_SIGN_ENTITLEMENTS"] = "NpcLab/NpcLab.entitlements"
    tgt["HEADER_SEARCH_PATHS"] = (
        "(\n"
        "\t\t\t\t\t\"$(inherited)\",\n"
        "\t\t\t\t\t\"$(SRCROOT)/NpcLab/Core\",\n"
        "\t\t\t\t\t\"$(SRCROOT)/deps/ish/app\",\n"
        "\t\t\t\t)"
    )
    if HAS_KERNEL:
        # 每个库都要 -force_load：内核里那些 initcall / 设备驱动没人显式引用，
        # 普通链接会被整段裁掉，运行时直接空指针
        ldflags = ["$(inherited)"]
        for lib in KERNEL_LIBS:
            ldflags += ["-force_load", "$(SRCROOT)/Vendor/" + lib]
        ldflags += ["-lz", "-lsqlite3"]
        tgt["OTHER_LDFLAGS"] = (
            "(\n" + "".join('\t\t\t\t\t"%s",\n' % f for f in ldflags) + "\t\t\t\t)"
        )

    w("\n/* Begin XCBuildConfiguration section */")
    cfg("cfg:proj:d", "Debug", dbg)
    cfg("cfg:proj:r", "Release", rel)
    cfg("cfg:tgt:d", "Debug", tgt)
    cfg("cfg:tgt:r", "Release", tgt)

    # 扩展的编译配置
    for e in EXTENSIONS:
        et = {
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": "1",
            "DEVELOPMENT_TEAM": "\"\"",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Extensions/%s/Info.plist" % e["name"],
            "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
            # 扩展的 rpath 要比主 App 多一层，它在 PlugIns/ 下面
            "LD_RUNPATH_SEARCH_PATHS": (
                "(\n"
                "\t\t\t\t\t\"$(inherited)\",\n"
                "\t\t\t\t\t\"@executable_path/Frameworks\",\n"
                "\t\t\t\t\t\"@executable_path/../../Frameworks\",\n"
                "\t\t\t\t)"
            ),
            "MARKETING_VERSION": "1.0",
            # 扩展不能带 App 的 bundle id，必须加后缀
            "PRODUCT_BUNDLE_IDENTIFIER": "%s.%s" % (BUNDLE_ID, e["suffix"]),
            "PRODUCT_NAME": "\"$(TARGET_NAME)\"",
            "SKIP_INSTALL": "YES",
            "SWIFT_VERSION": SWIFT,
            "TARGETED_DEVICE_FAMILY": "\"1,2\"",
            # 扩展里不能调 UIApplication.shared 之类，必须开这个
            "APPLICATION_EXTENSION_API_ONLY": "YES",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "CODE_SIGN_ENTITLEMENTS": "Extensions/%s/%s.entitlements" % (e["name"], e["name"]),
        }
        if e["kind"] == "widget":
            # 小组件不需要主 App 的 AppIcon
            et.pop("ASSETCATALOG_COMPILER_APPICON_NAME", None)
            et["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
            et["INFOPLIST_KEY_CFBundleDisplayName"] = "\"NpcLab\""

        cfg("cfg:%s:d" % e["name"], "Debug", et)
        cfg("cfg:%s:r" % e["name"], "Release", et)

    w("/* End XCBuildConfiguration section */")

    # ----------------------------------------------------- XCConfigurationList
    w("\n/* Begin XCConfigurationList section */")
    lists = [("cfglist:project", "PBXProject", "cfg:proj:d", "cfg:proj:r", TARGET),
             ("cfglist:target", "PBXNativeTarget", "cfg:tgt:d", "cfg:tgt:r", TARGET)]
    for e in EXTENSIONS:
        lists.append(("cfglist:" + e["name"], "PBXNativeTarget",
                      "cfg:%s:d" % e["name"], "cfg:%s:r" % e["name"], e["name"]))

    for key, label, d, r, nm in lists:
        w("\t\t%s /* Build configuration list for %s \"%s\" */ = {" % (oid(key), label, nm))
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w("\t\t\t\t%s /* Debug */," % oid(d))
        w("\t\t\t\t%s /* Release */," % oid(r))
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")

    w("\t};")
    w("\trootObject = %s /* Project object */;" % oid("project"))
    w("}")

    os.makedirs(PROJ, exist_ok=True)
    with io.open(os.path.join(PROJ, "project.pbxproj"), "w",
                 encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")

    write_scheme()
    print("写入", os.path.join(PROJ, "project.pbxproj"))


def write_scheme():
    sd = os.path.join(PROJ, "xcshareddata", "xcschemes")
    os.makedirs(sd, exist_ok=True)
    scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES"
            buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TID}"
               BuildableName = "NpcLab.app" BlueprintName = "NpcLab" ReferencedContainer = "container:NpcLab.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0"
      useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TID}"
            BuildableName = "NpcLab.app" BlueprintName = "NpcLab" ReferencedContainer = "container:NpcLab.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TID}"
            BuildableName = "NpcLab.app" BlueprintName = "NpcLab" ReferencedContainer = "container:NpcLab.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""".replace("{TID}", oid("target"))
    with io.open(os.path.join(sd, "NpcLab.xcscheme"), "w",
                 encoding="utf-8", newline="\n") as f:
        f.write(scheme)
    print("写入", os.path.join(sd, "NpcLab.xcscheme"))


if __name__ == "__main__":
    main()
