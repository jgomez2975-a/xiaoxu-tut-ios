//
//  NpcLinux.c
//  NpcLab
//
//  iSH 内核的 App 侧胶水层（kernel=ish 版本）。
//
//  ==========================================================================
//  为什么是 kernel=ish（改之前先读完）
//  ==========================================================================
//
//  iSH 有两套完全不同的内核实现，meson 用 -Dkernel= 二选一：
//
//    kernel=linux  真 Linux 内核。要从 ish-app/linux clone 源码，用 Kbuild 编
//                  出几千个 .o。App 侧靠 linux/emu_asbestos.c 把内核的
//                  pt_regs 翻译成 cpu_state —— 而这个桥接只有 x86 版本，
//                  换 guest_arch=arm64 后 cpu_state 变成 x0..x30/sp/pc/nzcv，
//                  cpu->eax 那一堆直接编译不过。
//
//    kernel=ish    内置假内核。kernel/、fs/、emu/ 自己实现 syscall / 文件系统
//                  / 进程调度，不依赖 Linux 内核源码。产物就是 libish.a。
//                  AzTuT（Minis）走的就是这条：它的二进制里 kernel=linux 的
//                  符号（actuate_kernel / run_kernel / linux_start_session /
//                  ios_pty_open / LinuxPTY / LinuxRoot / FsInitialize）一个都
//                  没有，kernel=ish 的（mount_root / become_first_process /
//                  do_execve / task_start / fakefs）全在。
//
//  ==========================================================================
//  kernel=ish 的线程模型（跟 kernel=linux 完全不同，这是最容易踩的坑）
//  ==========================================================================
//
//  kernel=linux：整个内核跑在一个线程里，所有 guest 进程都在这个线程内调度。
//                进内核必须 async_do_in_workqueue 排队，不能直接调。
//
//  kernel=ish：  一个 guest 进程 = 一个宿主 pthread。
//                  · current 是 __thread 的（kernel/task.c:12）
//                  · task_start(task) → pthread_create，新线程里 current = task
//                  · task_run_current() → 在当前线程直接跑 current，不新建线程
//
//  所以这里不需要任何"投递到内核"的队列：谁想操作内核，就在自己线程里直接调，
//  current 由调用者自己维护（见下面 exec 里对 current 的保存/恢复）。
//
//  启动流程用 task_run_current() 跑 init（当前线程变成 init 的执行线程），
//  子进程用 task_start() 各起一个线程。
//
//  ==========================================================================
//  数据结构
//  ==========================================================================
//
//    pid 1        /bin/sh，stdio 全接 /dev/null。它不干实际活，只作为
//                 become_new_init_child() 的锚点存在（那个函数要 pid_get_task(1)）。
//    console      /dev/console 的 tty driver（纯 C 实现，替代 Terminal.m 的
//                 ios_tty_ops）。输出只进日志，不上屏。
//    session      交互会话。pty slave 的 driver 也是我们这套 ops，输出直接
//                 送 npc_out_cb 上屏。输入走 tty_input()。
//    exec         非交互执行。stdout/stderr 接宿主 pipe，从 pipe 读到 EOF，
//                 退出码靠 exit_hook 拿。
//

#include "NpcLinux.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/select.h>

// iSH 内核内部头。这些必须在 -I deps/ish 下用 iSH 自己的宏环境展开，
// 丢进 Xcode 的 Swift 工程里编会和 Darwin 的同名结构体撞（termios/stat/rlimit）。
#include "kernel/fs.h"       // fs_ops / do_mount / generic_* / adhoc_fd_create
#include "kernel/init.h"     // mount_root / become_first_process / create_stdio
#include "kernel/calls.h"    // do_execve
#include "kernel/task.h"     // current / task_start / task_run_current / exit_hook
#include "kernel/signal.h"   // send_signal / SIGKILL_ / SIGINFO_NIL
#include "kernel/errno.h"    // _EIO / _ENOMEM …
#include "fs/devices.h"      // MEM_MAJOR / TTY_*_MAJOR / DEV_*_MINOR
#include "fs/dev.h"          // dev_make
#include "fs/path.h"         // AT_PWD
#include "fs/tty.h"          // struct tty / tty_input / tty_set_winsize / DEFINE_TTY_DRIVER
#include "fs/fd.h"           // fd_retain / fd_close
#include "fs/real.h"         // realfs_fdops
#include "debug.h"           // die_handler

