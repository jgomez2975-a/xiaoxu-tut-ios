//
//  NpcUnzip.h
//  NpcLab
//
//  最小 zip 解压器。只为 rootfs 服务：支持 store/deflate、目录、符号链接、权限位。
//  不处理 zip64、加密、分卷——rootfs 用不到。
//

#ifndef NPC_UNZIP_H
#define NPC_UNZIP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 进度回调，可能在任意线程调
typedef void (*npc_unzip_progress)(int done, int total, const char *name, void *ctx);

/// 把 zipPath 解到 destDir（不存在则创建）。
/// @return 0 成功；-1 打不开；-2 格式不对；-3 写盘失败；-4 解压失败
int npc_unzip(const char *zipPath, const char *destDir,
              npc_unzip_progress progress, void *ctx);

/// 目标目录是否已经解压过（看 meta.db 在不在）
int npc_unzip_is_done(const char *destDir);

/// 递归删除目录（重装 rootfs 用）
int npc_rmtree(const char *path);

#ifdef __cplusplus
}
#endif

#endif
