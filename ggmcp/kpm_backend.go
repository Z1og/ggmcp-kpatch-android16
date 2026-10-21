// kpm_backend.go - ggmcp 的 KPatch-Next KPM 内核读写后端
//
// 适配背景（本机 OPD2513 / Android 16 / kernel 6.12.58 GKI 实测）：
//   - 原 MemoryDriver 协议（socket + ioctl 0x7e1a/0x7e1b）依赖 __ioremap()，
//     6.12 GKI 已移除该符号，社区驱动全部加载失败。
//   - 本后端改用自研 KPM「kpgcmem」，其内核侧走 access_process_vm()，
//     不依赖 __ioremap、不手工遍历页表、不触碰 mmap_lock。
//   - 用户态通道：KPatch supercall 45 的 SUPERCALL_KPM_CONTROL，
//     参数 "R,<pid>,<hexaddr>,<len>,<hex_ubuf>" / "W,<pid>,<hexaddr>,<hex>"。
//
// 关键坑位（都已踩过并验证）：
//   1. SUPERCELL_KPM_CONTROL 在内核侧只映射到 module_control0，ctl1 无入口。
//   2. ctl0 回调持 rcu_read_lock()，回调内不能睡眠。
//   3. compat_copy_to_user() 返回「成功复制的字节数」，不是 0/1 状态码；
//      写成 `!= 0` 判断会导致永远判定失败。
//   4. out_msg 缓冲需 ≤ 64 字节，大数据走用户态预触缓冲区（mmap + memset + mlock）。

package main

import (
	"errors"
	"fmt"
	"sync"
	"syscall"
	"unsafe"
)

const (
	kpSupercallNr       = 45
	kpCmdHello       = 0x1000
	kpSupercallKpmCtl   = 0x1022
	kpHelloMagic        = 0x20262026
	kpVerCode           = 0x000d05 // KPatch 0.13.5
	kpmXferBufSize      = 4 * 4096
	kpmMaxXfer          = 4096
	kpmModuleName       = "kpgcmem"
)

// kpXferBuf 用户态预触缓冲区：KPM 直接写入此地址。
// 必须整页 memset 并 mlock，确保页常驻 —— ctl0 处于 RCU 上下文，触发缺页不安全。
var (
	kpXferOnce sync.Once
	kpXferBuf  []byte
	kpXferErr  error
)

func kpXferBuffer() ([]byte, error) {
	kpXferOnce.Do(func() {
		b, err := syscall.Mmap(-1, 0, kpmXferBufSize,
			syscall.PROT_READ|syscall.PROT_WRITE,
			syscall.MAP_PRIVATE|syscall.MAP_ANON)
		if err != nil {
			kpXferErr = fmt.Errorf("mmap xfer buf: %w", err)
			return
		}
		// 预触所有页
		for i := 0; i < len(b); i += 4096 {
			b[i] = 0
		}
		// 尽力锁定（失败不致命）
		_ = syscall.Mlock(b)
		kpXferBuf = b
	})
	return kpXferBuf, kpXferErr
}

func kpVerAndCmd(cmd int) uintptr {
	v := (uintptr(kpVerCode) << 32) | (0x2026 << 16) | uintptr(cmd&0xFFFF)
	return v
}

// kpSupercallHello 检测 KPatch supercall 是否可用
func kpHelloOK() bool {
	r, _, _ := syscall.Syscall(kpSupercallNr, 0, kpVerAndCmd(kpCmdHello), 0)
	return uint32(r) == kpHelloMagic
}

// kpKpmCtl 调用 KPM ctl0，返回内核写入 out 的内容
func kpKpmCtl(args string) (string, error) {
	out := make([]byte, 128)
	argsPtr, err := syscall.BytePtrFromString(args)
	if err != nil {
		return "", err
	}
	namePtr, err := syscall.BytePtrFromString(kpmModuleName)
	if err != nil {
		return "", err
	}
	r, _, errno := syscall.Syscall6(
		kpSupercallNr,
		0,
		kpVerAndCmd(kpSupercallKpmCtl),
		uintptr(unsafe.Pointer(namePtr)),
		uintptr(unsafe.Pointer(argsPtr)),
		uintptr(unsafe.Pointer(&out[0])),
		uintptr(len(out)-1),
	)
	if errno != 0 {
		return "", fmt.Errorf("supercall ctl0: %w", errno)
	}
	if int64(r) < 0 {
		return "", fmt.Errorf("ctl0 rc=%d", int64(r))
	}
	// 截断到首个 NUL
	n := 0
	for n < len(out) && out[n] != 0 {
		n++
	}
	return string(out[:n]), nil
}

