//
//  NpcUnzip.c
//  NpcLab
//
//  自己写而不引第三方库，是因为只有两个需求：解 rootfs、保住符号链接。
//  后者是硬性的——Alpine 的 /bin 下几百个命令全是 busybox 的软链，
//  丢了链接这个 Linux 就是个空壳。
//

#include "NpcUnzip.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define EOCD_SIG 0x06054b50u
#define CEN_SIG  0x02014b50u
#define LOC_SIG  0x04034b50u
#define CHUNK    65536

static uint16_t rd16(const unsigned char *p) {
    return (uint16_t) (p[0] | (p[1] << 8));
}
static uint32_t rd32(const unsigned char *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static int mkdirs(const char *path) {
    char tmp[4096];
    size_t n = strlen(path);
    if (n >= sizeof(tmp)) return -1;
    memcpy(tmp, path, n + 1);
    for (size_t i = 1; i < n; i++) {
        if (tmp[i] != '/') continue;
        tmp[i] = 0;
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        tmp[i] = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

/// 拼接并挡住 ../ 越界
static int join_path(char *out, size_t cap, const char *root, const char *name) {
    if (strstr(name, "../") || strncmp(name, "/", 1) == 0 || strcmp(name, "..") == 0)
        return -1;
    int n = snprintf(out, cap, "%s/%s", root, name);
    if (n <= 0 || (size_t) n >= cap) return -1;
    return 0;
}

int npc_rmtree(const char *path) {
    DIR *d = opendir(path);
    if (!d) return (errno == ENOENT) ? 0 : -1;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char sub[4096];
        if (snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name) >= (int) sizeof(sub)) continue;
        struct stat st;
        if (lstat(sub, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) npc_rmtree(sub);
        else unlink(sub);
    }
    closedir(d);
    return rmdir(path);
}

int npc_unzip_is_done(const char *destDir) {
    char probe[4096];
    snprintf(probe, sizeof(probe), "%s/meta.db", destDir);
    return access(probe, F_OK) == 0;
}

/// 解一个条目的数据到 out（已 malloc）
static int inflate_entry(const unsigned char *src, size_t srcLen,
                         unsigned char **out, size_t outLen, int method) {
    unsigned char *buf = malloc(outLen + 1);
    if (!buf) return -3;
    if (method == 0) {
        if (srcLen < outLen) outLen = srcLen;
        memcpy(buf, src, outLen);
    } else if (method == 8) {
        z_stream z;
        memset(&z, 0, sizeof(z));
        if (inflateInit2(&z, -MAX_WBITS) != Z_OK) { free(buf); return -4; }
        z.next_in = (Bytef *) src;
        z.avail_in = (uInt) srcLen;
        z.next_out = buf;
        z.avail_out = (uInt) outLen;
        int rc = inflate(&z, Z_FINISH);
        inflateEnd(&z);
        if (rc != Z_STREAM_END && rc != Z_OK) { free(buf); return -4; }
        outLen = z.total_out;
    } else {
        free(buf);
        return -4;
    }
    buf[outLen] = 0;
    *out = buf;
    return (int) outLen;
}

int npc_unzip(const char *zipPath, const char *destDir,
              npc_unzip_progress progress, void *ctx) {
    FILE *f = fopen(zipPath, "rb");
    if (!f) return -1;

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long fsize = ftell(f);

    // 从尾部往前找 EOCD（注释最长 65535）
    unsigned char tail[65557];
    long tailLen = fsize < (long) sizeof(tail) ? fsize : (long) sizeof(tail);
    if (fseek(f, fsize - tailLen, SEEK_SET) != 0) { fclose(f); return -1; }
    if (fread(tail, 1, (size_t) tailLen, f) != (size_t) tailLen) { fclose(f); return -1; }

    long eocd = -1;
    for (long i = tailLen - 22; i >= 0; i--) {
        if (rd32(tail + i) == EOCD_SIG) { eocd = i; break; }
    }
    if (eocd < 0) { fclose(f); return -2; }

    uint16_t total = rd16(tail + eocd + 10);
    uint32_t cenOff = rd32(tail + eocd + 16);
    if (total == 0) { fclose(f); return 0; }

    mkdirs(destDir);

    long pos = (long) cenOff;
    int done = 0;

    for (uint16_t idx = 0; idx < total; idx++) {
        if (fseek(f, pos, SEEK_SET) != 0) { fclose(f); return -2; }

        unsigned char h[46];
        if (fread(h, 1, 46, f) != 46 || rd32(h) != CEN_SIG) { fclose(f); return -2; }

        uint16_t method   = rd16(h + 10);
        uint32_t compSize = rd32(h + 20);
        uint32_t rawSize  = rd32(h + 24);
        uint16_t nameLen  = rd16(h + 28);
        uint16_t extraLen = rd16(h + 30);
        uint16_t cmtLen   = rd16(h + 32);
        uint32_t extAttr  = rd32(h + 38);
        uint32_t locOff   = rd32(h + 42);

        if (nameLen == 0 || nameLen > 1024) { fclose(f); return -2; }
        char name[1025];
        if (fread(name, 1, nameLen, f) != nameLen) { fclose(f); return -2; }
        name[nameLen] = 0;

        pos = ftell(f) + extraLen + cmtLen;

        if (name[0] == 0 || strcmp(name, ".") == 0) continue;

        char outPath[4096];
        if (join_path(outPath, sizeof(outPath), destDir, name) != 0) continue;

        mode_t mode = (mode_t) ((extAttr >> 16) & 0xFFFF);
        int isDir = (nameLen > 0 && name[nameLen - 1] == '/');
        int isLink = S_ISLNK(mode);

        if (isDir) {
            mkdirs(outPath);
            if (mode) chmod(outPath, mode & 07777);
            done++;
            if (progress && (done % 64 == 0)) progress(done, total, name, ctx);
            continue;
        }

        // 读本地头定位真实数据起点（中央目录的 compSize 有时不可靠）
        long save = ftell(f);
        if (fseek(f, (long) locOff, SEEK_SET) != 0) { fclose(f); return -2; }
        unsigned char lh[30];
        if (fread(lh, 1, 30, f) != 30 || rd32(lh) != LOC_SIG) { fclose(f); return -2; }
        uint16_t lNameLen = rd16(lh + 26);
        uint16_t lExtra   = rd16(lh + 28);
        long dataOff = (long) locOff + 30 + lNameLen + lExtra;
        fseek(f, save, SEEK_SET);

        if (compSize == 0xFFFFFFFFu || rawSize == 0xFFFFFFFFu) {
            // zip64 标记，rootfs 里不该出现
            continue;
        }

        unsigned char *comp = malloc(compSize ? compSize : 1);
        if (!comp) { fclose(f); return -3; }
        if (fseek(f, dataOff, SEEK_SET) != 0) { free(comp); fclose(f); return -2; }
        if (compSize && fread(comp, 1, compSize, f) != compSize) {
            free(comp); fclose(f); return -2;
        }

        unsigned char *raw = NULL;
        int got = inflate_entry(comp, compSize, &raw, rawSize, method);
        free(comp);
        if (got < 0) { fclose(f); return -4; }

        if (isLink) {
            unlink(outPath);
            // 链接目标就是文件内容
            if (symlink((const char *) raw, outPath) != 0 && errno != EEXIST) {
                // 目标已有东西，先删再建
                unlink(outPath);
                symlink((const char *) raw, outPath);
            }
        } else {
            unlink(outPath);   // 覆盖旧文件，别留截断的尾巴
            FILE *o = fopen(outPath, "wb");
            if (!o) { free(raw); fclose(f); return -3; }
            if (got > 0 && fwrite(raw, 1, (size_t) got, o) != (size_t) got) {
                fclose(o); free(raw); fclose(f); return -3;
            }
            fclose(o);
            if (mode) chmod(outPath, mode & 07777);
        }
        free(raw);

        done++;
        if (progress) progress(done, total, name, ctx);
    }

    fclose(f);
    return 0;
}
