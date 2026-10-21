// kpmrw - 单进程内直接 supercall，缓冲区指针在本进程有效
//   kpmrw <pid> <hexaddr> <len>
//   kpmrw <pid> <hexaddr> W <hex>
//   kpmrw --selftest
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/syscall.h>

#define __NR_supercall        45
#define SUPERCALL_HELLO       0x1000
#define SUPERCALL_KPM_CONTROL 0x1022
#define SUPERCALL_HELLO_MAGIC 0x20262026UL

#define BUF_SIZE  (4 * 4096)
#define MAX_XFER  4096

/* KPatch 0.13.5 -> MAJOR=0 MINOR=13 PATCH=5 -> version_code = 0x000d05 */
#define KP_VER_CODE 0x000d05

static long ver_and_cmd(long cmd)
{
    return ((long)KP_VER_CODE << 32) | (0x2026 << 16) | (cmd & 0xFFFF);
}

static long sc_hello(void)
{
    return syscall(__NR_supercall, (void *)0, ver_and_cmd(SUPERCALL_HELLO));
}

static long sc_kpm_control(const char *name, const char *ctl_args,
                           char *out_msg, long outlen)
{
    return syscall(__NR_supercall, (void *)0, ver_and_cmd(SUPERCALL_KPM_CONTROL),
                   name, ctl_args, out_msg, outlen);
}

int main(int argc, char **argv)
{
    if (sc_hello() != (long)SUPERCALL_HELLO_MAGIC) {
        fprintf(stderr, "KPatch supercall not available\n");
        return 1;
    }

    unsigned char *buf = mmap(NULL, BUF_SIZE, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { perror("mmap"); return 1; }
    memset(buf, 0, BUF_SIZE);
    mlock(buf, BUF_SIZE);

    if (argc >= 2 && strcmp(argv[1], "--selftest") == 0) {
        char out[128] = {0};
        long r = sc_kpm_control("kpgcmem", "V", out, sizeof(out) - 1);
        printf("buf=%p hello=%lx ctl=%ld ver=%s\n",
               (void *)buf, sc_hello(), r, out);
        return 0;
    }

    if (argc < 4) {
        fprintf(stderr, "usage: %s <pid> <hexaddr> <len>\n", argv[0]);
        fprintf(stderr, "       %s <pid> <hexaddr> W <hex>\n", argv[0]);
        return 1;
    }

    int pid = atoi(argv[1]);
    unsigned long addr = strtoul(argv[2], NULL, 16);
    int is_write = (argc >= 5 && (argv[3][0] == 'W' || argv[3][0] == 'w'));

    char args[400];
    char out[256] = {0};

    if (is_write) {
        snprintf(args, sizeof(args), "W,%d,0x%lx,%s", pid, addr, argv[4]);
    } else {
        uint32_t len = (uint32_t)strtoul(argv[3], NULL, 0);
        if (len > MAX_XFER) len = MAX_XFER;
        snprintf(args, sizeof(args), "R,%d,0x%lx,%u,0x%lx",
                 pid, addr, len, (unsigned long)(uintptr_t)buf);
    }

    long r = sc_kpm_control("kpgcmem", args, out, sizeof(out) - 1);
    if (r < 0) {
        fprintf(stderr, "ctl failed: %ld errno=%d(%s)\n", r, errno, strerror(errno));
        return 1;
    }

    if (is_write) {
        printf("%s\n", out);
        return 0;
    }

    if (out[0] != 'R') { printf("ERR: %s\n", out); return 1; }
    long n = atol(out + 1);
    if (n <= 0) { printf("ERR: %s\n", out); return 1; }
    for (long i = 0; i < n; i++) printf("%02x", buf[i]);
    printf("\n");

    munmap(buf, BUF_SIZE);
    return 0;
}