#define NPC_MAX_WAIT      8
#define NPC_ROOT_MAX      1024
#define NPC_ERR_MAX       512
#define NPC_STDIO_PATH    64

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static npc_out_cb g_cb = NULL;
static void *g_cb_ctx = NULL;

static char g_root[NPC_ROOT_MAX];
static char g_err[NPC_ERR_MAX];

static volatile int g_alive = 0;      // init 已经跑起来（task_run_current 之前置 1）
static volatile int g_ready = 0;      // 已用 /bin/true 真测过
static volatile int g_probing = 0;
static volatile int g_boot_started = 0;   // mount + exec 都做完了
static volatile int g_boot_err = 0;       // 启动阶段失败的错误码

// 交互会话
static struct tty *g_session_tty = NULL;   // pty slave（用于 tty_input / winsize）
static int g_session_pid = 0;
static volatile int g_session_dead = 1;

// exec 等待槽位。exit_hook 在 guest 线程里跑（持有 pids_lock），
// 这里只用我们自己的锁，绝不能碰 pids_lock，否则死锁。
struct npc_wait {
    int used;
    int pid;
    int done;
    int code;
};
static struct npc_wait g_waits[NPC_MAX_WAIT];
static pthread_mutex_t g_wait_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_wait_c = PTHREAD_COND_INITIALIZER;

static const char *kVersion = "iSH ARM64 内核 / NpcLab 集成层 2.0 (kernel=ish)";

// ---------------------------------------------------------------------------
// 小块工具
// ---------------------------------------------------------------------------

static void set_err(const char *msg) {
    pthread_mutex_lock(&g_lock);
    snprintf(g_err, sizeof(g_err), "%s", msg ? msg : "");
    pthread_mutex_unlock(&g_lock);
}

// iSH 的 die() 是 noreturn：默认 handler 打印完就 abort()。我们接管它。
//
// 不能 abort —— 那会把整个 App 带走，用户只看到闪退什么都不知道。
// 用 pthread_exit 让**当前内核线程**退出：错误留在 g_err 里，上层还能显示。
// （die 的调用点几乎都在 guest 线程或 boot 线程，pthread_exit 能干净退出。）
static void npc_die_handler(const char *msg) {
    set_err(msg ? msg : "kernel die");
    fprintf(stderr, "NpcLab: kernel die: %s\n", msg ? msg : "");
    pthread_exit(NULL);
}

// ---------------------------------------------------------------------------
// 纯 C 的 tty driver
//
// 替代 app/Terminal.m 里那段 ObjC 的 ios_tty_ops。kernel=ish 的 tty 接口就三个
//  回调：init / write / cleanup。
//
//  方向要搞清楚（很容易反）：
//    driver->ops->write  ← guest 往 tty 写（输出），由 fs/tty.c:tty_write() 调
//    tty_input(tty, ...) ← App 往 guest 送键盘（输入），我们直接调
// ---------------------------------------------------------------------------

struct npc_tty {
    int num;
    int is_console;
};

static int npc_tty_init(struct tty *tty) {
    struct npc_tty *t = calloc(1, sizeof(*t));
    if (!t)
        return _ENOMEM;
    t->num = (int) tty->num;
    t->is_console = (tty->type == TTY_CONSOLE_MAJOR);
    tty->data = t;
    return 0;
}

static int npc_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) blocking;
    if (!buf || len == 0)
        return 0;

    struct npc_tty *t = tty->data;

    // console 的输出（pid 1 那套）只留在日志里，别混进终端页。
    // 终端页显示的是 session 的 pty slave。
    if (t && t->is_console)
        return (int) len;

    npc_out_cb cb = g_cb;
    void *ctx = g_cb_ctx;
    if (cb)
        cb((const char *) buf, (int) len, ctx);
    return (int) len;
}

static void npc_tty_cleanup(struct tty *tty) {
    free(tty->data);
    tty->data = NULL;
}

