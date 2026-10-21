/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * kpgcmem v27 - ctl0 直写用户预触缓冲区
 *
 * v26 发现：SUPERCALL_KPM_CONTROL 在内核侧只映射到 module_control0，
 *           ctl1 没有 supercall 入口，调不到。
 * v25 发现：ctl0 内 compat_copy_to_user(out_msg, data, 32) 只写出 1 字节。
 *           原因推测：out_msg 是 kpatch 的用户栈缓冲，RCU 上下文首访缺页不安全。
 *
 * 本版方案：沿用 ctl0，但把用户态「已 mmap + memset 预触」的缓冲区指针
 *           编码进 ctl_args，KPM 直接写那块常驻页，绕开缺页问题。
 *
 * 参数格式：
 *   R,<pid>,<hexaddr>,<len>,<hexptr>    读 len 字节写入 hexptr，返回 W<bytes>
 *   W,<pid>,<hexaddr>,<hexdata>         写
 *   V                                   版本
 */
#include <compiler.h>
#include <kpmodule.h>
#include <linux/printk.h>
#include <common.h>
#include <kputils.h>
#include <linux/string.h>
#include <ktypes.h>
#include <ksyms.h>
#include <log.h>

KPM_NAME("kpgcmem");
KPM_VERSION("27.0.0");
KPM_LICENSE("GPL v2");
KPM_AUTHOR("lcs");
KPM_DESCRIPTION("kernel cross-process r/w, ctl0 with user pinned buffer");

typedef struct task_struct_fwd task_t;
typedef struct mm_struct_fwd mm_t;

typedef task_t *(*fn_find_task_t)(int nr);
typedef mm_t *(*fn_get_task_mm_t)(task_t *t);
typedef void (*fn_mmput_t)(mm_t *mm);
typedef int (*fn_apvm_t)(task_t *tsk, unsigned long addr, void *buf,
                         int len, unsigned int write);

static fn_find_task_t kf_find_task;
static fn_get_task_mm_t kf_get_task_mm;
static fn_mmput_t kf_mmput;
static fn_apvm_t kf_apvm;

#define MAX_XFER 4096

static void sk(const char **pp) { while (**pp == ',' || **pp == ' ') (*pp)++; }

