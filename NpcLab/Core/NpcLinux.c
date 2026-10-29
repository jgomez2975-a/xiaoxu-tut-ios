//
//  NpcLinux.c
//  NpcLab
//
//  iSH 内核的 App 侧胶水层。
//
//  iSH 编译成静态库后仍然是"半成品"——它不知道 rootfs 在哪、不知道输出给谁，
//  还缺 4 个 Terminal_* 符号和几个 ObjC 桥。这些原本由 iSH 自己的 UIKit 终端实现，
//  这里用一套无 UI 依赖的环形缓冲顶掉，让内核能在一个纯 C 环境里跑起来。
//
//  线程模型：
//    - 内核占一个独立线程，actuate_kernel() 进去就不再出来
//    - 所有进内核的调用都必须经 async_do_in_workqueue 排队，不能直接调
//    - 输出回调发生在内核线程，上层要自己切主线程
//

#include "NpcLinux.h"
#include "LinuxInterop.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <dispatch/dispatch.h>

// 由 Tools/ish-npclab.patch 加进 app/LinuxPTY.c
extern int npc_pty_write(struct linux_tty *tty, const char *buf, size_t len);

#define NPC_MAX_TERM 8
#define NPC_ROOT_MAX 1024

struct npc_term {
    int used;
    int is_session;
    struct linux_tty *ltty;
};

static struct npc_term g_terms[NPC_MAX_TERM];
static nsobj_t g_session_term = NULL;
static int g_claim_session = 0;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_exec_lock = PTHREAD_MUTEX_INITIALIZER;

static npc_out_cb g_cb = NULL;
static void *g_cb_ctx = NULL;

static char g_root[NPC_ROOT_MAX];
static char g_err[512];
static volatile int g_booting = 0;
static volatile int g_alive = 0;   // 内核线程已投递
static volatile int g_ready = 0;   // 已用 /bin/true 真测过
static volatile int g_session_dead = 0;

// exec 期间独占的输出缓冲
static char *g_buf = NULL;
static size_t g_buf_len = 0;
static size_t g_buf_cap = 0;
static int g_capture = 0;

static const char *kVersion = "iSH 内核 / NpcLab 集成层 1.0";

// ---------------------------------------------------------------------------
// 小块工具
// ---------------------------------------------------------------------------

static void set_err(const char *msg) {
    pthread_mutex_lock(&g_lock);
    snprintf(g_err, sizeof(g_err), "%s", msg ? msg : "");
    pthread_mutex_unlock(&g_lock);
}

static int buf_append(const char *data, size_t len) {
    if (g_buf_len + len + 1 > g_buf_cap) {
        size_t want = (g_buf_cap ? g_buf_cap * 2 : 8192);
        while (want < g_buf_len + len + 1) want *= 2;
        char *p = realloc(g_buf, want);
        if (!p) return -1;
        g_buf = p;
        g_buf_cap = want;
    }
    memcpy(g_buf + g_buf_len, data, len);
    g_buf_len += len;
    g_buf[g_buf_len] = 0;
    return 0;
}

// ---------------------------------------------------------------------------
// iSH 缺的符号：终端
//
// 内核调这 4 个函数时认为对面是一个 UIKit 终端对象。我们给的是一个 8 槽的
// 静态数组，槽位不回收（pty 数量本就有限），避免内核线程和主线程抢同一块内存。
// ---------------------------------------------------------------------------

nsobj_t Terminal_terminalWithType_number(int type, int number) {
    (void) type;
    (void) number;

    pthread_mutex_lock(&g_lock);
    int idx = -1;
    for (int i = 0; i < NPC_MAX_TERM; i++) {
        if (!g_terms[i].used) { idx = i; break; }
    }
    if (idx < 0) idx = NPC_MAX_TERM - 1;   // 槽位耗尽，复用最后一个

    struct npc_term *t = &g_terms[idx];
    t->used = 1;
    t->ltty = NULL;
    t->is_session = 0;

    if (g_claim_session && g_session_term == NULL) {
        t->is_session = 1;
        g_session_term = t;
    }
    pthread_mutex_unlock(&g_lock);
    return (nsobj_t) t;
}