static const struct tty_driver_ops npc_tty_ops = {
    .init = npc_tty_init,
    .write = npc_tty_write,
    .cleanup = npc_tty_cleanup,
    // .open / .close / .ioctl 故意留空：
    //   open  空着 → 不用检查 pty 的 locked 标志（pty_slave_open 才会检查，
    //                而 pty_open_fake 默认把 slave 设成 locked，走那条路会 EIO）
    //   ioctl 空着 → TIOCSWINSZ 之类落到 tty.c 的通用实现
};

// console 驱动必须注册进 tty_drivers[]，create_stdio("/dev/console") 会查它
DEFINE_TTY_DRIVER(npc_console_driver, &npc_tty_ops, TTY_CONSOLE_MAJOR, 64);

// pty slave 的驱动。不注册到 tty_drivers[]（那个位置留给 pty_slave），
// 只作为 pty_open_fake() 的参数传进去 —— pty_open_fake 会把 ttys 表指向
// pty_slave.ttys，于是 /dev/pts/N 打开时拿到的是我们这套 ops。
static struct tty_driver npc_pty_driver = {
    .ops = &npc_tty_ops,
};

// ---------------------------------------------------------------------------
// exit_hook：guest 进程退出时被调（kernel/exit.c:222）
//
// 注意调用点持有 pids_lock，这里绝对不能调任何要 pids_lock 的东西
// （pid_get_task / send_signal / task_* 全都不行）。只做记录 + 唤醒。
// ---------------------------------------------------------------------------

static void npc_exit_hook(struct task *task, int code) {
    int pid = (int) task->pid;

    // 1. 唤醒 exec 的等待者。这里只碰 g_wait_m。
    pthread_mutex_lock(&g_wait_m);
    for (int i = 0; i < NPC_MAX_WAIT; i++) {
        if (g_waits[i].used && g_waits[i].pid == pid) {
            g_waits[i].done = 1;
            g_waits[i].code = code;
            break;
        }
    }
    pthread_cond_broadcast(&g_wait_c);
    pthread_mutex_unlock(&g_wait_m);

    // 2. 会话状态归 g_lock 管。两把锁不嵌套，避免和 session_tty_retain
    //    （g_lock → tty->lock）凑出环。
    pthread_mutex_lock(&g_lock);
    if (g_session_pid != 0 && pid == g_session_pid) {
        g_session_dead = 1;
        // 进程退出后三个 stdio fd 会被关，pty slave 的 refcount 归零 →
        // 内核 free(tty)。这里必须清指针，否则 session_write 会拿着悬垂
        // 指针去 tty_input。已经 retain 住的调用方不受影响（refcount 还 >0）。
        g_session_tty = NULL;
        g_session_pid = 0;
    }
    pthread_mutex_unlock(&g_lock);
}

// 占一个等待槽位。调用方必须在 task_start 之前 arm，避免进程跑太快退出时
// exit_hook 找不到对应槽位。
static int wait_alloc(int pid) {
    pthread_mutex_lock(&g_wait_m);
    int slot = -1;
    for (int i = 0; i < NPC_MAX_WAIT; i++) {
        if (!g_waits[i].used) { slot = i; break; }
    }
    if (slot >= 0) {
        g_waits[slot].used = 1;
        g_waits[slot].pid = pid;
        g_waits[slot].done = 0;
        g_waits[slot].code = -1;
    }
    pthread_mutex_unlock(&g_wait_m);
    return slot;
}

static void wait_free(int slot) {
    if (slot < 0) return;
    pthread_mutex_lock(&g_wait_m);
    g_waits[slot].used = 0;
    pthread_mutex_unlock(&g_wait_m);
}

// 等槽位就绪。deadline 是 CLOCK_REALTIME 绝对时间；返回 1 拿到结果 / 0 超时
static int wait_for(int slot, const struct timespec *deadline) {
    if (slot < 0) return 0;
    int ok = 0;
    pthread_mutex_lock(&g_wait_m);
    while (!g_waits[slot].done) {
        if (deadline == NULL) {
            pthread_cond_wait(&g_wait_c, &g_wait_m);
        } else if (pthread_cond_timedwait(&g_wait_c, &g_wait_m, deadline) == ETIMEDOUT) {
            break;
        }
    }
    if (g_waits[slot].done) {
        ok = 1;
        g_waits[slot].done = 2;   // 交回结果，避免重复取
    }
    pthread_mutex_unlock(&g_wait_m);
    return ok;
}

