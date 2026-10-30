//
//  NpcLinux.h
//  NpcLab
//
//  把 iSH 内核（kernel=ish，Vendor/libish.a）接到 Swift 上的唯一入口。
//  这里是纯 C，不带任何 ObjC / UIKit 依赖，方便在 kernel 线程直接调。
//

#ifndef NPC_LINUX_H
#define NPC_LINUX_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 输出回调。可能在 kernel 线程被调用，调用方自己切主线程。
/// @param bytes 原始字节（带 ANSI 转义）
/// @param len   字节数，不保证以 \0 结尾
typedef void (*npc_out_cb)(const char *bytes, int len, void *ctx);

/// 启动内核。rootfsPath 指向解压后的 alpine-rootfs 目录（里面应有 meta.db 和 data/）。
/// 立即返回；内核在独立线程里跑，之后就一直在跑，不会退出。
/// @return 0 成功开始启动，负数为参数错误
int npc_linux_boot(const char *rootfsPath);

/// 内核线程是否已经投递（不代表已就绪）
int npc_linux_booted(void);

/// 真探活：跑 /bin/true 验证 fakefs 挂载与 chroot 成功。
/// 首次可能返回 0，上层轮询重试。@return 1 就绪 / 0 还没
int npc_linux_ready(void);

/// 最后一次错误 / panic 文本，没有则返回空串
const char *npc_linux_last_error(void);

/// 注册输出回调。传 NULL 取消。
void npc_linux_set_output(npc_out_cb cb, void *ctx);

/// 同步执行一条命令（/bin/sh -c），输出收集到 out。
/// @param timeout 秒，<=0 表示不限
/// @param out     输出缓冲，由本库 malloc，调用方用 npc_linux_free 释放
/// @param outLen  输出字节数
/// @param exitCode 进程退出码
/// @return 0 正常拿到结果，-1 未启动，-2 超时，-3 其它
int npc_linux_exec(const char *cmd, double timeout,
                   char **out, int *outLen, int *exitCode);

void npc_linux_free(char *p);

/// 打开交互会话（pty + /bin/sh -l）。重复调用返回已存在的会话。
/// @return 0 成功，-1 未启动，-2 内核拒绝
int npc_linux_session_open(void);

/// 往交互会话写按键（原始字节，可以是转义序列）
int npc_linux_session_write(const char *bytes, int len);

/// 调整窗口大小
int npc_linux_session_resize(int cols, int rows);

/// 会话是否还活着
int npc_linux_session_alive(void);

/// 当前 rootfs 路径（未 boot 时为空串）
const char *npc_linux_root_path(void);

/// 版本串，给设置页显示
const char *npc_linux_version(void);

#ifdef __cplusplus
}
#endif

#endif /* NPC_LINUX_H */