int Terminal_roomForOutput(nsobj_t _self) {
    (void) _self;
    // 不做背压：UI 侧是异步消费的，这里返回大值让内核尽管写
    return 1 << 20;
}

int Terminal_sendOutput_length(nsobj_t _self, const char *data, int size) {
    if (!data || size <= 0) return 0;

    struct npc_term *t = (struct npc_term *) _self;
    int is_session = (t && t->is_session) || _self == g_session_term;

    int captured = 0;
    if (!is_session && g_capture) {
        pthread_mutex_lock(&g_exec_lock);
        if (g_capture) captured = (buf_append(data, (size_t) size) == 0);
        pthread_mutex_unlock(&g_exec_lock);
    }

    // 交互会话的输出直接上屏；exec 的输出只进缓冲，避免污染终端
    if (is_session && !captured) {
        npc_out_cb cb = g_cb;
        void *ctx = g_cb_ctx;
        if (cb) cb(data, size, ctx);
    }
    return size;
}

void Terminal_setLinuxTTY(nsobj_t _self, struct linux_tty *tty) {
    struct npc_term *t = (struct npc_term *) _self;
    if (t) t->ltty = tty;
}

// ---------------------------------------------------------------------------
// iSH 缺的符号：内核回话
// ---------------------------------------------------------------------------

const char *DefaultRootPath(void) {
    return g_root;
}

void ConsoleLog(const char *data, unsigned len) {
    if (!g_cb || !data || len == 0) return;
    g_cb(data, (int) len, g_cb_ctx);
}

void ReportPanic(const char *message) {
    set_err(message ? message : "kernel panic");
    if (g_cb && message) {
        size_t n = strlen(message);
        g_cb(message, (int) n, g_cb_ctx);
    }
}

// iSH 用 ObjC 引用计数管终端对象。我们的终端是静态结构，计数无意义，
// 但必须成对存在，否则链接失败、运行时崩在 objc_retain 上。
nsobj_t objc_get(nsobj_t object) {
    return object;
}

void objc_put(nsobj_t object) {
    (void) object;
}

// 内核里两个可选的剪贴板/NSData 通道，LinuxPTY 不强制用，给空实现占位
nsobj_t UIPasteboard_get(void) { return NULL; }
long UIPasteboard_changeCount(void) { return 0; }
void UIPasteboard_set(const char *data, size_t len) { (void) data; (void) len; }
size_t NSData_length(nsobj_t data) { (void) data; return 0; }
const void *NSData_bytes(nsobj_t data) { (void) data; return NULL; }

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------

static void *kernel_main(void *arg) {
    (void) arg;
    // 不返回：内核在自己线程里调度，退出即崩
    actuate_kernel("");
    set_err("kernel 意外退出");
    g_alive = 0;
    g_booting = 0;
    return NULL;
}

int npc_linux_boot(const char *rootfsPath) {
    if (g_booting || g_alive) return 0;
    if (!rootfsPath || !*rootfsPath) return -1;

    size_t n = strlen(rootfsPath);
    if (n >= NPC_ROOT_MAX) return -2;
    memcpy(g_root, rootfsPath, n + 1);

    g_booting = 1;
    pthread_t th;
    if (pthread_create(&th, NULL, kernel_main, NULL) != 0) {
        g_booting = 0;
        set_err("内核线程创建失败");
        return -3;
    }
    pthread_detach(th);

    // 不能在这里 sleep 着等。actuate_kernel 一旦返回，内核就接管了这个线程，
    // 挂载 fakefs（rootfs_initcall → DefaultRootPath）也在那个线程里做。
    // 这里只标记"已投递"，真活了没有由 npc_linux_ready() 用 /bin/true 实测。
    g_alive = 1;
    g_booting = 0;
    return 0;
}

// 真探活：跑一次 /bin/true，退出码 0 才算内核起来了。
// 第一次进终端页调它，没就绪就由上层轮询重试。
int npc_linux_ready(void) {
    if (!g_alive) return 0;
    if (g_ready) return 1;

    char *out = NULL;
    int n = 0, rc = -1;
    // /bin/true 在 Alpine 里是 busybox 软链；能执行说明 fakefs 挂上了、chroot 成功了
    if (npc_linux_exec("true", 10.0, &out, &n, &rc) == 0 && rc == 0) {
        g_ready = 1;
    }
    if (out) free(out);
    return g_ready;
}