static int wait_code(int slot) {
    if (slot < 0) return -1;
    pthread_mutex_lock(&g_wait_m);
    int c = g_waits[slot].code;
    pthread_mutex_unlock(&g_wait_m);
    return c;
}

static void deadline_from_now(struct timespec *ts, double seconds) {
    clock_gettime(CLOCK_REALTIME, ts);
    if (seconds <= 0) return;
    ts->tv_sec += (time_t) seconds;
    ts->tv_nsec += (long) ((seconds - (double) (time_t) seconds) * 1e9);
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_sec += 1;
        ts->tv_nsec -= 1000000000L;
    }
}

// ---------------------------------------------------------------------------
// 环境变量
//
// 格式跟 do_execve 的要求一致：NUL 分隔，末尾双 NUL。数组字面量的最后一个
// "\0" 保证双 NUL 结尾。
// ---------------------------------------------------------------------------

static const char kEnv[] =
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
    "HOME=/root\0"
    "TERM=xterm-256color\0"
    "LANG=C.UTF-8\0"
    "SHELL=/bin/sh\0"
    "ENV=/etc/profile\0"
    "PYTHONMALLOC=malloc\0"   // ARM64 guest：V8/CPython 在这套模拟器上更稳
    "\0";

// ---------------------------------------------------------------------------
// 设备节点 / 挂载点
//
// 全在 fakefs 上，写一次就永久留在 meta.db 里，重复 mknod 会返回 EEXIST，
// 忽略即可。所以这里不判返回值。
// ---------------------------------------------------------------------------

static void make_device_nodes(void) {
    const struct { const char *path; int major; int minor; } devs[] = {
        {"/dev/null",    MEM_MAJOR,           DEV_NULL_MINOR},
        {"/dev/zero",    MEM_MAJOR,           DEV_ZERO_MINOR},
        {"/dev/full",    MEM_MAJOR,           DEV_FULL_MINOR},
        {"/dev/random",  MEM_MAJOR,           DEV_RANDOM_MINOR},
        {"/dev/urandom", MEM_MAJOR,           DEV_URANDOM_MINOR},
        {"/dev/tty",     TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx",    TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
        {"/dev/tty1",    TTY_CONSOLE_MAJOR,   1},
    };
    for (size_t i = 0; i < sizeof(devs) / sizeof(devs[0]); i++)
        generic_mknodat(AT_PWD, devs[i].path, S_IFCHR | 0666,
                        dev_make(devs[i].major, devs[i].minor));

    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/proc", 0755);
    generic_mkdirat(AT_PWD, "/tmp", 01777);
}

// 把宿主 fd 包成 guest 的 struct fd。
// 注意 realfs_fdops 直接接管这个 host fd —— 不要在包完之后再 close 它。
static struct fd *wrap_host_fd(int host_fd) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (!fd) return NULL;
    fd->real_fd = host_fd;
    fd->flags = O_RDWR_;
    // guest 侧 stat 填成 pipe，免得 libuv/Node 把 stdout 当成 socket 后拒绝初始化
    fd->stat.mode = S_IFIFO | 0600;
    return fd;
}

// ---------------------------------------------------------------------------
// 内核启动
//
// 流程照抄 xX_main_Xx.h（CLI 的纯 C 启动路径），顺序不能乱：
//   mount_root → become_first_process → 设备节点 → exec → console → task_run
//
// 为什么 exec 在 create_stdio 之前：xX_main_Xx.h 就是这么排的，
// create_stdio 之后会重新填 fd 0/1/2，覆盖 exec 继承下来的那套。
// ---------------------------------------------------------------------------

// 启动阶段要用的 rootfs 数据目录（<rootfs>/data），由 boot 传进来
static char g_data_dir[NPC_ROOT_MAX];