static u64 px(const char **pp)
{
    u64 v = 0; const char *p = *pp;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    for (;;) {
        char c = *p; u32 d;
        if (c >= '0' && c <= '9') d = (u32)(c - '0');
        else if (c >= 'a' && c <= 'f') d = (u32)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = (u32)(c - 'A' + 10);
        else break;
        v = (v << 4) | d; p++;
    }
    *pp = p; return v;
}
static int pd(const char **pp)
{
    int v = 0; const char *p = *pp;
    while (*p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); p++; }
    *pp = p; return v;
}
static int hv(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static void ps(char *d, int *pn, const char *s) { while (*s) d[(*pn)++] = *s++; }
static void putnum(char *d, int *pn, long v)
{
    char b[24]; int bn = 0, i, n = *pn;
    if (v < 0) { d[n++] = '-'; v = -v; }
    do { b[bn++] = (char)('0' + v % 10); v /= 10; } while (v && bn < 20);
    for (i = bn - 1; i >= 0; i--) d[n++] = b[i];
    *pn = n;
}

/* 读：结果直接写入用户指针 ubuf */
static long do_read(int pid, u64 addr, u32 len, u64 ubuf)
{
    task_t *t;
    mm_t *mm;
    u8 tmp[MAX_XFER];
    u32 done = 0;

    if (len == 0 || len > MAX_XFER) return -1;
    if (!ubuf) return -1;

    t = kf_find_task(pid);
    if (!t) return -2;
    mm = kf_get_task_mm(t);
    if (!mm) return -4;

    while (done < len) {
        u32 n = len - done;
        int r;
        if (n > MAX_XFER) n = MAX_XFER;
        r = kf_apvm(t, (unsigned long)(addr + done), tmp, (int)n, 0); logki("kpgc27: apvm_read r=%d n=%u\n", r, n);
        if (r <= 0) break;
        int cp = compat_copy_to_user((void __user *)(uintptr_t)(ubuf + done), tmp, r); logki("kpgc27: copy r=%d cp=%d\n", r, cp); if (cp <= 0) break;
        done += (u32)r;
        if ((u32)r < n) break;
    }

    kf_mmput(mm);
    return done ? (long)done : -3;
}

static long do_write(int pid, u64 addr, const char *hex)
{
    task_t *t;
    mm_t *mm;
    u8 data[MAX_XFER];
    u32 len = 0, done = 0;

    while (hex[0] && hex[1] && len < MAX_XFER) {
        int hi = hv(hex[0]), lo = hv(hex[1]);
        if (hi < 0 || lo < 0) break;
        data[len++] = (u8)((hi << 4) | lo);
        hex += 2;
    }
    if (!len) return -3;

    t = kf_find_task(pid);
    if (!t) return -2;
    mm = kf_get_task_mm(t);
    if (!mm) return -4;

    while (done < len) {
        u32 n = len - done;
        int r;
        if (n > MAX_XFER) n = MAX_XFER;
        r = kf_apvm(t, (unsigned long)(addr + done), data + done, (int)n, 1);
        if (r <= 0) break;
        done += (u32)r;
        if ((u32)r < n) break;
    }

    kf_mmput(mm);
    return (long)done;
}

static long kpgcmem_ctl0(const char *ctl_args, char *__user out_msg, int outlen)
{
    char resp[64];
    int n = 0;
    const char *p = ctl_args;

    if (!p || !*p) { ps(resp, &n, "E"); resp[n] = 0;
        compat_copy_to_user(out_msg, resp, n); return 0; }
    sk(&p);

    if (*p == 'R' || *p == 'r') {
        int pid; u64 addr, ubuf; u32 len; long r;
        p++; sk(&p);
        pid = pd(&p); sk(&p);
        addr = px(&p); sk(&p);
        len = (u32)pd(&p); sk(&p);
        ubuf = px(&p);

        r = do_read(pid, addr, len, ubuf);
        n = 0; ps(resp, &n, "R"); putnum(resp, &n, r); resp[n] = 0;

    } else if (*p == 'W' || *p == 'w') {
        int pid; u64 addr; long r;
        p++; sk(&p);
        pid = pd(&p); sk(&p);
        addr = px(&p); sk(&p);
        r = do_write(pid, addr, p);
        n = 0; ps(resp, &n, "W"); putnum(resp, &n, r); resp[n] = 0;

    } else if (*p == 'V' || *p == 'v') {
        ps(resp, &n, "v27"); resp[n] = 0;

    } else {
        ps(resp, &n, "E"); resp[n] = 0;
    }

    compat_copy_to_user(out_msg, resp, n);
    return 0;
}

static long kpgcmem_init(const char *args, const char *event, void *__user reserved)
{
    kf_find_task = (fn_find_task_t)kallsyms_lookup_name("find_get_task_by_vpid");
    if (!kf_find_task) kf_find_task = (fn_find_task_t)kallsyms_lookup_name("find_task_by_vpid");
    kf_get_task_mm = (fn_get_task_mm_t)kallsyms_lookup_name("get_task_mm");
    kf_mmput = (fn_mmput_t)kallsyms_lookup_name("mmput");
    kf_apvm = (fn_apvm_t)kallsyms_lookup_name("access_process_vm");

    logki("kpgc27: init apvm=%px\n", kf_apvm);
    if (!kf_find_task || !kf_get_task_mm || !kf_mmput || !kf_apvm) return -1;
    logki("kpgc27: ready\n");
    return 0;
}

static long kpgcmem_exit(void *__user reserved) { logki("kpgc27: exit\n"); return 0; }

KPM_INIT(kpgcmem_init);
KPM_CTL0(kpgcmem_ctl0);
KPM_EXIT(kpgcmem_exit);