int npc_linux_booted(void) { return g_alive; }

const char *npc_linux_last_error(void) { return g_err; }

void npc_linux_set_output(npc_out_cb cb, void *ctx) {
    g_cb = cb;
    g_cb_ctx = ctx;
}

const char *npc_linux_root_path(void) { return g_root; }

const char *npc_linux_version(void) { return kVersion; }

// ---------------------------------------------------------------------------
// 执行
// ---------------------------------------------------------------------------

// 注意：这个结构必须堆分配。超时返回后内核那边的回调仍持有它，
// 放栈上会在函数退栈后被当成有效指针写，直接崩。
struct exec_wait {
    pthread_mutex_t m;
    pthread_cond_t c;
    int done;
    int rc;
    int abandoned;          // 超时后置 1，由回调负责回收
    char *cmd;              // 命令副本，生命周期同本结构
    const char *argv[4];
};

// 回调统一入口：谁最后持有谁回收
static void exec_finish(struct exec_wait *w, int rc) {
    pthread_mutex_lock(&w->m);
    w->rc = rc;
    w->done = 1;
    int orphan = w->abandoned;
    pthread_cond_signal(&w->c);
    pthread_mutex_unlock(&w->m);

    if (orphan) {
        pthread_mutex_destroy(&w->m);
        pthread_cond_destroy(&w->c);
        free(w->cmd);
        free(w);
    }
}

static const char *kEnv[] = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
    "TERM=xterm-256color",
    "LANG=C.UTF-8",
    "SHELL=/bin/sh",
    NULL
};

int npc_linux_exec(const char *cmd, double timeout,
                   char **out, int *outLen, int *exitCode) {
    if (!cmd) return -1;
    if (!g_alive) return -1;

    struct exec_wait *w = calloc(1, sizeof(*w));
    if (!w) return -3;
    pthread_mutex_init(&w->m, NULL);
    pthread_cond_init(&w->c, NULL);
    w->rc = -1;
    w->cmd = strdup(cmd);
    if (!w->cmd) {
        pthread_mutex_destroy(&w->m);
        pthread_cond_destroy(&w->c);
        free(w);
        return -3;
    }
    w->argv[0] = "/bin/sh";
    w->argv[1] = "-c";
    w->argv[2] = w->cmd;
    w->argv[3] = NULL;

    pthread_mutex_lock(&g_exec_lock);
    g_buf_len = 0;
    if (g_buf) g_buf[0] = 0;
    g_capture = 1;
    pthread_mutex_unlock(&g_exec_lock);

    // block 捕获 w（堆），不捕获任何栈变量
    async_do_in_workqueue(^{
        linux_start_session("/bin/sh", w->argv, kEnv, ^(int retval, int pid, nsobj_t terminal) {
            (void) pid;
            (void) terminal;
            // 命令结束不等于输出写完，LinuxPTY 的 flush 可能晚一拍；
            // 给内核线程 30ms 把最后一段吐出来再收口。
            struct timespec gap = { .tv_sec = 0, .tv_nsec = 30 * 1000 * 1000 };
            nanosleep(&gap, NULL);
            exec_finish(w, retval);
        });
    });

    int timedOut = 0;
    pthread_mutex_lock(&w->m);
    if (timeout > 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += (time_t) timeout;
        ts.tv_nsec += (long) ((timeout - (double) (time_t) timeout) * 1e9);
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
        while (!w->done) {
            if (pthread_cond_timedwait(&w->c, &w->m, &ts) == ETIMEDOUT) {
                if (!w->done) { timedOut = 1; w->abandoned = 1; }
                break;
            }
        }
    } else {
        while (!w->done) pthread_cond_wait(&w->c, &w->m);
    }
    int finalRc = w->rc;
    pthread_mutex_unlock(&w->m);

    pthread_mutex_lock(&g_exec_lock);
    g_capture = 0;
    size_t n = g_buf_len;
    char *copy = NULL;
    if (n > 0) {
        copy = malloc(n + 1);
        if (copy) { memcpy(copy, g_buf, n); copy[n] = 0; }
    } else {
        copy = malloc(1);
        if (copy) copy[0] = 0;
    }
    pthread_mutex_unlock(&g_exec_lock);

    if (!timedOut) {
        pthread_mutex_destroy(&w->m);
        pthread_cond_destroy(&w->c);
        free(w->cmd);
        free(w);
    }
    // 超时分支不碰 w：所有权已交给回调

    if (out) *out = copy;
    if (outLen) *outLen = (int) n;
    if (exitCode) *exitCode = timedOut ? -1 : finalRc;

    if (timedOut) return -2;
    return 0;
}