static void *kernel_main(void *arg) {
    (void) arg;

    // ---- 1. 挂 fakefs ----
    // fakefs 的 fs_ops 要的是「含 data/ 和 meta.db 的那个目录 + /data」，
    // 不是 rootfs 根目录本身。传错就是 meta.db 找不到 → 挂载失败。
    int err = mount_root(&fakefs, g_data_dir);
    if (err < 0) {
        set_err("fakefs 挂载失败：检查 rootfs 下是否有 meta.db 和 data/");
        g_boot_err = err;
        goto boot_done;
    }

    // ---- 2. 变成 pid 1 之前的第一个进程 ----
    err = become_first_process();
    if (err < 0) {
        set_err("become_first_process 失败");
        g_boot_err = err;
        goto boot_done;
    }
    // 把 init task 绑到本线程（task_run_current 会在本线程跑它）
    current->thread = pthread_self();

    // ---- 3. 设备节点 + 伪文件系统 ----
    make_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // ---- 4. console ----
    // 必须在 create_stdio 之前注册，create_stdio 会 dev_open(TTY_CONSOLE_MAJOR, 1)
    tty_drivers[TTY_CONSOLE_MAJOR] = &npc_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);

    // ---- 5. exec pid 1 ----
    // pid 1 只用来看家：become_new_init_child() 要 pid_get_task(1)，
    // 没有它连子进程都起不来。stdio 接 /dev/null，别让它的输出干扰终端页。
    {
        struct fd *nullfd = generic_open("/dev/null", O_RDWR_, 0);
        if (!IS_ERR(nullfd)) {
            current->files->files[0] = fd_retain(nullfd);
            current->files->files[1] = fd_retain(nullfd);
            current->files->files[2] = fd_retain(nullfd);
            fd_close(nullfd);
        }
    }

    // pid 1 只用来看家：become_new_init_child() 要 pid_get_task(1)，没有它连
    // 子进程都起不来。所以让它常驻但不干活 —— 每 3600 秒醒一次重新睡，
    // 避免 sleep 参数过大被 busybox 拒绝。
    static const char kInitArgv[] =
        "/bin/sh\0-c\0trap 'exit 0' TERM INT; while :; do sleep 3600; done\0";
    err = do_execve("/bin/sh", 3, kInitArgv, kEnv);
    if (err < 0) {
        set_err("exec pid 1 失败：rootfs 里的 /bin/sh 可能不是 aarch64");
        g_boot_err = err;
        goto boot_done;
    }

    exit_hook = npc_exit_hook;
    die_handler = npc_die_handler;

    g_alive = 1;
    g_boot_err = 0;

boot_done:
    g_boot_started = 1;

    if (g_boot_err != 0) {
        // 启动失败就别进 task_run_current（那会 die）
        return NULL;
    }

    // ---- 6. 在当前线程跑 init ----
    // 这个函数不返回（除非 guest 进程退出），所以 kernel_main 走到这里就
    // 一直占着这个线程当 pid 1 的执行线程。
    task_run_current();

    g_alive = 0;
    set_err("task_run_current 意外返回");
    return NULL;
}

int npc_linux_boot(const char *rootfsPath) {
    if (g_alive || g_boot_started) return 0;
    if (!rootfsPath || !*rootfsPath) return -1;

    // 传进来的是 <...>/alpine-rootfs（含 meta.db + data/），
    // fakefs 要的是它下面的 data 子目录
    int n = snprintf(g_data_dir, sizeof(g_data_dir), "%s/data", rootfsPath);
    if (n < 0 || (size_t) n >= sizeof(g_data_dir)) return -2;

    // 校验 rootfs 结构，早点报错比在 kernel 里 die 好
    char probe[NPC_ROOT_MAX];
    snprintf(probe, sizeof(probe), "%s/meta.db", rootfsPath);
    if (access(probe, R_OK) != 0) {
        set_err("rootfs 下没有 meta.db —— 解压目录不对");
        return -2;
    }

    n = snprintf(g_root, sizeof(g_root), "%s", rootfsPath);
    if (n < 0 || (size_t) n >= sizeof(g_root)) return -2;

    g_boot_started = 0;
    g_boot_err = 0;

    pthread_t th;
    if (pthread_create(&th, NULL, kernel_main, NULL) != 0) {
        set_err("内核线程创建失败");
        return -3;
    }
    pthread_detach(th);

    // 等 mount + exec 做完。给 20 秒（fakefs 首次打开 meta.db 要建索引，慢）。
    for (int i = 0; i < 400; i++) {
        if (g_boot_started) break;
        usleep(50 * 1000);
    }
    if (!g_boot_started) {
        set_err("内核 20 秒内没启动完成");
        return -4;
    }
    if (g_boot_err != 0)
        return -5;

    // 再给子进程调度一点余量，然后放行
    usleep(100 * 1000);
    return 0;
}

