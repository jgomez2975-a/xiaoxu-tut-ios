//
//  NpcBoot.c
//  libiSHApp
//
//  内核初始化完成的信号灯。
//
//  为什么需要它：App 侧要往内核里投 block（跑命令、开 shell）只能走
//  async_do_in_workqueue → async_do_in_irq，而后者依赖 subsys_initcall 里
//  建好的那对 pipe。initcall 没跑完就投，host_write 失败会 __builtin_trap()，
//  也就是 SIGILL——进程当场没，连 crash 日志都只有一条 "Illegal instruction"。
//
//  这个 late_initcall 排在所有 initcall 之后、pid 1 起来之前跑，把标志置 1。
//  NpcLinux.c 的 npc_linux_boot() 就靠它判断"现在能不能碰内核"。
//

#include <linux/init.h>

// 定义在 NpcLab/Core/NpcLinux.c
extern volatile int npc_kernel_init_flag;

static int __init npc_boot_marker(void) {
    npc_kernel_init_flag = 1;
    return 0;
}

// 用 late_initcall 而不是 module_init：level 6/7 是最后一批，
// 此时 pty、devpts、block 通道都已经就绪。
late_initcall(npc_boot_marker);