void npc_linux_free(char *p) { free(p); }

// ---------------------------------------------------------------------------
// iSH 的 async_do_in_ios
// ---------------------------------------------------------------------------
// 原实现在 deps/ish/app/IOSCalls.m，但它 #include <UIKit/UIKit.h> 和 Roots.h，
// 而我们这里只需要一行 dispatch_async，没必要为了一个函数把 UIKit 那套拖进来。
// LinuxInterop.o 和 LinuxTTY.o 都引用它（panic 上报、tty 销毁时切主线程）。
void async_do_in_ios(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

// ---------------------------------------------------------------------------
// iSH 的 FsInitialize
// ---------------------------------------------------------------------------
// LinuxRoot.c 的 ish_rootfs() 挂完 fakefs 会调 FsInitialize()。它的原实现在
// deps/ish/app/CurrentRoot.m，但那个文件同时 #import <Foundation/Foundation.h>
// 和 #include "kernel/calls.h"：在 kernel=linux 真内核模式下后者是完整 Linux
// 内核头，两套头必然撞（__attribute__ 被重定义、成片 typedef redefinition）。
//
// 那个函数只做一件事：读 /ish/version 判断 rootfs 版本、需要时跑迁移。我们的
// rootfs 是整包固定打进去的，不存在跨版本迁移，空实现语义上就够了。
void FsInitialize(void) {
}

// ---------------------------------------------------------------------------
// 交互会话
// ---------------------------------------------------------------------------

static int spawn_session(void) {
    // 必须 static：下面的 block 要引它，而 C 的 block 是按值捕获，
    // 数组类型不能被捕获（cannot refer to declaration with an array type
    // inside block）。静态存储期改成按地址引用就没这个问题。
    static const char *argv[] = {"/bin/sh", "-l", NULL};

    pthread_mutex_lock(&g_lock);
    g_claim_session = 1;
    pthread_mutex_unlock(&g_lock);

    __block int started = 0;
    async_do_in_workqueue(^{
        linux_start_session("/bin/sh", argv, kEnv, ^(int retval, int pid, nsobj_t terminal) {
            (void) retval;
            (void) pid;
            (void) terminal;
            g_session_dead = 1;   // sh 退出 = 会话结束
        });
        started = 1;
    });

    pthread_mutex_lock(&g_lock);
    g_claim_session = 0;
    pthread_mutex_unlock(&g_lock);

    return started ? 0 : -2;
}

int npc_linux_session_open(void) {
    if (!g_alive) return -1;
    if (g_session_term && !g_session_dead) return 0;
    g_session_dead = 0;
    return spawn_session();
}

int npc_linux_session_alive(void) {
    return (g_session_term != NULL) && !g_session_dead;
}

int npc_linux_session_write(const char *bytes, int len) {
    if (!bytes || len <= 0) return -1;
    struct npc_term *t = (struct npc_term *) g_session_term;
    if (!t || !t->ltty) return -1;
    return npc_pty_write(t->ltty, bytes, (size_t) len);
}

int npc_linux_session_resize(int cols, int rows) {
    struct npc_term *t = (struct npc_term *) g_session_term;
    if (!t || !t->ltty) return -1;
    struct linux_tty *ltty = t->ltty;
    // winsize 得回内核里改，不能在这里直接写
    async_do_in_workqueue(^{
        if (ltty->ops && ltty->ops->resize) ltty->ops->resize(ltty, cols, rows);
    });
    return 0;
}