// 真探活：跑一次 /bin/true。第一次进终端页调它，没就绪就由上层轮询重试。
int npc_linux_ready(void) {
    if (!g_alive) return 0;
    if (g_ready) return 1;
    if (g_probing) return 0;

    g_probing = 1;
    char *out = NULL;
    int len = 0, rc = -1;
    if (npc_linux_exec("true", 3.0, &out, &len, &rc) == 0 && rc == 0)
        g_ready = 1;
    if (out) free(out);
    g_probing = 0;
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
// 非交互执行
//
// 模型（照抄 app/ISHShellExecutor.m 的 kernel=ish 分支）：
//   become_new_init_child() → 装 stdio（stdout/stderr 接宿主 pipe）
//   → do_execve → task_start → 从 pipe 读到 EOF → 等 exit_hook 拿退出码
//
// 注意 current 是 thread-local。become_new_init_child() 会把**本线程**的
// current 设成新 task，task_start 之后必须恢复，否则 App 线程后续任何
// 内核调用都会拿着一个已经在跑的 task，行为不可预测。
// ---------------------------------------------------------------------------

// 从 pipe 读到 EOF 或超时。返回读到的字节数，-1 表示超时前没读到 EOF。
static int drain_pipe(int rfd, char **out, size_t *outLen, const struct timespec *deadline) {
    size_t cap = 8192, len = 0;
    char *buf = malloc(cap);
    if (!buf) return -1;
    buf[0] = 0;

    for (;;) {
        struct timeval tv;
        if (deadline) {
            struct timespec now;
            clock_gettime(CLOCK_REALTIME, &now);
            long long us = (long long)(deadline->tv_sec - now.tv_sec) * 1000000LL
                         + (deadline->tv_nsec - now.tv_nsec) / 1000;
            if (us <= 0) { free(buf); return -1; }
            tv.tv_sec = (time_t)(us / 1000000);
            tv.tv_usec = (suseconds_t)(us % 1000000);
        } else {
            tv.tv_sec = 1;
            tv.tv_usec = 0;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(rfd, &rfds);
        int sel = select(rfd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return -1;
        }
        if (sel == 0) {
            if (deadline) { free(buf); return -1; }
            continue;
        }

        if (len + 4096 + 1 > cap) {
            size_t want = cap * 2;
            while (want < len + 4096 + 1) want *= 2;
            char *p = realloc(buf, want);
            if (!p) { free(buf); return -1; }
            buf = p;
            cap = want;
        }
        ssize_t got = read(rfd, buf + len, cap - len - 1);
        if (got < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            break;
        }
        if (got == 0) break;   // EOF
        len += (size_t) got;
    }

    buf[len] = 0;
    *out = buf;
    *outLen = len;
    return (int) len;
}

// 超时后把 guest 进程干掉。每个 guest 进程占着 ~350KB 的 TLB + fiber_frame，
// 不杀的话反复超时会一路吃内存（iSH 的 exit.c 注释里也强调了这点）。
static void npc_kill_pid(int pid) {
    if (pid <= 0) return;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t) pid);
    if (task != NULL)
        send_signal(task, SIGKILL_, SIGINFO_NIL);
    unlock(&pids_lock);
}