// ---------- KernelMem：替换原 MemoryDriver 实现 ----------

// KernelMem 内核读写引擎（KPatch-Next KPM 后端）
type KernelMem struct {
	mu     sync.Mutex
	ok     bool
	reason string
	ver    string
}

// Init 检测 KPatch supercall 与 kpgcmem 模块是否就绪
func (k *KernelMem) Init() error {
	k.mu.Lock()
	defer k.mu.Unlock()

	if !kpHelloOK() {
		k.reason = "KPatch supercall unavailable"
		return errors.New(k.reason)
	}

	ver, err := kpKpmCtl("V")
	if err != nil || ver == "" || ver[0] == 'E' {
		k.reason = fmt.Sprintf("kpgcmem not loaded (%v, resp=%q)", err, ver)
		return errors.New(k.reason)
	}

	if _, err := kpXferBuffer(); err != nil {
		k.reason = err.Error()
		return err
	}

	k.ver = ver
	k.ok = true
	k.reason = ""
	return nil
}

// kernelRead 读 len(buf) 字节
func (k *KernelMem) kernelRead(pid int, addr uintptr, buf []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.ok {
		return errors.New("kernel backend not ready")
	}
	if len(buf) == 0 {
		return nil
	}

	xbuf, err := kpXferBuffer()
	if err != nil {
		return err
	}

	done := 0
	for done < len(buf) {
		n := len(buf) - done
		if n > kpmMaxXfer {
			n = kpmMaxXfer
		}
		args := fmt.Sprintf("R,%d,0x%x,%d,0x%x",
			pid, uint64(addr)+uint64(done), n, uint64(uintptr(unsafe.Pointer(&xbuf[0]))))

		resp, err := kpKpmCtl(args)
		if err != nil {
			return err
		}
		if len(resp) == 0 || resp[0] != 'R' {
			return fmt.Errorf("kernel read failed: %q", resp)
		}
		var got int
		if _, e := fmt.Sscanf(resp[1:], "%d", &got); e != nil {
			return fmt.Errorf("kernel read parse: %q", resp)
		}
		if got <= 0 {
			return fmt.Errorf("kernel read rc=%d", got)
		}
		copy(buf[done:], xbuf[:got])
		done += got
		if got < n {
			break
		}
	}
	if done != len(buf) {
		return fmt.Errorf("kernel read short: %d/%d", done, len(buf))
	}
	return nil
}

// kernelWrite 写 len(buf) 字节
func (k *KernelMem) kernelWrite(pid int, addr uintptr, buf []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.ok {
		return errors.New("kernel backend not ready")
	}
	if len(buf) == 0 {
		return nil
	}

	done := 0
	for done < len(buf) {
		n := len(buf) - done
		if n > 512 { // ctl_args 长度限制
			n = 512
		}
		hex := fmt.Sprintf("%x", buf[done:done+n])
		args := fmt.Sprintf("W,%d,0x%x,%s", pid, uint64(addr)+uint64(done), hex)

		resp, err := kpKpmCtl(args)
		if err != nil {
			return err
		}
		if len(resp) < 2 || resp[0] != 'W' {
			return fmt.Errorf("kernel write failed: %q", resp)
		}
		var got int
		if _, e := fmt.Sscanf(resp[1:], "%d", &got); e != nil {
			return fmt.Errorf("kernel write parse: %q", resp)
		}
		if got <= 0 {
			return fmt.Errorf("kernel write rc=%d", got)
		}
		done += got
		if got < n {
			break
		}
	}
	if done != len(buf) {
		return fmt.Errorf("kernel write short: %d/%d", done, len(buf))
	}
	return nil
}

// Close 释放（KPM 模块保持加载，不做卸载）
func (k *KernelMem) Close() {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.ok = false
}

// Mode 返回后端标识，供 gg_status 显示
func (k *KernelMem) Mode() string {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.ok {
		return "kpm(" + k.ver + ")"
	}
	return "kpm(unavailable: " + k.reason + ")"
}