int npc_linux_exec(const char *cmd, double timeout,
                   char **out, int *outLen, int *exitCode) {
    if (!cmd) return -1;
    if (!g_alive) return -1;

    int p[2];
    if (pipe(p) < 0) return -3;
    fcntl(p[0], F_SETFL, O_NONBLOCK);

    struct timespec deadline;
    deadline_from_now(&deadline, timeout);

    struct task *saved = current;      // App 线程这里是 NULL
    if (become_new_init_child() < 0) {
        close(p[0]); close(p[1]);
        current = saved;
        return -3;
    }
    struct task *task = current;
    int pid = (int) task->pid;

    // stdin = /dev/null
    int nullfd = open("/dev/null", O_RDONLY);
    if (nullfd >= 0) {
        struct fd *in = wrap_host_fd(nullfd);
        if (in) task->files->files[0] = in;
        else close(nullfd);
    }

    // stdout / stderr = pipe 写端。
    // 必须各 dup 一份：wrap_host_fd 是「接管」语义，fd 关闭时会 close 掉
    // real_fd。如果直接把 p[1] 交给 fd，父进程再 close(p[1]) 就会让 guest
    // 手里的 fd 变成 EBADF；反过来不 close(p[1]) 又永远等不到 EOF。
    int o_fd = dup(p[1]);
    struct fd *o = (o_fd >= 0) ? wrap_host_fd(o_fd) : NULL;
    if (o) task->files->files[1] = o; else if (o_fd >= 0) close(o_fd);
    int e_fd = dup(p[1]);
    struct fd *e = (e_fd >= 0) ? wrap_host_fd(e_fd) : NULL;
    if (e) task->files->files[2] = e; else if (e_fd >= 0) close(e_fd);

    // argv："/bin/sh\0-c\0<cmd>\0\0"
    size_t need = strlen(cmd) + 32;
    char *argvBuf = malloc(need);
    if (!argvBuf) {
        close(p[0]); close(p[1]);
        current = saved;
        return -3;
    }
    size_t pos = 0;
    memcpy(argvBuf + pos, "/bin/sh", 8); pos += 8;
    memcpy(argvBuf + pos, "-c", 3);      pos += 3;
    size_t clen = strlen(cmd) + 1;
    memcpy(argvBuf + pos, cmd, clen);    pos += clen;
    argvBuf[pos] = 0;

    int err = do_execve("/bin/sh", 3, argvBuf, kEnv);
    free(argvBuf);
    if (err < 0) {
        close(p[0]); close(p[1]);
        current = saved;
        return -3;
    }

    // 先 arm 再 start：进程可能瞬间就退出，exit_hook 来早了就收不到
    int slot = wait_alloc(pid);
    task_start(task);
    current = saved;                   // 恢复 App 线程的 current（NULL）

    // 父进程必须关掉写端，否则 read 永远等不到 EOF
    close(p[1]);

    char *body = NULL;
    size_t bodyLen = 0;
    int drainRc = drain_pipe(p[0], &body, &bodyLen, timeout > 0 ? &deadline : NULL);
    close(p[0]);

    int timedOut = (drainRc < 0);
    int rc = -1;
    if (!timedOut) {
        if (wait_for(slot, timeout > 0 ? &deadline : NULL))
            rc = wait_code(slot);
        else
            timedOut = 1;
    }
    wait_free(slot);

    if (!body) {
        body = malloc(1);
        bodyLen = 0;
    }
    if (body) body[bodyLen] = 0;

    if (out) *out = body; else free(body);
    if (outLen) *outLen = (int) bodyLen;
    if (exitCode) *exitCode = timedOut ? -1 : rc;

    if (timedOut) {
        set_err("命令超时");
        npc_kill_pid(pid);   // 别把进程留在后台吃内存
        return -2;
    }
    return 0;
}

void npc_linux_free(char *p) { free(p); }

// ---------------------------------------------------------------------------
// 交互会话（pty + /bin/sh -i）
//
// 流程照抄 app/TerminalViewController.m 的 kernel=ish 分支：
//   become_new_init_child → pty_open_fake → create_stdio("/dev/pts/N")
//   → do_execve → task_start
//
// 数据流：
//   输出  guest 写 pts/N → fs/tty.c:tty_write → npc_tty_ops.write → npc_out_cb
//   输入  App → tty_input(slave, bytes) → 进 slave 的输入缓冲 → guest read()
//
// 注意 pty_open_fake 把 npc_pty_driver.ttys 指向 pty_slave.ttys，
// 所以 /dev/pts/N 打开时拿到的 tty->driver 就是我们这套 ops（open 为空，
// 绕过 pty_slave_open 的 locked 检查）。
// ---------------------------------------------------------------------------

int npc_linux_session_open(void) {
    if (!g_alive) return -1;

    pthread_mutex_lock(&g_lock);
    int already = (g_session_tty != NULL && !g_session_dead);
    pthread_mutex_unlock(&g_lock);
    if (already) return 0;

    struct task *saved = current;
    if (become_new_init_child() < 0) {
        current = saved;
        return -2;
    }
    struct task *task = current;
    int pid = (int) task->pid;

    struct tty *tty = pty_open_fake(&npc_pty_driver);
    if (IS_ERR(tty)) {
        current = saved;
        return -2;
    }

    char stdioPath[NPC_STDIO_PATH];
    snprintf(stdioPath, sizeof(stdioPath), "/dev/pts/%d", tty->num);

    // create_stdio 内部会 generic_open("/dev/pts/N") → tty_get，refcount 变 2，
    // 并把 tty 设成这个进程的控制终端（tty_open 里 sid == pid 时自动做）
    if (create_stdio(stdioPath, TTY_PSEUDO_SLAVE_MAJOR, (int) tty->num) < 0) {
        tty_release(tty);
        current = saved;
        return -2;
    }

    static const char kShellArgv[] = "/bin/sh\0-i\0";
    int err = do_execve("/bin/sh", 2, kShellArgv, kEnv);
    if (err < 0) {
        tty_release(tty);
        current = saved;
        return -2;
    }

    // 这里必须先把句柄交出去、把 pty_open_fake 那份引用还掉，再 task_start。
    // 反过来的话：进程可能瞬间退出 → exit_hook 清 g_session_tty → 我们再
    // tty_release 就是对已 free 的 tty 操作。
    // 还掉之后 refcount = 1（fd 那份），tty 由 guest 的 stdio fd 保活；
    // 进程退出时 fd 关闭 → refcount 归零 → 内核回收。
    pthread_mutex_lock(&g_lock);
    g_session_tty = tty;
    g_session_pid = pid;
    g_session_dead = 0;
    pthread_mutex_unlock(&g_lock);

    tty_release(tty);

    task_start(task);
    current = saved;
    return 0;
}

int npc_linux_session_alive(void) {
    pthread_mutex_lock(&g_lock);
    int alive = (g_session_tty != NULL) && !g_session_dead;
    pthread_mutex_unlock(&g_lock);
    return alive;
}

// 取 session tty 并临时加一份引用，避免 exit_hook 在我们用它的同时把
// refcount 放掉导致 tty 被 free。用完必须 tty_release。
static struct tty *session_tty_retain(void) {
    pthread_mutex_lock(&g_lock);
    struct tty *t = g_session_tty;
    if (t != NULL && !g_session_dead) {
        lock(&t->lock);
        t->refcount++;
        unlock(&t->lock);
    } else {
        t = NULL;
    }
    pthread_mutex_unlock(&g_lock);
    return t;
}

int npc_linux_session_write(const char *bytes, int len) {
    if (!bytes || len <= 0) return -1;
    struct tty *tty = session_tty_retain();
    if (!tty) return -1;

    // tty_input 是「App 侧送键盘」的入口。blocking=false：终端页不能卡在
    // 内核缓冲满的时候，宁可丢几个按键。
    ssize_t n = tty_input(tty, bytes, (size_t) len, false);
    tty_release(tty);
    return (n < 0) ? -1 : (int) n;
}

int npc_linux_session_resize(int cols, int rows) {
    struct tty *tty = session_tty_retain();
    if (!tty) return -1;

    struct winsize_ ws = {
        .row = (word_t) rows,
        .col = (word_t) cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    // tty_set_winsize 内部会给前台进程组发 SIGWINCH（fs/tty.c:792），
    // 这里不用自己发 —— 而且 tty->session 是个 pid，不是 task 指针。
    tty_set_winsize(tty, ws);
    tty_release(tty);
    return 0;
}
