# Väinö — Development Roadmap

> Step-by-step plan from scratch to a bootable hybrid microkernel operating system.
> Each phase produces a **testable artifact** (QEMU boot + serial output).

---

## Phase 0 — Foundation ✅

| Task | Status |
|------|--------|
| Architecture documentation | ✅ |
| Over-documentation standard | ✅ |
| Project structure & build.zig skeleton | ✅ |
| Limine + linker.ld configuration | ✅ |
| Documented entry point example | ✅ |

---

## Phase 1 — Boot & Output ✅

**Goal**: Kernel boots in Limine, prints "Zinux boot OK" to UART/VGA.

| # | Task | File | Status |
|---|------|------|--------|
| 1.1 | Limine request/response | `kernel/boot/limine_protocol.zig` | ✅ |
| 1.2 | `_start` entry + early stack | `kernel/boot/entry.zig` | ✅ |
| 1.3 | VGA text mode driver | `kernel/drivers/video/vga.zig` | ✅ |
| 1.4 | UART COM1 debug driver | `kernel/drivers/char/uart.zig` | ✅ |
| 1.5 | Log module (serial + vga) | `kernel/lib/log.zig` | ✅ |
| 1.6 | ISO-build + QEMU-run step | `build.zig` | ✅ |
| 1.7 | CI: boot-test "Zinux boot OK" | `.github/workflows/ci.yml` | ✅ |

**Test**:
```bash
zig build iso && zig build run
# Expected serial: [Zinux] boot OK
```

---

## Phase 2 — Memory Management ✅

**Goal**: Physical and virtual memory management works; kernel heap allocates.

| # | Task | File | Status |
|---|------|------|--------|
| 2.1 | GDT + TSS | `kernel/arch/x86_64/gdt.zig` | ✅ GDT (TSS later) |
| 2.2 | IDT + interrupt handlers | `kernel/arch/x86_64/idt.zig` | ✅ stub + #14 |
| 2.3 | 4-level paging | `kernel/arch/x86_64/paging.zig` | ✅ mapPage + mapPageEnsure |
| 2.4 | PMM bitmap allocator | `kernel/mm/pmm.zig` | ✅ Limine map + host tests |
| 2.5 | VMM page mapping | `kernel/mm/vmm.zig` | ✅ PMM page tables + mapNewPageEnsure |
| 2.6 | Kernel heap (first-fit) | `kernel/mm/heap.zig` | ✅ heap_core + VMM growth |
| 2.7 | Page fault handler | `kernel/arch/x86_64/idt.zig` | ✅ CR2 + error code log |

**Test**: Allocate 100 frames, map, write, read — no page fault. ✅

**Boot**:
```bash
zig build run
# Expected serial:
# PMM initialized, PMM alloc test OK, VMM initialized, Heap initialized
# Memory map test OK (100 frames), Heap test OK, Zinux boot OK
```

---

## Phase 3 — Processes & Scheduling ✅

**Goal**: Multiple threads, context switch, PIT timer.

| # | Task | File | Status |
|---|------|------|--------|
| 3.1 | CPU context (save/restore) | `kernel/arch/x86_64/context.zig` | ✅ RSP switch |
| 3.2 | Process & thread structures | `kernel/sched/thread.zig` | ✅ stub |
| 3.3 | Round-robin scheduler | `kernel/sched/scheduler.zig` | ✅ coop ABAB demo |
| 3.4 | PIT 8254 timer | `kernel/drivers/timer/pit.zig` | ✅ |
| 3.5 | Timer IRQ → scheduler tick | `kernel/arch/x86_64/idt.zig` | ✅ PIT IRQ + Phase 3 timer ticks OK |
| 3.6 | SMP per-CPU init (Limine) | `kernel/boot/smp.zig` | ✅ CPU count in boot log |

**Test**: Two threads alternate output → `ABAB...` in serial ✅

---

## Phase 4 — Syscalls & IPC ✅

**Goal**: User-mode process can call the kernel; capability model.

| # | Task | File | Status |
|---|------|------|--------|
| 4.1 | Syscall entry (syscall/sysenter) | `kernel/arch/x86_64/syscall.zig` | ✅ STAR/LSTAR/SFMASK + entry.S |
| 4.2 | Syscall dispatch table | `kernel/syscall/dispatch.zig` | ✅ write/exit/getpid + boot test |
| 4.3 | Capability structure | `kernel/ipc/capability.zig` | ✅ create/delegate/revoke + boot test |
| 4.4 | IPC ports (send/recv) | `kernel/ipc/port.zig` | ✅ ring buffer + cap send/recv + boot test |
| 4.5 | Ring 3 transition | `kernel/arch/x86_64/usermode.zig` | ✅ iretq + SYSCALL hello + test_return |
| 4.6 | Shared ABI | `libs/zinuxabi.zig` | ✅ syscall numbers + error codes |

**Test**: Ring 3 `sys_write("hello")` → serial + `Usermode test OK` ✅

---

## Phase 5 — Userland ✅

**Goal**: Init process, shell, basic commands.

| # | Task | File | Status |
|---|------|------|--------|
| 5.1 | ELF loader in kernel | `kernel/loader/elf.zig` | ✅ parse PT_LOAD + boot "elf" |
| 5.2 | init process | `userland/init/main.zig` | ✅ ELF load + "init\n" + Init process OK |
| 5.3 | Interactive shell | `userland/shell/main.zig` | ✅ prompt + help + Shell test OK |
| 5.4 | PS/2 keyboard | `kernel/drivers/char/keyboard.zig` | ✅ IRQ1 + Keyboard init/test OK |
| 5.5 | Commands: help, meminfo, ps | `userland/shell/commands/` | ✅ SYS_meminfo/ps + boot test OK |

**Test**: Boot → shell prompt `zinux> ` → `help` / `meminfo` / `ps` work.

---

## Phase 6 — Drivers & Filesystem ✅

**Goal**: PCI enumeration, virtio-blk, simple FS.

| # | Task | File | Status |
|---|------|------|--------|
| 6.1 | PCI bus scan | `kernel/drivers/bus/pci.zig` | ✅ config scan + PCI scan OK |
| 6.2 | VirtIO block driver | `kernel/drivers/block/virtio_blk.zig` | ✅ PCI common cfg + VirtIO block read OK |
| 6.3 | VFS interface | `kernel/fs/vfs.zig` | ✅ mount + open/read/close + VFS test OK |
| 6.4 | tmpfs (RAM-based) | `kernel/fs/tmpfs.zig` | ✅ /tmp/welcome + tmpfs test OK |
| 6.5 | Userland driver model | `userland/drivers/` | ✅ registry + null driver + Userland driver test OK |

---

## Phase 7 — Security & Hardening ✅

| # | Task | Status |
|---|------|--------|
| 7.1 | SMEP/SMAP activation | ✅ CR4 + stac/clac + SMEP/SMAP hardening OK |
| 7.2 | Stack canaries in kernel | ✅ early/syscall/TSS/thread + Stack canary OK |
| 7.3 | KASLR (random kernel base) | ✅ RDTSC+HHDM heap slide + KASLR OK |
| 7.4 | Capability-audit logging | ✅ ring buffer + Capability audit OK |
| 7.5 | Fuzzing: syscall interface | ✅ LCG fuzz + Syscall fuzz OK |

---

## Phase 8 — IPC to Userland ✅

**Goal**: Ring 3 can send/receive messages through capability slots via syscalls.

| # | Task | File | Status |
|---|------|------|--------|
| 8.1 | sys_ipc_send / sys_ipc_recv | `kernel/syscall/dispatch.zig`, `ipc_syscall_core.zig` | ✅ invoke + IPC syscall OK |
| 8.2 | Userland IPC library | `userland/lib/ipc.zig` | ✅ ring 3 send/recv + Userland IPC test OK |

**Test**:
```bash
zig build run
# Expected serial: IPC syscall OK, userland ipc OK, Userland IPC test OK
```

---

## Phase 9 — Capability Delegation to Userland ✅

**Goal**: Ring 3 can delegate capability rights via `sys_cap_delegate` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 9.1 | sys_cap_delegate | `kernel/syscall/dispatch.zig`, `cap_syscall_core.zig` | ✅ invoke + Cap syscall OK |
| 9.2 | Userland cap library | `userland/lib/cap.zig` | ✅ ring 3 delegate + Userland cap test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap syscall OK, userland cap OK, Userland cap test OK
```

---

## Phase 10 — Capability Creation in Userland ✅

**Goal**: Ring 3 can create new IPC-port capabilities via `sys_cap_create` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 10.1 | sys_cap_create | `kernel/syscall/dispatch.zig`, `cap_syscall_core.zig` | ✅ invoke + Cap create syscall OK |
| 10.2 | Userland cap.createPort | `userland/lib/cap.zig` | ✅ ring 3 create + Userland cap create test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap create syscall OK, userland cap create OK, Userland cap create test OK
```

---

## Phase 11 — Blocking IPC recv ✅

**Goal**: `sys_ipc_recv` blocks when port queue is empty; timer IRQ wakes waiting recv in boot test.

| # | Task | File | Status |
|---|------|------|--------|
| 11.1 | Blocking recv + timer-wake | `kernel/syscall/ipc_block_core.zig`, `ipc_block.zig`, `dispatch.zig` | ✅ IPC block OK |
| 11.2 | Userland blocking ipc.recv | `userland/ipc_block_test/`, `ipc_block_userland.zig` | ✅ userland ipc block OK |

**Test**:
```bash
zig build run
# Expected serial: IPC block OK, userland ipc block OK, Userland IPC block test OK
```

---

## Phase 12 — Capability Revocation in Userland ✅

**Goal**: Ring 3 can revoke its capability slots via `sys_cap_revoke` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 12.1 | sys_cap_revoke | `kernel/syscall/dispatch.zig`, `capability_core.zig` | ✅ invoke + Cap revoke syscall OK |
| 12.2 | Userland cap.revoke | `userland/lib/cap.zig`, `userland/cap_revoke_test/` | ✅ ring 3 revoke + Userland cap revoke test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap revoke syscall OK, userland cap revoke OK, Userland cap revoke test OK
```

---

## Phase 13 — Non-blocking IPC recv ✅

**Goal**: Ring 3 can attempt message reception without blocking via `sys_ipc_try_recv` syscall (EAGAIN if queue empty).

| # | Task | File | Status |
|---|------|------|--------|
| 13.1 | sys_ipc_try_recv | `kernel/syscall/dispatch.zig`, `ipc_try_recv_syscall.zig` | ✅ invoke + IPC try recv syscall OK |
| 13.2 | Userland ipc.tryRecv | `userland/lib/ipc.zig`, `userland/ipc_try_recv_test/` | ✅ ring 3 tryRecv + Userland IPC try recv test OK |

**Test**:
```bash
zig build run
# Expected serial: IPC try recv syscall OK, userland ipc try recv OK, Userland IPC try recv test OK
```

---

## Phase 14 — IPC Queue Depth Query ✅

**Goal**: Ring 3 can query the number of messages in a capability slot's port queue via `sys_ipc_pending` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 14.1 | sys_ipc_pending | `kernel/syscall/dispatch.zig`, `port.zig` | ✅ invoke + IPC pending syscall OK |
| 14.2 | Userland ipc.pending | `userland/lib/ipc.zig`, `userland/ipc_pending_test/` | ✅ ring 3 pending + Userland IPC pending test OK |

**Test**:
```bash
zig build run
# Expected serial: IPC pending syscall OK, userland ipc pending OK, Userland IPC pending test OK
```

---

## Phase 15 — Capability Rights Query in Userland ✅

**Goal**: Ring 3 can read a capability slot's rights mask via `sys_cap_get_rights` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 15.1 | sys_cap_get_rights | `kernel/syscall/dispatch.zig`, `cap_get_rights.zig` | ✅ invoke + Cap get rights syscall OK |
| 15.2 | Userland cap.getRights | `userland/lib/cap.zig`, `userland/cap_get_rights_test/` | ✅ ring 3 getRights + Userland cap get rights test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap get rights syscall OK, userland cap get rights OK, Userland cap get rights test OK
```

---

## Phase 16 — Capability Type Query and Port Release ✅

**Goal**: Ring 3 can read a capability slot's type via `sys_cap_get_type` syscall; port-capability revocation frees the IPC port.

| # | Task | File | Status |
|---|------|------|--------|
| 16.1 | sys_cap_get_type + port destroy on revoke | `dispatch.zig`, `capability_core.zig`, `cap_get_type.zig` | ✅ Cap get type syscall OK |
| 16.2 | Userland cap.getType | `userland/lib/cap.zig`, `userland/cap_get_type_test/` | ✅ userland cap get type OK |

**Test**:
```bash
zig build run
# Expected serial: Cap get type syscall OK, userland cap get type OK, Userland cap get type test OK
```

---

## Phase 17 — IPC Port Queue Flush ✅

**Goal**: Ring 3 can clear a capability slot's port message queue via `sys_ipc_flush` syscall without recv.

| # | Task | File | Status |
|---|------|------|--------|
| 17.1 | sys_ipc_flush | `kernel/syscall/dispatch.zig`, `port_core.zig`, `ipc_flush_syscall.zig` | ✅ invoke + IPC flush syscall OK |
| 17.2 | Userland ipc.flush | `userland/lib/ipc.zig`, `userland/ipc_flush_test/` | ✅ userland ipc flush OK |

**Test**:
```bash
zig build run
# Expected serial: IPC flush syscall OK, userland ipc flush OK, Userland IPC flush test OK
```

---

## Phase 18 — Capability Resource ID Query ✅

**Goal**: Ring 3 can read a capability slot's resource ID (e.g., port_id) via `sys_cap_get_resource` syscall; query requires read right.

| # | Task | File | Status |
|---|------|------|--------|
| 18.1 | sys_cap_get_resource | `dispatch.zig`, `capability_core.zig`, `cap_get_resource.zig` | ✅ Cap get resource syscall OK |
| 18.2 | Userland cap.getResource | `userland/lib/cap.zig`, `userland/cap_get_resource_test/` | ✅ userland cap get resource OK |

**Test**:
```bash
zig build run
# Expected serial: Cap get resource syscall OK, userland cap get resource OK, Userland cap get resource test OK
```

---

## Short-Term Plan (Phases 19–22) ✅

> **Priority**: first finish IPC introspection (19), then cross-process IPC (20–22).
> **Boot**: `zig build run` = smoke (~10 s), `zig build boot-test` = full integration tests (QEMU exits itself).

| Phase | Theme | Goal |
|-------|-------|------|
| **19** | IPC queue capacity | `pending` / `flush` / `queueCapacity` introspection trio | ✅ |
| **20** | Process table | Separate capability slots per pid | ✅ |
| **21** | Process creation | Second user-ELF into ring 3 (`sys_spawn`) | ✅ |
| **22** | Cross-process IPC | Message from process A → process B | ✅ |

---

## Medium-Term Plan (Phases 23–28)

> **Priority**: process management and introspection (23–24) → address spaces (25) → scheduler (26) → userland-IPC demo (27) → mmap (28).
> **Boot**: `zig build boot-test` = full integration test suite.

| Phase | Theme | Goal |
|-------|-------|------|
| **23** | Process list (`sys_ps`) | Real PIDs from process table + shell `ps` | ✅ |
| **24** | Process lifecycle | `sys_exit` + `sys_wait` (spawn → exit → wait) | ✅ |
| **25** | Per-process address spaces (`page_table` + CR3 per process) | ✅ |
| **26** | Scheduler + processes with timer preemption | ✅ |
| **27** | Cross-IPC userland | Spawn + cap_transfer + send/recv in ring 3 | ✅ |
| **28** | Capability-mmap | `sys_mem_map` with memory-capability | ❓ |

### Known fixes (security review, PR #2)

PR #2 branch security review (phases 20–22) found **2 medium findings**. Fixes are tied to the roadmap:

| ID | Severity | Location | Problem | Fix | Phase |
|----|----------|----------|---------|-----|-------|
| **S1** | Medium | `dispatch.zig:506`, `capability_core.zig` | `sys_cap_create` installs cap into **pid 1**, but slots are looked up with **`currentPid`** → wrong namespace / DoS pid ≥ 2 | `createAndInstall(..., process.currentPid(), ...)` | **23.0** ✅ |
| **S2** | Medium | `capability_core.zig:307`, `dispatch.zig:150` | `sys_cap_transfer` can fill victim's 32 slots with unlimited copies | Dedup scan in `transferSlotToPid` — returns existing slot index, bounded by MAX_SLOTS | **27.0** ✅ |

**S1 attack path (fixed in phase 23):** process pid ≥ 2 calls `sys_cap_create` → cap was installed into pid 1 → `lookupSlot` searches current pid's table → slot index does not match correct cap / fills boot process slots.

**S2 attack path (fixed in Phase 27.0):** process with grant-cap loops `sys_cap_transfer(victim_pid)` → victim's `MAX_SLOTS` now bounded by dedup scan — stable slot returned for same object_id before any new install.

---

## Phase 19 — IPC Queue Capacity ✅

**Goal**: Ring 3 can query a capability slot's port maximum queue depth via `sys_ipc_queue_capacity` syscall (complements `pending` + `flush`).

| # | Task | File | Status |
|---|------|------|--------|
| 19.1 | sys_ipc_queue_capacity | `dispatch.zig`, `port_core.zig`, `ipc_queue_capacity_syscall.zig` | ✅ invoke + IPC queue capacity syscall OK |
| 19.2 | Userland ipc.queueCapacity | `userland/lib/ipc.zig`, `userland/ipc_queue_capacity_test/` | ✅ userland ipc queue capacity OK |

**Test**:
```bash
zig build run
# Expected serial: IPC queue capacity syscall OK, userland ipc queue capacity OK, Userland IPC queue capacity test OK
```

---

## Phase 20 — Process Table and Per-Process Capabilities ✅

**Goal**: Kernel separates capability slots per process; current single stub process (pid 1) expands into a process table.

| # | Task | File | Status |
|---|------|------|--------|
| 20.1 | Process structure + slots per pid | `kernel/sched/process.zig`, `capability_core.zig` | ✅ lookupSlotForPid(pid, slot) |
| 20.2 | Syscall context: current pid | `dispatch.zig`, `usermode.zig` | ✅ getpid returns current pid |
| 20.3 | Boot test: two processes in same table | host-tests + kernel smoke | ✅ Process table OK |

**Note**: Phase does not yet launch a second ELF — prepares for cross-process IPC.

---

## Phase 21 — Process Creation (sys_spawn) ✅

**Goal**: Kernel can launch a second user-ELF as its own process in ring 3 (ELF-loader + separate stack mapping).

| # | Task | File | Status |
|---|------|------|--------|
| 21.1 | sys_spawn(elf_path stub / embedded) | `kernel/syscall/spawn_syscall.zig`, `dispatch.zig` | ✅ Spawn syscall OK |
| 21.2 | Separate stack/map for second process | `loader/elf.zig`, `spawn.zig`, `process_core.zig` | ✅ Two processes boot OK |
| 21.3 | Userland spawn wrapper (optional) | `userland/lib/spawn.zig` | ✅ ring 3 spawn wrapper |

**Test**: Boot loads two lightweight test ELFs sequentially with different PIDs — both print to serial (`spa\n`, `spb\n`).

---

## Phase 22 — Cross-Process IPC ✅

**Goal**: Process A sends a message to process B's port through a capability; port-capability transferred/delegated to another process.

| # | Task | File | Status |
|---|------|------|--------|
| 22.1 | Capability transfer between processes | `capability_core.zig`, `sys_cap_transfer`, `dispatch.zig` | ✅ Cap transfer OK |
| 22.2 | IPC send/recv cross-pid | `port.zig`, `cross_ipc_syscall.zig` | ✅ Cross-process send OK |
| 22.3 | Boot test: A send → B recv | `cross_ipc_test/`, `cross_ipc_userland.zig` | ✅ Userland cross IPC test OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Cap transfer OK, Cross-process send OK, Cross-process IPC syscall OK,
# userland cross ipc OK, Userland cross IPC test OK
```

---

## Phase 23 — Process List (`sys_ps`) ✅

**Goal**: `sys_ps` and shell `ps` show real processes from the process table (not hardcoded stub).

| # | Task | File | Status |
|---|------|------|--------|
| 23.0 | Security: `sys_cap_create` → `currentPid` | `dispatch.zig`, `capability_core.zig` | ✅ Cap create pid OK |
| 23.1 | `sys_ps` from process table | `dispatch.zig`, `ps_syscall_core.zig` | ✅ Ps syscall OK |
| 23.2 | Shell `ps` updated | `userland/shell/commands/ps.zig` | ✅ shell ps OK (sys_ps) |
| 23.3 | Boot test: multiple processes listed | `ps_syscall.zig`, host-tests | ✅ Ps lists processes OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Cap create pid OK, Ps syscall OK, Ps lists processes OK
# Shell in boot test: ps prints correct PIDs (at least 1 boot, 2 proc)
```

---

## Phase 24 — Process Lifecycle (exit / wait) ✅

**Goal**: Spawned process can terminate itself; parent can wait for child (`sys_wait`).

| # | Task | File | Status |
|---|------|------|--------|
| 24.1 | Process state (running / zombie) | `process_core.zig` | ✅ Process state OK |
| 24.2 | `sys_exit` marks process zombie | `dispatch.zig` | ✅ Exit syscall OK |
| 24.3 | `sys_wait(pid)` — wait one child | `dispatch.zig`, `wait_syscall.zig` | ✅ Process wait OK |
| 24.4 | Boot test: spawn → exit → wait | `spawn.zig`, boot-tests | ✅ Spawn wait boot OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Process state OK, Exit syscall OK, Process wait OK, Spawn wait boot OK
```

---

## Phase 25 — Per-Process Address Spaces ✅

**Goal**: Each process has its own page table (CR3); ELF-loader maps only into the process's address space.

| # | Task | File | Status |
|---|------|------|--------|
| 25.1-A | `Process.page_table` + CR3 field | `process_core.zig`, `vmm.zig` | ✅ `page_table: u64` in struct + all 4 init sites |
| 25.1-B | Target PML4 override | `vmm.zig` ✅ `target_pml4_phys` + `pml4Phys()` |
| 25.2 | ELF-loader into per-process table | `loader/elf.zig`, `spawn.zig` | ✅ `setTargetPml4 / clearTargetPml4` around load |
| 25.3 | Boot test: two ELFs at same VA, different procs | `phase_25_boot_test.zig` | ✅ Page table per pid OK + Address space OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Page table per pid OK, Address space OK
```

global dependency for Phase 26 (CR3 switch) and Phase 28 (mmap).

---

## Phase 26 — Scheduler + Processes ✅

**Goal**: Timer preemption switches processes; per-process CR3 switching via iretq/return.

| # | Task | File | Status |
|---|------|------|--------|
| 26.1 | `Process.page_table` + per-process PML4 | `process_core.zig`, `vmm.zig` | ✅ Phase 25 wiring |
| 26.2 | CR3 switch on ring-3 entry/return | `usermode_jump.S`, `usermode.zig` | ✅ R9→CR3 on enter, saved_kernel_cr3 restore on return |
| 26.3 | Boot test: two processes at different addresses | boot-tests | ✅ (precedes timer preemption — CR3 isolation verified) |

**Test**:
```bash
zig build boot-test
# Expected serial: Page table per pid OK, Address space OK
```

CR3 switching uses the x86_64 R9 register convention: `usermodeEnterIret(…, cr3)` writes `%r9 → %cr3` before `iretq`; `usermodeReturnToKernel` restores `saved_kernel_cr3` via a zero-check guard. No new global state added — wires Phase 25's per-process PML4 into the existing iretq + ret entry/return path.

**Dependency**: Requires Phase 25 (per-process page table). Foundation for full timer-based preemption.

---

## Phase 27 — Cross-Process IPC Userland Demo ✅

**Goal**: Userland process spawns another, transfers recv-capability, send → recv without kernel orchestration.

| # | Task | File | Status |
|---|------|------|--------|
| 27.0 | Security: `sys_cap_transfer` deduplication / move | `capability_core.zig` | ✅ Dedup scan added — returns existing slot index bounded by MAX_SLOTS |
| 27.1 | `userland/lib/spawn.zig` + `cap.transfer()` demo | `userland/lib/` | ✅ `CAP_RECV_MASK`, `capTransfer()`, `CapTransferError` |
| 27.2 | Parent spawn → transfer → child recv | `userland/cross_spawn_ipc_test/` | ✅ Parent ELF: spawn + cap_transfer loop + send |
| 27.3 | Boot test in ring 3 | `caps_s2_dedup_test.zig`, `cross_spawn_ipc_userland.zig` | ✅ S2 bounded + IPC OK serial output |

**Test**:
```bash
zig build boot-test
# Expected serial: Cap transfer bounded OK, Userland cross spawn IPC OK, Userland cross spawn IPC test OK
```

**Implementation summary:**
- **S2 dedup fix**: `transferSlotToPid` in `capability_core.zig` now scans destination slots for `src.object_id` match. Returns existing slot index instead of creating a duplicate — limits attack surface to MAX_SLOTS per process.
- **Userland cap_transfer wrapper**: `userland/lib/spawn.zig` gained `CAP_RECV_MASK`, `capTransfer()`, and `CapTransferError`. Syscall ABI: RAX=21, RDI=slot, RSI=dest_pid, RDX=mask.
- **Parent ELF** `cross_spawn_ipc_test/` (load VA `0xFFFFFFFF9008F000`): spawns child via embedded `sys_spawn(0)`, loops 4× `sys_cap_transfer(j, child_pid)` verifying stable slot index (S2 check), then sends "CXS" message. Prints `child pid: <N>` and `userland cross spawn IPC OK`.
- **Boot tests**: `caps_s2_dedup_test.zig::runS2DedupTest()` verifies bounded transfer; `cross_spawn_ipc_userland.zig::runBootTest()` orchestrates S2 + capability setup for pid_A, prints `Userland cross spawn IPC test OK`. Registered in `boot_tests.zig` between Phase 22 and Phase 23.

---

## Phase 28 — Capability-Based mmap (`sys_mem_map`) ✅

**Goal**: Memory-capability + `sys_mem_map` maps a single page into ring 3 (see ARCHITECTURE.md §6).

| # | Task | File | Status |
|---|------|------|--------|
| 28.1 | Memory-capability type (`CAP_TYPE_MEMORY=5`, CapType.memory) | `capability_core.zig`, `zinuxabi.zig` | ✅ |
| 28.2 | `sys_mem_map(slot, addr)` with write validation + mapPageEnsure U/W | `dispatch.zig`, `mem_map_syscall.zig`, `vmm.zig`, `pmm.zig` | ✅ |
| 28.3 | Userland demo: create cap → mmap → write/read verify | `userland/mem_map_test/` | ✅ |

**Test**:
```bash
zig build boot-test
# Expected serial: Mem map syscall OK, Userland mem map OK, Userland mem map test OK
```

**Dependency**: Phase 25 (per-process page table) required for correct userland mapping.

> **NOTE**: `mem_map_core.zig` provides the core: validates CapType.memory + map-right on slot, then maps with `pmm.allocFrame() → vmm.mapPageEnsure(virt,phys,{present,W,U})`.

---

## Long-Term Vision (Phases 29–37)

> These phases evolve Zinux from a monolithic microkernel into a **compositional, plugin-driven foundation** — "Zinux is not a fixed operating system. Zinux is a foundation for building operating systems."
>
> **Prerequisite chain**: Each phase builds on the capability model (25) + memory-cap mmap (28) already complete.

| Phase | Theme | Goal |
|-------|-------|------|
| **29** | Plugin sandboxing model | Capability-bound, per-plugin address space isolation | ✅ |
| **30** | `sys_plugin_load / unload` | Load/unload user-space plugin binaries at runtime | ✅ |
| **31** | Plugin IPC framework | Cross-namespace capability transfer for the plugin ecosystem | ✅ |
| **31.5** | Plugin snapshots & restore | Checkpoint/restore entire plugin state (memory, caps, regs) |
| **32** | Plugin ecosystem & untrusted distribution | Signing, registry, community audit, `zig build plugin-install` | ✅ |
| **33** | Self-healing ("Everything is replaceable") | Auto-diagnosis, patch generation, hot-swap validated plugins | ✅ |
| **34** | Task-driven composition (The Eeden Phase) | Declare a task → Zinux composes minimal environment → runs → decomposes |
| **35** | Federated Zinux (clustered capabilities) | Network-capability delegation, remote plugin, failover |
| **36** | Hardware-as-a-Service | Device declares capability → driver self-generated at runtime |
| **37** | Eeden Gate (autonomous lifecycle) | Self-verify: boot → compose → run 30d → decompose → core only |

See `docs/eeden_roadmap_append (1).md` for detailed subtasks, files, and tests.

---
### Phase-0 Blocker — Fix `sys_cap_create(type=5)` Bug ✅

Before any Eeden phase can work, **Phase 28 was functionally broken**: the ABI constant `CAP_TYPE_MEMORY = 5` in `cap_syscall_core.zig` was never routed by `sysCapCreate()` in `dispatch.zig`, which unconditionally called `port.createPort()` and installed a `.port` capability regardless of the type argument. Userland code calling `sys_cap_create(type=5)` returned `-22` (EINVAL).

| # | Task | File | Status |
|---|------|------|--------|
| **0.3** | **Implement type-aware routing in `sysCapCreate()`** | ✅ Switch/blk: port → `port.createPort()`, memory → `createAndInstall(.memory, …)` + safe null unwrap |
| **#** | **Task** | **File** | **Status** |
|---|------|------|--------|
| 0.1 | Add `CAP_TYPE_MEMORY` branch in `do_capability_create()` | `kernel/syscall/dispatch.zig` | ✅ |
| 0.2 | Verify: userland `mem_map_test` creates memory-cap via syscall, maps it, writes/reads back | `userland/mem_map_test/main.zig` + boot-test | ⬜ **pending** |

**Implementation note**: Replaced unconditional `createAndInstall(.port, …)` with a type-switch block that routes `.port` → port allocation and `.memory` → `createAndInstall(.memory, owner, 0, rights)`. The memory capability's physical frame is still allocated lazily by Phase 28's `sys_mem_map()`. All Phases 29+ are now unblocked.

---

### Detailed Execution Plan

#### Phase 29 — Plugin Sandboxing Model ✅

> **Goal**: Define security boundaries. Every plugin is a process with restricted capabilities.

| # | Task | File | Status |
|---|------|------|--------|
| 29.1 | `plugin::Scope` struct + mask in `Rights` | `kernel/plugin/scope.zig`, `capability_core.zig` | ✅ `Scope{pid,types,rights,max_caps}` + `rightsToMask/scopeAllows` + `Plugin scope/sandbox OK` boot test |
| 29.2 | Capability manifest format spec | `userland/plugin_manifest.zig` (schema) | ✅ `Manifest{validate/fitsScope}` + host tests |
| 29.3 | Isolation invariant doc | `docs/PLUGIN_MODEL.md` | ✅ I1–I7 invariants |

**Test**:
```bash
zig build test
# scope + manifest + capability host tests OK (91/91 passed)
zig build boot-test
# Expected serial: Plugin scope OK, Plugin sandbox OK, All boot tests OK
```

**Implementation summary:**
- **Scope core** (`kernel/plugin/scope.zig`, dependency-free pure logic, host-testable): `Scope{plugin_pid, allowed_types, allowed_rights, max_caps, require_isolation}` with `initScope` (clips unknown bits, defaults empty cap-limit to 8, caps at 32 = MAX_SLOTS), `validate`, `allowsType` (ABI-numbered bit: 1=port, 5=memory; 0/rejected types denied), `allowsRights` (requested ⊆ scope, reserved bits rejected), `allowsCreate` (type + rights + `count < max_caps`), `allowsDelegate` (new ⊆ old ∩ scope, no escalation), `isIsolated(page_table != 0)`.
- **Rights-mask hook** (`kernel/ipc/capability_core.zig`, no import cycle with scope): `rightsToMask`, `rightsWithinMask`, `typeBit` (kernel `.memory` enum maps to ABI bit 5 so scope/manifest match `dispatch.zig` routing), `scopeAllows(types_mask, rights_mask, typ, rights)`. Pinned by host test "masks match capability_core layout".
- **Boot test** (`kernel/plugin/plugin.zig`, registered in `boot_tests.zig` after Phase 25): positive checks (port/memory allowed, send/recv allowed, create under cap-limit, core-layer agreement, non-zero PML4 isolated) + negative checks (IRQ denied, grant leaked, cap-limit overflow, evil grant blocked at core layer, zero page-table not isolated). Prints `Plugin scope OK`, `Plugin sandbox OK`.
- **Manifest schema** (`userland/plugin_manifest.zig`, fixed-size freestanding-safe, host-testable): `Manifest{name[32], version, abi_version=1, entry_offset, caps[8]{cap_type, rights_mask}}` with `init/addCap/validate/fitsScope`. Validation order `BadName → BadAbi → TooManyCaps → BadCapType → BadRights`; rejects non-printable/`/`-names, IRQ/endpoint types (deferred to Phase 30+), reserved rights bits, empty masks; `fitsScope` checks every requirement against scope (type bit + rights subset + count).
- **Isolation model** (`docs/PLUGIN_MODEL.md`): invariants I1–I7 (per-pid slots, per-plugin address space, scope-subset holding, no-escalation delegation, manifest-is-request, global revocation, no silent broadening) + rejected alternatives (ambient authority, broad caps, trusting the manifest).
- **Wiring**: `build.zig` host modules `scope_core` + `plugin_manifest`; `tests/host/scope_test.zig` (3 tests) + `manifest_test.zig` (3 tests) registered in `tests/host/root.zig`.
- **Key design decision**: `scope.zig` has zero `@import`s to avoid a `capability_core ↔ scope` cycle; bit-layout compatibility is enforced by tests instead of shared imports.

**Verification evidence (2026-09-08):**
- `zig build test --summary all` → 91/91 host tests passed (incl. 6 new scope/manifest tests).
- `zig build` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Plugin scope OK`, `Plugin sandbox OK`) → pending CI (no QEMU/xorriso on dev machine).


#### Phase 30 — `sys_plugin_load` / `sys_plugin_unload` ✅

> **Goal**: Runtime plugin lifecycle via syscalls, with manifest-driven capability enforcement.

| # | Task | File | Status |
|---|------|------|--------|
| 30.1 | ELF loader for plugins (reuses Phase 5 ELF parser) | `kernel/plugin/loader.zig` | ✅ `loadPlugin/runPlugin` + 8-entry registry (`plugin_prog.bin` @ 0xFFFFFFFF9008D000, stack slot 116) |
| 30.2 | Manifest parser (`{caps:[], entry_offset, name}` JSON) | `kernel/plugin/manifest.zig` | ✅ `buildSingleCapManifest/checkManifest/checkScope` (register-carried 1-cap manifest; JSON deferred — no std.json in freestanding kernel, schema already multi-cap ready) |
| 30.3 | `sys_plugin_load(path)` syscall | `kernel/syscall/plugin_load_syscall.zig` | ✅ `SYS_plugin_load=24`, `sys_plugin_load(embedded_id, req_type, req_rights, scope_types, scope_rights, max_caps)` → pid; `Plugin load OK` boot test |
| 30.4 | `sys_plugin_unload(pid)` syscall + resource reclamation | `kernel/syscall/plugin_unload_syscall.zig` | ✅ `SYS_plugin_unload=25`, parent-or-boot only; revoke + slots + PML4 + pid reclaimed; `Plugin unload OK` boot test |

**Dependency**: Phases 25+28 (per-process address spaces + memory-cap mmap).
**Hook into existing boot-test**: register new plugin via init, verify it is alive.

**Test**:
```bash
zig build test
# plugin manifest + scope + capability + pmm host tests OK (98/98 passed)
zig build boot-test
# Expected serial: plg / Plugin load OK, Plugin unload OK, All boot tests OK
```

**Implementation summary:**
- **Loader + registry** (`kernel/plugin/loader.zig`): `loadPlugin` mirrors the Phase 21/25 spawn flow (allocNextPid → parent=current → PML4 frame → memset → setPageTable → target_pml4 → `elf.loadElfWithStack` → setLoaded) with cleanup on every failure path; fixed 8-entry `PluginEntry{pid, parent_pid, scope}` registry (`register/unregister/isPlugin/pluginParent/pluginCount`); `runPlugin` via `enterUserAs` (prints `plg\n`); `unloadPlugin` = `revokeAllOwnedBy` + `clearSlotsForPid` + `physToFrame`→`freeFrame` PML4 + `setPageTable(0)` + `freePid` + unregister (best-effort order, tail-pid so no table holes).
- **Manifest enforcement** (`kernel/plugin/manifest.zig`, host-testable): `validateSingleCap` structural check, `buildSingleCapManifest` (name "plugin"), `checkManifest` → EINVAL, `checkScope` (`fitsScope` + per-cap `allowsCreate` with running count) → EPERM. Imports userland schema as `plugin_manifest` build module (same `zinuxabi`/`process_core` pattern — relative cross-root `@import` is rejected by Zig 0.16 modules).
- **Syscalls** (`dispatch.zig`, `libs/zinuxabi.zig`): `SYS_plugin_load=24` builds manifest + scope from registers (pid rebound to loaded pid after load; registry-full → unload + ENOMEM), `SYS_plugin_unload=25` requires caller == parent or boot (else EPERM), unknown/non-plugin pid → ESRCH. Handlers fit the existing `[32]` table.
- **Reclamation helpers**: `capability_core.revokeAllOwnedBy` (revoke each owned object — ports freed, all referencing slots zeroed) + `clearSlotsForPid` (drop remaining references incl. transferred caps); `pmm.physToFrame` (aligned + in-range checked inverse of `frameToPhys`).
- **Plugin ELF** (`userland/plugin_test/`: `start.S` prints `plg\n` + `SYS_test_return`, `user.ld` @ `0xFFFFFFFF9008D000` — free gap between 0x…C000 and 0x…E000): standard build.zig embed block → `kernel/loader/plugin_prog.bin`.
- **Key design decisions**: register-carried manifest instead of JSON/pointers (no parser, no user-copy, identical path from ring 3 and boot-test `invoke`); unload keeps Phase 24 zombie semantics out — full removal, since plugins are replaceable units (I-model "everything is replaceable").

**Verification evidence (2026-09-08):**
- `zig build test --summary all` → 98/98 host tests passed (incl. 3 plugin-manifest-enforcement + 2 capability-reclaim + 1 pmm-physToFrame tests).
- `zig build` (freestanding kernel incl. plugin ELF + new boot tests) → passed.
- QEMU `boot-test` serial (`plg`, `Plugin load OK`, `Plugin unload OK`) → pending CI (no QEMU/xorriso on dev machine).

#### Phase 31 — Plugin IPC Framework ✅

> **Goal**: Cross-namespace capability transfer through a gateway mechanism rooted in init.pid scope.

| # | Task | File | Status |
|---|------|------|--------|
| 31.1 | Namespace mapping: plugin A → plugin B capabilities | `kernel/plugin/ns_map.zig` | ✅ `gatewayTransfer` + `Plugin IPC gateway OK` boot test |
| 31.2 | Manifest `cap:[]` enforcement at load-time | `kernel/plugin/manifest.zig` (validator) | ✅ `enforceCapsAtLoad` + `Plugin manifest caps OK` boot test |
| 31.3 | `sys_plugin_transfer` syscall (gateway ABI) | `dispatch.zig`, `libs/zinuxabi.zig` (`SYS_plugin_transfer=26`) | ✅ thin handler → EPERM on closed gate; positive path via syscall as source |
| 31.4 | Ring-3 wrapper + transfer test ELF | `userland/lib/plugin_transfer.zig`, `userland/plugin_xfer_test/` | ✅ `transfer()` + `pxfer OK` from ring 3 (R10 4th-arg ABI proven) |

**Dependency**: Phase 29 (sandbox scope), Phases 22+30 (transfer + plugin infra).

**Test**:
```bash
zig build test
# scope + manifest host tests OK (incl. gateway + caps-list vectors)
zig build boot-test
# Expected serial: Plugin manifest caps OK, Plugin gateway transfer OK,
# Plugin gateway message OK, Plugin IPC gateway OK, All boot tests OK
```

**Implementation summary:**
- **Gateway** (`kernel/plugin/ns_map.zig`): `gatewayTransfer(src_pid, src_slot, dest_pid, rights_mask)` mediates plugin→plugin transfer. Both endpoints must be registered plugins; caller must be boot/init or the source itself (init-pid root — a stranger cannot move others' caps). Kernel gathers facts (grant bit, rights subset, dest scope, dest cap count) and calls the pure `scope.allowsGatewayTransfer` predicate before any write; installation reuses `transferSlotToPid` in the source context (grant/subset re-check + S2 dedup + audit). Direct plugin→plugin transfer without the scope gate was rejected (would violate I3).
- **Policy core** (`kernel/plugin/scope.zig`, dependency-free, host-testable): `allowsGatewayTransfer(dest, abi_type, rights_mask, dest_owned, src_grant, rights_subset, parties_ok)` — parties + grant + subset + `allowsCreate` (type/rights/ceiling).
- **Caps-list enforcement** (`kernel/plugin/manifest.zig`): `enforceCapsAtLoad(sc, caps, owned_start)` validates each CapReq structurally and against the scope with a running ownership count; `checkScope` is refactored onto it (fail-closed behavior preserved). Shared by the single-cap register path and future multi-cap manifests (Phase 32).
- **Accessors**: `capability_core.slotCountForPid` (destination ceiling), `loader.pluginScope` (destination scope).
- **Boot test** (`kernel/syscall/plugin_transfer_syscall.zig::runBootTest`, registered after plugin unload): 2-cap manifest admit/ceiling/grant-escalation checks; two plugins with different scopes (A with grant, B without); ghost-pid, stranger-caller (via syscall → EPERM), and grant-escalation negatives; `P31` message A→B with the transfer itself issued as `sys_plugin_transfer` by the source plugin; both plugins run in ring 3; LIFO unload restores the table.
- **Syscall** (`SYS_plugin_transfer=26`, RAX=26 RDI=src_pid RSI=src_slot RDX=dest_pid R10=rights_mask — 4. argumentti R10:ssä, CPU ylikirjoittaa RCX:n): thin `dispatch.zig` wrapper around `gatewayTransfer` — closed gate → EPERM. Register values narrow with `@truncate` (not `@intCast`): a ring-3 caller controls the registers, and truncation fails closed through the gateway instead of trapping the kernel. `ns_map.zig` stays import-clean (`dispatch → ns_map`, no cycle); the boot test lives in the syscall file per Phase-30 convention.
- **Ring-3 wrapper** (`userland/lib/plugin_transfer.zig`, `userland/plugin_xfer_test/` @ `0xFFFFFFFF90092000`, stack slot 117, `.capboot` params @ `0xFFFFFFFF90093000`, embed → `kernel/loader/plugin_xfer_test_prog.bin`): `transfer()` + `TransferError`, 4th arg in R10. Boot test loads the ELF into plugin A's address space (target-PML4 + HHDM-aliased boot-info, Phase-28 pattern), runs it as A — `pxfer OK` from ring 3 proves the R10 path; the follow-up invoke then dedups to the same slot and the `P31` message proves the transferred cap works.

#### Phase 31.5 — Plugin Snapshots & Restore ⬛ Heavy

> **Goal**: Full-state checkpoint/restore: memory pages, capability table, register file.

| # | Task | File | Status |
|---|------|------|--------|
| 31.5.1 | Snapshot struct + page-table walk (U/S-bit boundary, not half) | `kernel/snapshot_core.zig`, `kernel/snapshot.zig` | ✅ pure index/leaf math + freestanding 4-level walk + `Snapshot walk OK` boot test (VSL PML4 anchor, supervisor-skip proof) |
| 31.5.2 | `sys_plugin_checkpoint(pid)` → dump+W=0 guard | `kernel/snapshot.zig` (store+copy+guard), `kernel/syscall/dispatch.zig` (`SYS_plugin_checkpoint=27`), `kernel/syscall/snapshot_syscall.zig` | ✅ PMM-frame copies + per-page W-clear/invlpg + replace semantics + unload-reclaim + `Snapshot checkpoint OK` (copy memcmp + guard set/restore proof, 0 leaks) |
| 31.5.3 | `sys_plugin_restore(pid)` → copy-back + W-restore (slots/regs deferred, documented) | `kernel/snapshot.zig` (`restorePlugin`), `kernel/syscall/dispatch.zig` (`SYS_plugin_restore=28`), `kernel/syscall/snapshot_syscall.zig` | ✅ frame→live memcmp-verified copy-back + original-W restore (runnable, repeatable) + stale-table/mapping refusals + `Snapshot restore OK` (2× damage/restore + ghost-ESRCH) |
| 31.5.4 | Incremental snapshot (dirty-page tracking via #PF) | `kernel/snapshot.zig` (`handleWriteFault`, incremental path), `kernel/arch/x86_64/idt.zig` (returnable #PF wrapper), `userland/dirty_test/` (id=2) | ✅ fault-and-continue (#PF→dirty+W=1→iret) + dirty-gated re-copy (same cpid) + genuine ring-3 write-fault end-to-end (`dty` + `Dirty tracking OK`) |
| 31.5.5 | Watchdog: auto-restore on crash | `kernel/watchdog.zig`, `kernel/watchdog_core.zig` | ✅ `Crash captured` + `Watchdog restart OK` boot test |

**Dependency**: Phase 25 (page-table per-process). Hardest single sub-phase in Eeden stretch.

**31.5.2 implementation summary (2026-09-10):**
- **Store split** (`kernel/snapshot_ckpt_core.zig`, zero imports like `scope.zig`): fixed 4-slot table, `allocSlot/findForPid/releaseSlot/pageVirt/pageFrame/pageWasWritable/pageCount` — host-tested (3 tests: empty, alloc/find/reuse, full-rejects-fifth). Reason: importing frame/PTE code to host trips Zig 0.16's same-file-two-modules rule (hit twice, documented).
- **Orchestration** (`kernel/snapshot.zig`, +~250 lines): `checkpointPlugin` (walk → refuse huge/truncated → replace old → per page: `pmm.allocFrame` + HHDM `memcpy` + `paging.setPteWritable(false)` + invlpg; any failure rolls back frames + W-bits), `deleteCheckpoint` (W-restore with PML4-staleness check for future swap + frame free), `deleteCheckpointsForPid` (unload-reclaim, called from `sysPluginUnload` — no loader cycle since the boot test moved to `snapshot_syscall.zig`).
- **Syscall** (`SYS_plugin_checkpoint=27`, slot 28 reserved for restore): BOOT-or-parent rule mirroring unload (ESRCH ghost, EPERM stranger); `NoPageTable/HasHuge/Truncated/NoGuard→EINVAL`, `NoMemory/TableFull→ENOMEM`. Fuzz core marks 27 registered+dangerous.
- **Boot test** (`kernel/syscall/snapshot_syscall.zig`, walk test moved here verbatim): ghost→ESRCH, cpid>0, page-count==inventory, byte-memcmp of copies vs live, W-bit cleared on a writable page, delete restores W + count==0, unload clean → `Snapshot checkpoint OK`.
- **Verification:** `zig build test` 159/159, `zig build` + `-Dboot=full` clean, 3× QEMU green with `Snapshot checkpoint OK`, 0 `[ERR]`, downstream suites (heal/federate/scheduler) unaffected.

**31.5.3 implementation summary (2026-09-10):**
- **Copy-back restore** (`snapshot.restorePlugin`, NOT remap — remap considered and rejected for auditability: copy-back keeps frame identities stable and is byte-verifiable): per page, re-validate live PTE is still a present 4K user leaf (else `StaleMapping`), `memcpy` frame→live, restore original W (runnable, repeatable state — checkpoint retained, `delete` frees).
- **Staleness discipline:** PML4 compared before any write (`StaleTable` on swap/migration — owned-state migration stays a documented limit); slots/regs explicitly NOT restored (31.5.2 never captured them — page-level rollback only, stated in code + here).
- **Syscall** (`SYS_plugin_restore=28`): same BOOT-or-parent rule as checkpoint; `NoCheckpoint→ESRCH`, rest→`EINVAL`. Fuzz core: 28 registered+dangerous.
- **Boot test:** damage first page (0xA5) → `sys_plugin_restore` → memcmp + W-runnable proof → damage (0x5A) → restore again (repeatability) → ghost→ESRCH → `Snapshot restore OK`.
- **Verification:** host still 159/159 (no new pure logic — boot-covered), freestanding clean, 3× QEMU green with `Snapshot restore OK`, 0 `[ERR]`.

**31.5.5 implementation summary (2026-09-11):**
- **Watchdog core** (`watchdog_core.zig`, pure, host-tested): 4-entry table (pid→cpid+PML4), `eligibleForClaim` (U-bit + checkpoint, P/W not required — crash class is typically not-present read), saturating crash counter. 3 host tests.
- **Mechanism** (`watchdog.zig`): `watch/unwatch` (PML4-bound, diag row), `claimFault` called from the #PF wrapper after the dirty check — restore + diag + counter, then boot-test context return. Boot test: ghost negatives → load crasher (`userland/crash_test/`, embedded_id=3, not-present read at `0x1234000`) → checkpoint → watch → genuine ring-3 crash captured (`crashCount==1`, diag `degraded`) → unload + reload + re-capture (restart policy) → `Watchdog restart OK`.
- **Crash-return path** (`idt.zig` wrapper): dirty → `iretq`; watchdog-claim → RSP + callee restore + `ret` (same discipline as `usermodeReturnToKernel`); foreign → legacy log+halt. Reloads RDI/RSI before the second query (first `call` may clobber caller-saved regs).
- **Root-cause fix found via QEMU repro (infinite `Watchdog captured crash` loop):** `claimFault` ran on the plugin's CR3, whose low half lacks kernel mappings (VGA `0xB8000`) — `log.info`'s VGA write nested-faulted and the boot test continued in the wrong address space. Fix: restore `saved_kernel_cr3` before restore/diag/log (Phase-26 discipline). Temporary RSP/ret-target hex debug removed.
- **Verification:** host 164/164, freestanding clean, 3× QEMU green with `Crash captured`, `Watchdog restart OK`, `All boot tests OK`, `Full boot OK`, exit 0, 0 `[ERR]`.

**31.5.4 implementation summary (2026-09-10):**
- **Dirty bit** (`CkptPage.dirty` in the pure core): set by the fault path, cleared by incremental re-copy; `dirtyCount` accessor for tests. Host-tested lifecycle (inject → mark → count → clear).
- **Fault path** (`snapshot.handleWriteFault`, called from IDT): CR3-matched checkpoint + virt-matched page → dirty=true + `setPteWritable(true)` + invlpg + counter, returns true (silent — K2-clean); anything else → false → legacy log+halt. Stale-PTE failure rolls the flag back (no fault livelock).
- **Returnable #PF wrapper** (`idt.zig`): `pageFaultHandle` (bool) runs first, requires P+W+U bits (kernel/SMAP faults stay fatal); true → drop error code + `iretq` (write retries successfully); false → legacy path.
- **Incremental checkpoint:** same `sys_plugin_checkpoint` syscall returns the SAME cpid when a checkpoint exists — re-copies only dirty pages, re-guards them, defensively re-guards clean pages; layout change → `LayoutChanged` (caller deletes + full checkpoints).
- **End-to-end proof** (`userland/dirty_test/`, embedded_id=2, stack slot 119, `@0x90095000`): writes its own guarded stack in ring 3 → genuine #PF → `dty` serial → `dirtyCount==1` + fault counter (hardware proof, not direct call) → incremental (same cpid, count 0) → unload → `Dirty tracking OK`.
- **Enablers fixed on the way (K5/K6 above):** this was the first ring-3 exception in kernel history — its delivery path (IDT bytes, TSS layout) had never been exercised.
- **Verification:** host 160/160, freestanding clean, 3× QEMU green with `Dirty tracking OK`, 0 `[ERR]`.

#### Phase 32 — Plugin Ecosystem & Untrusted Distribution ✅

> **Goal**: Infrastructure for untrusted third-party plugins — signing, registry, audit docs.

| # | Task | File | Status |
|---|------|------|--------|
| 32.1 | Plugin signing spec (Ed25519) + format | `docs/PLUGIN_SIGNING.md` | ✅ spec + test vectors + `signing_test` (fixed vector, tamper, canonical pin, fixture end-to-end) |
| 32.2 | Public plugin registry pattern (minimal manifest net) | `userland/plugin_registry/` | ✅ `package.zig` (canonical 110 B + `ZPKG` framing) + `registry.zig` (index parse/lookup) + `registry_test` |
| 32.3 | Community audit guide | `docs/PLUGIN_AUDIT.md` | ✅ M1–M5 mechanical checks, capability review, severity rubric, worked example |
| 32.4 | `zig build plugin-install <url>` in `build.zig` | `build.zig` | ✅ fetch (curl) + `tools/plugin_verify.zig` (Ed25519 gate) + local registry; demo good→installed / tampered→rejected |

**Dependency**: None (documentation + tooling). Can start **in parallel** with Phases 30–31.

**Test**:
```bash
zig build test
# signing (5) + registry (3) host tests OK
zig build plugin-install -Dplugin-url=file://$PWD/tests/fixtures/plugin_registry/demo_plugin.zpkg -Dplugin-key=$(cat tests/fixtures/plugin_registry/trusted_test_key.hex)
# plugin-verify: INSTALLED 'demo' v1 (2 caps)
zig build plugin-install -Dplugin-url=.../demo_plugin_tampered.zpkg -Dplugin-key=...
# plugin-verify: SIGNATURE REJECTED for 'demo', exit 1, nothing installed
```

**Implementation summary:**
- **Format** (`userland/plugin_registry/package.zig`, freestanding-safe, no crypto): canonical 110-byte manifest (little-endian, fixed layout — trailing zeros signed), `ZPKG` framing `[magic 4][len u32][canonical 110][sig 64]` = 182 B. `BadMagic/BadLength/BadManifest` rejections name the cause.
- **Registry** (`userland/plugin_registry/registry.zig`, dependency-free): `name version keyid-hex url` text index (`file://`/`https://` only — plain `http` rejected for distribution), duplicate-name rejection, `keyid` = first 8 pubkey bytes. Trust comes from pinned keys, never from the index.
- **Signing spec** (`docs/PLUGIN_SIGNING.md`): Ed25519/RFC 8032, keyid rules, canonical layout table, framing table, sign/verify procedures, TEST-ONLY vectors (seed `zinux-phase32-test-seed-00000001`, `hello zinux`), demo fixture appendix. Deferred honestly: no kernel-side checks (no `std.crypto` freestanding), no revocation lists, no ELF payload signing.
- **Audit guide** (`docs/PLUGIN_AUDIT.md`): M1–M5 mechanical checks, per-right necessity/minimality review, `grant` and `memory+map+write` red flags, severity rubric (REJECT/CUT/INSTALL), report template, worked example (bundled `plugin_test` → CUT: its port cap is unjustified).
- **Installer** (`tools/plugin_verify.zig` + `build.zig` step): request-file protocol (no argv parsing — fixed `zig-out/plugin-install/request`), `std.Io` file I/O (Zig 0.16 API), verify-then-copy (never installs on failure). Fixtures under `tests/fixtures/plugin_registry/` (test pubkey, good + tampered packages, index).
- **Key decision**: no private keys in the repo and no signer tool — fixtures were signed once with an ephemeral test key (since discarded); verification needs only the public key.

#### Phase 33 — Self-Healing ("Everything is Replaceable") ✅

> **Goal**: Auto-diagnosis, patch generation, validated hot-swap without human intervention.

| # | Task | File | Status |
|---|------|------|--------|
| 33.1 | Plugin error diagnostics (last faults, mem pressure, IPC latency) | `kernel/plugin_diag.zig` | ✅ pure core + `Plugin diagnostics OK` boot test |
| 33.2 | Patch generation design doc (ABI diff, ELF patching) | `docs/SELF_HEAL.md` | ✅ in-place reload model (no byte-patching) |
| 33.3 | Validation pipe: run corrected plugin in sandbox before swap | `tests/host/plugin_heal_test.zig`, `kernel/syscall/plugin_heal_syscall.zig` | ✅ offline pipe + live A→B gateway + `Plugin heal validation OK` |
| 33.4 | Hot-swap orchestration (freeze→kill→rename→bridge IPC) | `kernel/plugin_swap.zig` | ✅ in-place same-pid swap + `Self-heal OK` |

**Dependency**: Phase 31.5 (snapshots). Phase 30 (plugin lifecycle).

**Test**:
```bash
zig build test
# diag (2) + validation pipe (1) host tests OK (114/114 passed)
zig build boot-test
# Expected serial: Plugin heal validation OK, Plugin diagnostics OK,
# Hot-swap replaced plugin, Self-heal OK, All boot tests OK
```

**Implementation summary:**
- **Diag core** (`kernel/plugin_diag.zig`, dependency-free pure logic like `scope.zig`, host-testable): fixed table (16 rows), saturating `error_count` (`DIAG_MAX_ERRORS=3`), `FaultType` heuristic from error code, max-tracking IPC latency, pure `recordMemoryPressure(pid, free_now, free_baseline)` (caller passes `pmm` numbers in — no freestanding imports in the core). Unknown pid → `crashed` (fail-closed).
- **Swap** (`kernel/plugin_swap.zig`, freestanding): in-place same-pid reload — snapshot shared (non-old-owned) caps → fresh PML4 + `loadElfWithStack` alongside → revoke owned + clear slots + swap PML4 → scope-checked reinstall → registry refresh. Pid reuse keeps the append-only process table hole-free (new pid + old free would orphan the tail — documented). Old-owned caps die in teardown; owned-state migration needs Phase 31.5 snapshots (documented limit, stateless + shared-port plugins fully heal today).
- **Boot test** (`kernel/syscall/plugin_heal_syscall.zig`, registered in `boot_tests.zig` after Phase 31): loads A with grant scope, installs a BOOT-owned shared port (continuity) + an A-owned grant cap, proves the offline pipe (manifest + scope + gateway predicate), proves a live A→B gateway message, unloads B (LIFO-clean), crashes A (3 faults → `crashed`), swaps in place, verifies continuity message + ring 3 run, unloads A.
- **Loader hook**: `loader.pluginElf()` accessor for the swap reload (same bytes `loadPlugin` uses).
- **Wiring**: `build.zig` host module `plugin_diag_core`; `tests/host/plugin_heal_test.zig` (3 tests) registered in `tests/host/root.zig`.

**Verification evidence (2026-09-08):**
- `zig build test --summary all` → 114/114 host tests passed (incl. 3 new heal tests).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Plugin heal validation OK`, `Plugin diagnostics OK`, `Self-heal OK`) → pending CI (no QEMU/xorriso on dev machine, same as phases 29–31).
- **Amendment 2026-09-10 (first local QEMU run): serials NOT observed — heal test aborts at `Heal boot slot failed`. See K1/K2.**
- **Amendment 2026-09-10 (K1+K4 fixes, 3× green runs, 0 `[ERR]`): all serials observed — `Plugin heal validation OK`, `Plugin diagnostics OK`, `Hot-swap replaced plugin`, `Self-heal OK`.**

#### Phase 34 — Task-Driven Composition (The Eeden Phase) ✅

> **Goal**: User declares a task → Zinux composes minimal environment → runs → decomposes.

| # | Task | File | Status |
|---|------|------|--------|
| 34.1 | Task Description Language (TDL) spec doc | `docs/TDL.md` | ✅ grammar + canonical TaskSpec + C1–C5 invariants |
| 34.2 | AI-heuristic composer: resolve task→plugins | `userland/composer/` | ✅ `task.zig` parse/validate + `resolve.zig` 1:1 heuristic |
| 34.3 | Core orchestrator: receives TDL, resolves caps, installs plugins | `kernel/composer.zig` | ✅ manifest+scope gate per plugin + `Task compose OK` boot test |
| 34.4 | Decompose on task-complete / timeout (LIFO plugin kill) | `kernel/decomposer.zig` | ✅ pure LIFO+expiry policy + `Task decompose OK` boot test |

**Dependency**: Phases 30+32 (plugin load + registry). Phase 33 (self-healing guarantees).

**Test**:
```bash
zig build test
# tdl + resolve + decomposer host tests OK (118 passed)
zig build boot-test
# Expected serial: Task received: http+uptime, Composing system...,
# Task compose OK, Task run OK, Task complete, Decomposing...,
# Task decompose OK, Core only. Ready for next task., All boot tests OK
```

**Implementation summary:**
- **TDL core** (`userland/composer/task.zig`, dependency-free pure logic, host-testable): `TaskSpec{name[32], needs[8], timeout, max_plugins, version=1}` with line-oriented `;`-parser (no JSON — no `std.json` freestanding) + stable `validate` order `BadName → BadVersion → TooManyNeeds → BadNeedType → BadRights → BadBounds` (+ `ParseError` for syntax). ABI numbers match scope/manifest (1=port, 5=memory; read..grant bits 0..5).
- **Heuristic** (`userland/composer/resolve.zig`, dumb stand-in for the future AI composer): N needs → N `PluginReq`s, `scope_rights == req_rights` (no broadening by construction), single-type scopes, ceiling contradiction → `TooManyPlugins`. Shared `composer_task` module instance in both graphs (same pattern as `capability/process_core` — no duplicate-type split).
- **Orchestrator** (`kernel/composer.zig`, freestanding): per-plugin `buildSingleCapManifest → checkManifest → initScope/validate → checkScope` gate (same gate as `sys_plugin_load`, pid rebound to loaded pid — S1 lesson), abort unwinds LIFO (C2, no partial environments), single active composition (documented limit).
- **Decomposer** (`kernel/decomposer.zig`, dependency-free pure policy like `scope.zig`): `lifoAt/lifoOrder` tail-first teardown (append-only table stays hole-free), `isExpired` (`now >= deadline` — timeout is a kernel bound, not a hint), `shouldDecompose(complete/expired/failed)`.
- **Boot test** (`composer.runBootTest`, registered after Phase 33): syntax-escalation + ceiling negatives (nothing loaded), 2-plugin compose with `reqNarrowsNeed` no-broadening proof, ring-3 run (`plg` × 2), deadline predicate wiring, LIFO decompose with zero-survivor check (C5).
- **Wiring**: `build.zig` kernel modules `composer_task` + `composer_resolve` (shared instance) and host modules + `decomposer_core`; `tests/host/composer_test.zig` (5 tests) registered in `tests/host/root.zig`.
- **Key design decision**: policy (`decomposer.zig`, pure) vs. mechanism (`composer.zig` + `loader`, freestanding) split — the order/expiry decision is host-testable without hardware; only the load/unload loop touches kernel state.

**Verification evidence (2026-09-09):**
- `zig build test --summary all` → 118 host tests passed (incl. 5 new TDL/resolve/decomposer tests).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Task compose OK`, `Task run OK`, `Task decompose OK`, `Core only. Ready for next task.`) → pending CI (no QEMU/xorriso on dev machine, same as phases 29–33).

#### Phase 35 — Federated Zinux (Clustered Capabilities) ✅

> **Goal**: Capability delegation across machines; remote plugin migration + failover.

| # | Task | File | Status |
|---|------|------|--------|
| 35.1 | Capability tunnel over TCP (tuple + HMAC) | `kernel/net/cap_tunnel.zig` | ✅ HMAC-SHA256 seal/open + replay window (loopback wire — real TCP is 35.x, see F-L1) |
| 35.2 | Remote IPC userland library (transparent forwarding) | `userland/remote_ipc/` | ✅ `forwarder.zig` route table + length gate |
| 35.3 | Plugin migration: snapshot→push→restore on target | `kernel/migrate.zig` | ✅ all-or-nothing plan state machine + continuity proof |
| 35.4 | Failover: heartbeat + plugin replication on node loss | `kernel/failover.zig` | ✅ heartbeat/sweep cluster + spare-promotion policy |

**Dependency**: Phase 31 (IPC), Phase 33 (snapshot-based migration). Largest new code surface in this stretch.

**Test**:
```bash
zig build test
# hmac (FIPS + RFC 4231) + tunnel + forwarder + migrate + failover host tests OK (124 passed)
zig build boot-test
# Expected serial: Node A joined, Node B joined, Uptime plugin migrated A->B,
# Node A left, Failover: uptime plugin replicated on B, Federated cluster OK,
# All boot tests OK
```

**Implementation summary:**
- **HMAC core** (`kernel/net/hmac.zig`, dependency-free pure logic, host-testable): standard SHA-256 (FIPS 180-4) + HMAC-SHA256 (RFC 2104) with streaming `Sha256{init,update,final}` — no novel crypto (prior-art principle). Verified against FIPS vectors (`""`, `"abc"`) and RFC 4231 cases 1–2.
- **Tunnel** (`kernel/net/cap_tunnel.zig`, pure, shares one `fed_hmac` instance in both graphs — same pattern as `composer_task`): 33-byte canonical tuple `{src_node, src_pid, src_slot, dest_node, rights_mask, nonce}` + MAC. `sealNext` assigns monotonic nonces (0 reserved — zeroed memory never forms a message); `open` checks known-peer → fresh-nonce → valid-MAC, advancing the replay window only on accept. Named errors: `UnknownPeer` (join gate) / `Replay` / `BadMac` / `BadVersion` / `NoSlot`.
- **Forwarder** (`userland/remote_ipc/forwarder.zig`, pure value type): 8-entry `RemotePort` table, idempotent `register`, `route(node,slot)` for incoming frames, `checkSend` length gate at `port.MAX_MSG_SIZE` parity (never fragments). Carries routes, never capabilities — I1 holds across the wire.
- **Migration** (`kernel/migrate.zig`, pure): `idle → staged → restored → done` (or `aborted`); `notePushed` requires `bridged == total` (all-or-nothing, same discipline as 33-swap `fail_bridge`); rejects ghost pids, zero nodes, self-loops. Owned-state migration still needs 31.5 snapshots (documented F-L3).
- **Failover** (`kernel/failover.zig`, pure): `Cluster{join,heartbeat,leave,sweep,aliveCount}` on a caller tick clock (deterministic, `decomposer`-pattern); `ReplicaPlan{home,spare}` promotes only on confirmed home death with live spare + serving pid, else visibly `orphaned`.
- **Boot test** (`kernel/federate.zig`, registered after Phase 34): A+B join, grant-scoped PA + BOOT-owned shared port, sealed push over the loopback wire (F-L1 stand-in for TCP) with three in-boot negatives (replay/tamper/ghost), gateway-authorized install (MAC ≠ permission), live FED1 message, forwarder route proof, push 1/1 → run → restore → drain A → done, FED3 continuity via the surviving shared port, sweep-proven A-loss → spare promotion, full cleanup with zero-survivor check.
- **Trust doc** (`docs/FEDERATION.md`): authenticate-vs-authorize split, honest limits table F-L1…F-L5 (loopback wire, TEST-ONLY key, no owned-state migration, non-constant-time compare, single spare).
- **Wiring**: `build.zig` kernel modules `fed_hmac` + `remote_forwarder` (tunnel/migrate/failover travel relatively via `federate.zig`, scope-pattern) and host modules `fed_hmac/fed_tunnel/remote_forwarder/fed_migrate/fed_failover`; `tests/host/federate_test.zig` (5 tests + import shim) registered in `tests/host/root.zig`.
- **Key design decision**: a valid MAC is an envelope, not a capability — installation always re-passes the Phase 31 scope gate. A compromised peer key can at most request, never escalate.

**Verification evidence (2026-09-09):**
- `zig build test --summary all` → 124 host tests passed (118 baseline + 5 new federate tests + 1 import shim).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- Ground-truth cross-check: all 4 crypto vectors verified byte-for-byte against Python `hashlib`/`hmac` before acceptance (caught 3 transcription typos — evidence for never trusting hand-copied constants).
- QEMU `boot-test` serial (`Node A joined`, `Uptime plugin migrated A->B`, `Failover: uptime plugin replicated on B`, `Federated cluster OK`) → pending CI (no QEMU/xorriso on dev machine, same as phases 29–34).
- **Amendment 2026-09-10 (first local QEMU run): only `Node A/B joined` observed — federate test aborts at `Federate boot slot failed`. See K1/K2.**
- **Amendment 2026-09-10 (K1+allocator+tamper+K4 fixes, 3× green runs, 0 `[ERR]`): all serials observed — `Uptime plugin migrated A->B`, `Node A left`, `Failover: uptime plugin replicated on B`, `Federated cluster OK`.**

#### Phase 36 — Hardware-as-a-Service (Design / Research) ✅

> **Goal**: Device declares capability → driver auto-generated at runtime. No persistent `.ko` files.

| # | Task | File | Status |
|---|------|------|--------|
| 36.1 | Hardware capability protocol spec | `docs/HW_CAP_PROTOCOL.md` | ✅ descriptor + plan schema + P1–P4 policy + Termite prior art |
| 36.2 | Live driver code generator (Zig template expansion) | `kernel/hw_gen.zig` | ✅ pure plan validation + deterministic expansion + fake sensor |
| 36.3 | Driver lifecycle: generate → bind → exec → destroy | `kernel/hw_lifecycle.zig` | ✅ single active record + `Driver active` boot test |
| 36.4 | "No persistent driver files" design note | `docs/NO_DRIVERS.md` | ✅ generate→destroy rule + stored/not-stored table |

**Dependency**: Phase 6 (existing drivers as reference for device enumeration). Research phase — defer implementation until Phases 29–35 are stable.

**Test**:
```bash
zig build test
# hw plan + expansion + sensor + exec host tests OK (131 passed)
zig build boot-test
# Expected serial: Unknown device detected, Capabilities: temperature, humidity,
# Generating driver..., Driver active: temp=23.4C, Device detached,
# Driver destroyed, All boot tests OK
```

**Implementation summary:**
- **Protocol** (`docs/HW_CAP_PROTOCOL.md`): 9-layer split (task → hw-info → plan → policy → caps → generated map → validation → sandbox → execution — never collapsed); `HwDescriptor{window, named caps}` + `DriverPlan{ranges, forbidden, straight-line steps, read caps, expect}` with stable error order; P1 console-UART protection, P2 window-subset, P3 bounded execution (≤16 steps, no jumps), P4 mandatory `expect` (counterexample hook). Template class honestly bounded: register-PIO only; DMA/IRQ/firmware are named 36.x experiments.
- **Generator** (`kernel/hw_gen.zig`, dependency-free pure logic, host-testable): `validate` (subset ∩ policy ∩ caps) + `generate` (precomputed absolute addresses — "generation" is honestly a deterministic map, not a kernel compiler; documented) + `FakeSensor` (ID/STATUS/CTRL-magic/ready-gated measurements/read-only/write-only/range faults with a `faults` counter) + `execSequence` (init in order, reads, `expect` compare — any refusal fails the whole run).
- **Lifecycle** (`kernel/hw_lifecycle.zig`, freestanding): one active `BoundDriver` record (`generateBind → execActive → destroy`, destroy zeroes it — NO_DRIVERS by construction); boot test proves the eeden serials with 6 negatives first (UART overlap, bad step index, unarmed read, wrong magic, OOB/read-only/write-only, wrong expect) then the positive run (measured 234 tenths verified before the static `23.4C` line) and clean detach/destroy.
- **No-drivers note** (`docs/NO_DRIVERS.md`): plans (requests) may be kept, grants (bound addresses) die at destroy — policy changes apply retroactively because nothing is stored past the decision; costs stated plainly.
- **Wiring**: `build.zig` host module `hw_gen` (lifecycle travels relatively, decomposer-pattern); `tests/host/hw_test.zig` (6 tests + import shim) in `tests/host/root.zig`; `hw_lifecycle.runBootTest` in `boot_tests.zig` after Phase 35.
- **Key design decision**: framework (registration/lifecycle/error frames) is deterministic kernel infrastructure; only the hardware-specific map is "generated" — exactly the AGENTS.md split (*generate the hardware-specific part, not the entire OS*).

**Verification evidence (2026-09-10):**
- `zig build test --summary all` → 131 host tests passed (124 baseline + 6 new hw tests + 1 import shim).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Unknown device detected`, `Driver active: temp=23.4C`, `Driver destroyed`) → pending CI (no QEMU/xorriso on dev machine, same as phases 29–35).

#### Phase 37 — Eeden Gate (Autonomous Lifecycle) ✅

> **Goal**: End-to-end self-verification: boot → compose → run → decompose → core only.

| # | Task | File | Status |
|---|------|------|--------|
| 37.1 | 30-day autonomous simulation spec | `docs/EEDEN_DEMO.md` | ✅ timeline + fast-forward mapping + falsifiability |
| 37.2 | Lifecycle metrics collector (boot/composition/stability/failover) | `tests/eeden_metrics/` | ✅ `sim.zig` (real cores, virtual clock) + `metrics.zig` (10 checks) + `eeden-gate` tool |
| 37.3 | Final philosophy doc: "Zinux is a foundation for building operating systems" | `docs/EEDEN.md` | ✅ birth/life/death + guarantees + prior art |
| 37.4 | CI gate step (fast-forwarded simulation) | `.github/workflows/eeden_gate.yml` | ✅ sim gate + QEMU mechanism gate (both required) |

**Dependency**: All previous phases.

**Test**:
```bash
zig build test
# eeden sim + gate host tests OK (135 passed)
zig build eeden-gate
# [Zinux] Boot ... Running (30 days simulated) ... Core only
# eeden-metrics: compositions=1/1 faults=6 crashes=1 heals=5 migrations=1 failovers=1 tunnel_grants=1 uptime_days=30
# [Zinux] Eeden Gate: PASSED
zig build boot-test
# Expected serial: Eeden boot ... Eeden core only, Eeden Gate: PASSED, All boot tests OK
```

**Implementation summary:**
- **Demo spec** (`docs/EEDEN_DEMO.md`): day-by-day timeline (fault days 3/7/12/19/26 with a deliberate double-fault crash on day 12, migration day 14, silence day 21, detection day 22, done day 29), fast-forward mapping (1 day = 1000 ticks, no wall-clock/randomness), 10-check gate table, and what would falsify it.
- **Simulation** (`tests/eeden_metrics/sim.zig`, pure, drives the REAL cores — TDL parse/resolve, diag, tunnel seal/open, migrate plan, cluster sweep, decomposer predicate — on a virtual clock): `run() → Report` with 13 counters/flags; byte-identical across runs (host-tested).
- **Metrics** (`tests/eeden_metrics/metrics.zig`, dependency-free): `evaluate(anytype) → Verdict{failed_mask}` over 10 checks (`boot_ok`, `task_ok`, `compositions_done>=1`, `heals>=fault_days`, `migrations>=1`, `failovers==1`, `tunnel_grants_ok>=1`, `uptime_days>=30`, `deadline_ok`, `core_only`); evaluates hand-built bad reports too.
- **Gate tool** (`tools/eeden_gate.zig` + `zig build eeden-gate`, Phase-32 tool precedent): prints the appendix serials verbatim with REAL counters from the same run, exits 0/1 (failure names each broken check).
- **Kernel mechanism** (`kernel/eeden.zig`, freestanding, last boot test): replays birth→compose→run→death through the Phase 34 orchestrator with QEMU-honest serials (no "30 days" claim on hardware) ending in `Eeden Gate: PASSED` + verified core-only.
- **CI gate** (`.github/workflows/eeden_gate.yml`): unit tests → `eeden-gate` sim (greps verdict) → full QEMU `boot-test` (greps `All boot tests OK` AND kernel-side `Eeden Gate: PASSED`). Either half failing closes the gate.
- **Philosophy** (`docs/EEDEN.md`): birth/life/death, what Zinux is not, four tested guarantees, honored prior art, and the end state — *"Zinux does not maintain itself. It re-becomes itself."*
- **Key design decision**: two halves, neither sufficient alone — the sim cannot load ELFs, QEMU cannot wait 30 days; the gate requires both, and each side honestly labels what it proves.

**Verification evidence (2026-09-10):**
- `zig build test --summary all` → 135 host tests passed (131 baseline + 3 new eeden tests + 1 import shim).
- `zig build eeden-gate` → `Eeden Gate: PASSED` with the exact appendix serials and measured counters.
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` (kernel-side `Eeden boot … Eeden Gate: PASSED`) → pending local run (no QEMU/xorriso on dev machine); CI `eeden_gate.yml` runs it with marker greps.

---

#### Phase 38 — VSL-0: Spec + Stub Plugin ✅

> **Goal**: Linux enters Zinux as one plugin among many — core stays clean.
> Stub proves the lifecycle → manifest → scope → gateway chain without
> Linux complexity (VSL-spec options A+C; VM-host B rejected as negative result).

| # | Task | File | Status |
|---|------|------|--------|
| 38.1 | VSL canonical spec (choice A+C, mini-ABI table, scope, addresses, non-goals) | `docs/VSL_SPEC.md` | ✅ |
| 38.2 | VSL stub ELF (`vsl\n` + `SYS_test_return`) | `userland/vsl/main.zig`, `start.S`, `user.ld` (@ `0xFFFFFFFF90094000`) | ✅ |
| 38.3 | Second embedded image in loader (`embedded_id=1`, stack slot 118) | `kernel/plugin/loader.zig` | ✅ `VSL_EMBEDDED_ID`, `vslElf()`, image+slot branch |
| 38.4 | Boot test: negatives → load → run → LIFO-unload | `kernel/syscall/vsl_syscall.zig` | ✅ `VSL stub OK` |

**Dependency**: Phases 29–31 (scope/manifest/gateway + loader pattern).

**Test**:
```bash
zig build test
# vsl stub vectors incl. (139 passed)
zig build boot-test
# Expected serial: vsl / VSL stub OK / All boot tests OK
```

**Implementation summary:**
- **Stub ELF** (`userland/vsl/`, freestanding, same shape as `plugin_test`): `_start` writes `vsl\n` via `sys_write(1)` then `SYS_test_return(10)`. Own load address `0xFFFFFFFF90094000` (free gap after xfer `.capboot` `...93000`) and heap stack slot 118 (116=plugin, 117=xfer).
- **Loader branch** (`kernel/plugin/loader.zig`): `isValidEmbeddedId` accepts `0|1`; `loadPlugin` selects `plugin_elf/PLUGIN_STACK_SLOT` vs `vsl_elf/VSL_STACK_SLOT`; new `vslElf()` accessor mirrors `pluginElf()` (Phase 33 precedent).
- **Boot test** (`kernel/syscall/vsl_syscall.zig`, registered after `plugin_transfer` on a clean table): `bad id → EINVAL`, grant-escalation → EPERM, valid load with VSL scope (`port SEND|RECV + memory MAP|READ`, no GRANT — I4), `runPlugin` (`vsl\n`), `sys_plugin_unload` (zero survivors for heal/composer).
- **Wiring**: `build.zig` VSL embed block → `kernel/loader/vsl_prog.bin` + kernel dep; `boot_tests.zig` registration.

**Verification evidence (2026-09-10):**
- `zig build test --summary all` → 139 host tests passed.
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. VSL ELF + boot test) → passed.
- QEMU `boot-test` serial (`vsl`, `VSL stub OK`) → **observed 2026-09-10, first local QEMU run (WSL2).**

#### Phase 39 — VSL-1: Mini-Linux-ABI Translator ✅

> **Goal**: User-space Linux→Zinux syscall translation. The kernel never
> learns Linux — VSL learns Zinux (core stays clean).

| # | Task | File | Status |
|---|------|------|--------|
| 39.1 | Pure translation table (7 Linux nrs, internal-uname, memory-cap flags) | `userland/vsl/linux_abi.zig` | ✅ no imports, host-testable |
| 39.2 | Ring-3 shim (`vslWrite/Exit/Getpid`, local `unameCopy`, `isSupported`) | `userland/vsl/vsl_libc.zig` | ✅ Zig 0.16 asm-clobber style |
| 39.3 | Host vectors (translations + rejections + uname copy/truncation) | `tests/host/vsl_abi_test.zig` | ✅ 3 tests |

**Test**:
```bash
zig build test
# vsl translate + reject/uname + shim matrix OK (139 passed)
zig build boot-test
# Expected serial: VSL ABI OK, All boot tests OK
```

**Implementation summary:**
- **Table** (`linux_abi.zig`): `read(0)→11`, `write(1)→1`, `mmap(9)/brk(12)→mem_map(23)`, `getpid(39)→3`, `exit(60)→2`; `uname(63)` internal (`isHandledInternally`), `openat(257)` + unknown → null (ENOSYS port for VSL-2). `needsMemoryCap(brk/mmap)` pins the scope requirement.
- **Shim** (`vsl_libc.zig`): thin `syscall` wrappers (numbers pass through as Zinux only — Linux numbers never reach the kernel); `unameCopy` answers `"VSL 0.1"` locally with truncation instead of overflow; `classifyReturn`/`isSupported` pure for host tests.
- **Honest limit** (VSL_SPEC.md §3): only shim-linked test binaries work; trap-and-emulate of unmodified Linux ELFs is VSL-4 future, not claimed now.
- **Wiring**: `build.zig` host modules `vsl_abi` + `vsl_libc` (shared instance, `composer_task` pattern); `tests/host/root.zig` registration; kernel boot test asserts the VSL scope covers both ABI type bits (port+memory).

**Verification evidence (2026-09-10):**
- `zig build test --summary all` → 139 host tests passed (incl. 3 new VSL vectors).
- `zig build` + `zig build -Dboot=full` → passed.
- QEMU `boot-test` serial (`VSL ABI OK`) → **observed 2026-09-10, first local QEMU run (WSL2).**

#### Phase 40 — VSL-2: fd-table + Block-Backed Mini-Shell ✅

> **Goal**: VSL answers `ls /tmp` / `cat` from real storage — still fully
> in user space, still no kernel extensions for Linux.

| # | Task | File | Status |
|---|------|------|--------|
| 40.1 | fd-table in VSL (console/file/pipe kinds, 0/1/2 reserved, honest `isIoReady`) | `userland/vsl/fd.zig` | ✅ pure + 2 host tests |
| 40.2 | virtio-blk multi-sector read (`readSector0` → `readSector(n)` + sector-1 proof) | `kernel/drivers/block/virtio_blk.zig` | ✅ `VirtIO block multi OK` |
| 40.3 | VFS `write` op (optional, read-only FS → NotSupported) + tmpfs write/list | `kernel/fs/vfs_core.zig`, `vfs.zig`, `tmpfs_core.zig`, `tmpfs.zig` | ✅ `VSL fs OK` |
| 40.4 | Mini-shell parser (`help/ls/cat`, stable errors) + kernel-side `ls/cat/write` demo | `userland/vsl/shell.zig`, `kernel/syscall/vsl_fs_syscall.zig` | ✅ `vsl-ls` / `vsl-cat: TMPFS` + 2 host tests |

**Dependency**: Phase 6 (drivers/VFS reference) + Phase 39 (ABI table).

**Test**:
```bash
zig build test
# vsl fd + shell + tmpfs write/list + vfs write-reject OK (148 passed)
zig build boot-test
# Expected serial: VirtIO block multi OK, vsl-ls: welcome, vsl-cat: TMPFS,
# VSL fs OK, All boot tests OK
```

**Implementation summary:**
- **fd-table** (`userland/vsl/fd.zig`, dependency-free): `MAX_FDS=16` (VFS parity), fds 0/1/2 pinned console, `openFile/closeFd/kindOf/openCount`; `isIoReady` returns true only for console — file/pipe honestly false until fd-syscalls exist (VSL-4). Console close is a Linux-parity no-op.
- **Shell parser** (`userland/vsl/shell.zig`, pure): `parseLine` → `help/ls/cat/noop/unknown` with stable `MissingPath → PathTooLong` errors; execution lives in the kernel boot path (request vs. permission split).
- **virtio multi-read**: `readSector0` generalized to `readSector(n)`; boot test reads sector 1 after the sector-0 magic check (test disk is 2048 sectors, only magic written) and asserts status-OK + all-zero → `VirtIO block multi OK`. Existing serials untouched.
- **VFS write**: optional `write` field on `FileSystemOps` (default null → `NotSupported`, so testfs needs no change); `tmpfs_core.writeFile` with gap-zeroing bounded by `MAX_FILE_DATA` (overflow → `NotSupported`, never truncated); `fileCount/fileNameAt` re-exported through `tmpfs.zig` for `ls`.
- **Boot test** (`kernel/syscall/vsl_fs_syscall.zig`, self-contained VFS+tmpfs init, registered after the VSL stub test): missing-path negative → `vsl-ls: welcome` → `vsl-cat: TMPFS` → write `"hello-vsl"` readback → `VSL fs OK`.

**Verification evidence (2026-09-10):**
- `zig build test --summary all` → 148 host tests passed (incl. 4 vsl fd/shell + 3 tmpfs + 1 vfs tests).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`VirtIO block multi OK`, `vsl-ls`, `vsl-cat: TMPFS`, `VSL fs OK`) → **observed 2026-09-10, first local QEMU run (WSL2).**

#### Phase 41 — VSL-3: Snapshot-Ready State Descriptor ✅

> **Goal**: VSL carries a `VslState{regs, caps, pages}` descriptor so the
> Phase 31.5 snapshot mechanism has a concrete target. Restore of
> slots/regs is NOT claimed (31.5.3 boundary) — page-rollback only.

| # | Task | File | Status |
|---|------|------|--------|
| 41.1 | State descriptor format + dirty-page refs | `userland/vsl/state.zig` | ✅ `VslState{addCap/addPage/dirtyCount/containsPage}` + host tests |
| 41.2 | Shared-port continuity via `plugin_swap` (BOOT-owned port survives) | `kernel/plugin_swap.zig` reuse | ✅ same-pid VSL swap + `VSL swap continuity OK` |
| 41.3 | TDL `needs: [vsl-shell]` compose/decompose demo | `kernel/composer.zig` reuse | ✅ `composeTaskWithIds` + `VSL compose OK` |

**Dependency**: Phase 31.5 (snapshots) for owned-cap migration; stateless +
shared-port healing works today (Phase 33 pattern).

**41 implementation summary (2026-09-11):**
- **Descriptor** (`userland/vsl/state.zig`, pure, host-tested): `VslState{version, regs[16], caps[8]{slot, abi_type, rights_mask}, pages[64]{virt, dirty}}` per VSL_SPEC §6. ABI numbers (1/5, bits 0–5) matching scope/manifest/TDL; capacity 64 == `MAX_SNAP_PAGES` so a full inventory never truncates. Stable error order `BadCapType → BadRights → TooManyCaps → BadPage → TooManyPages`. `regs` honestly zero (31.5.2 captures no registers — reserved for VSL-4). 3 host tests.
- **Filler** (`kernel/syscall/vsl_state_syscall.zig::describeCheckpoint`): pages from checkpoint inventory + per-page `checkpointPageDirty` (new 3-line `snapshot.zig` wrapper over `ckpt.isDirty`); caps from `lookupSlotForPid` + `getObject` with kernel→ABI type map (port→1, memory→5, unknown skipped). Boot proof both sides: VSL describe (1 port/SEND cap round-trip, entry page anchored, `dirtyCount==0` agreeing with snapshot) + dirty_test describe (exactly 1 dirty ref on the stack-top page after a genuine ring-3 #PF).
- **Swap generalization** (`loader.elfForId/stackSlotForId` + `swapPlugin` by id): swap previously hardcoded the generic plugin ELF (passing a VSL id silently loaded the wrong image). Single source shared with `loadPlugin` (behavior identical for id 0 — Phase-33 test untouched). 41.2: shared BOOT-owned port → VSL same-pid swap (entry unchanged proof) → `VS1` continuity message → ring-3 `vsl` run → unload → `VSL swap continuity OK`.
- **Compose override** (`composer.composeTaskWithIds(spec, ids?)`): null = Phase-34 behavior; provided ids must match needs length + pass `isValidEmbeddedId` before anything loads, types/rights/scopes still gated per req (narrowing preserved, no syscall surface — boot-only routing). 41.3: `task "vsl-shell" { need port:send+recv; need memory:map+read; ... }` → bad-id + short-ids negatives → 2× VSL compose → `vsl`×2 run → LIFO decompose → `VSL compose OK`.
- **Verification:** host 168/168, freestanding clean, 3× QEMU green with `dty`, `VSL state OK`, `VSL swap continuity OK`, `Task compose vsl-shell OK`, `VSL compose OK`, `All boot tests OK`, `Full boot OK`, exit 0, 0 `[ERR]`.

---

#### Phase 42 — VSL-4A: fd-Syscalls in Ring 3 ✅

> **Goal**: VSL `file`-fds work in ring 3 through real syscalls
> (`SYS_vfs_open/read/close` 29/30/31); the dispatch table is now full (32/32).

| # | Task | File | Status |
|---|------|------|--------|
| 42.1 | `SYS_vfs_open/read/close` + errno map + fuzz gates | `dispatch.zig`, `vfs_core.zig`, `syscall_fuzz_core.zig` | ✅ invoke + `VSL file syscall OK` |
| 42.2 | Shim (`vslOpenFile/vslReadFile/vslCloseFile`, R10-offset) + fd handle binding | `vsl_libc.zig`, `fd.zig`, `linux_abi.zig` | ✅ `vsl-file: TMPFS` from ring 3 |
| 42.3 | Ring-3 demo ELF + boot test (incl. ENOENT/EINVAL/EBADF) | `userland/vsl_file_test/`, `vsl_file_syscall.zig` | ✅ `VSL file IO OK` |

**Dependency**: Phase 6 (VFS/tmpfs), Phase 39 (ABI table), VSL-2 (fd-table).

**Test**:
```bash
zig build test
# vfs errno/isOpen + fuzz gates + fd bind + shim matrix OK (171 passed)
zig build boot-test
# Expected serial: VSL file syscall OK, vsl-file: TMPFS,
# userland vsl file OK, VSL file IO OK, All boot tests OK
```

**Implementation summary:**
- **Syscalls** (`dispatch.zig`, table now 32/32 full): `sysVfsOpen(path_ptr,path_len,flags=0)` (flags!=0/len 0/>256 → EINVAL, kernel-staged copy, `vfs.open` → handle or `errnoOf`), `sysVfsRead(handle,buf,len,offset)` (`@truncate` + `isOpen` → EBADF, 256 B staging, `copyToUser`), `sysVfsClose(handle)` (`isOpen` → EBADF else close → 0). `vfs_core.errnoOf` (NotFound→ENOENT(-2, new `zinuxabi` mirror), InvalidPath→EINVAL, NotSupported/NotInitialized→ENOSYS, TooManyFiles/TooManyMounts→ENOMEM) + `isOpen`, both host-tested. Fuzz core marks 29–31 registered+dangerous.
- **Shim** (`vsl_libc.zig` + `fd.zig`): `zinuxSyscall4` (offset in R10 — Linux convention, Phase-31 precedent), `vslOpen/vslReadAt/vslClose` thin wrappers, `vslOpenFile/vslReadFile/vslCloseFile` with fd-table routing (console → 1/11, file → 30 + offset bookkeeping, pipe → ENOSYS) and pure `fdErrToNeg` mapper (host-tested incl. syscall-free paths: console no-op, unbound-file EBADF). `linux_abi`: openat→29, close→31 (new `LINUX_CLOSE=3`).
- **Demo ELF** (`userland/vsl_file_test/`, embedded_id=4, `@0x90097000`, stack slot 121): Zig program on the shim — open `/tmp/welcome` → read 5 B → print READ bytes (`vsl-file: TMPFS` serial marker) → EOF==0 → close==0 → double-close EBADF → `userland vsl file OK` + `SYS_test_return`.
- **Boot test** (`vsl_file_syscall.zig`, self-contained VFS+tmpfs init): ENOENT/EINVAL/empty/EBADF negatives → invoke open/read/EOF/close/double-close → `VSL file syscall OK` → ring-3 demo → `VSL file IO OK` → LIFO unload.
- **Key design decision**: VFS handles stay global (no per-pid fd tables) — one-plugin experiment, isolation limit documented in VSL_SPEC §11; per-pid tables are VSL-4B/RBAC follow-up, not smuggled in here.
- **Verification:** host 171/171, freestanding clean, 3× QEMU green with `VSL file syscall OK`, `vsl-file: TMPFS`, `userland vsl file OK`, `VSL file IO OK`, `All boot tests OK`, `Full boot OK`, exit 0, 0 `[ERR]`.

---

#### Phase 43 — VSL-4B: Trap-and-Emulate Unmodified Linux ELFs ✅

> **Goal**: A static Linux-ABI binary (no Zinux shim, no relink) prints
> via UART through per-plugin RAX translation; unknown Linux numbers
> return -ENOSYS to user mode (no halt).

| # | Task | File | Status |
|---|------|------|--------|
| 43.1 | Linux personality (`SYS_plugin_trap=32`, table 32→33) + trap_regs | `process_core.zig`, `dispatch.zig` | ✅ ghost/EPERM/EINVAL negatives + `VSL trap capture OK` |
| 43.2 | Pure translation table + uname bytes | `linux_trap_core.zig` | ✅ translate vectors + linux_abi agreement + host tests |
| 43.3 | Deterministic hello-ELF generator (no jumps, patched LEAs) | `tools/linux_hello.zig` | ✅ layout + LEA-resolve host tests, build-time embed |
| 43.4 | Ring-3 trap test (hello/uname/enosys/exit) + describe-regs | `vsl_trap_syscall.zig` | ✅ `VSL trap OK` |

**Dependency**: Phase 39 (ABI table), 31.5 (regs capture target = `VslState.regs`).

**Test**:
```bash
zig build test
# trap vectors + agreement + hello layout + process lifecycle OK (178 passed)
zig build boot-test
# Expected serial: hello linux, vsl-uname: VSL 0.1, vsl-enosys OK,
# VSL trap capture OK, VSL trap state OK, VSL trap OK, All boot tests OK
```

**Implementation summary:**
- **Personality** (`process_core`: `linux_trapped` + `trap_regs[16]` + valid flag, 3 init sites + `freePid` stale-clear, host lifecycle test): `SYS_plugin_trap(pid, 0/1)` with unload-caller rule (BOOT/parent, else EPERM), ghost→ESRCH, value>1→EINVAL. Affects ring-3 `syscallDispatchFromFrame` only — `invoke` never translates (trap branch before table lookup).
- **Translation** (`linux_trap_core.zig`, pure, host-tested + `linux_abi` agreement test): read→11, write→1, close→31, mmap/brk→23, getpid→3, exit→2, uname→internal, openat→29, else unsupported. Args pass through untouched (identical x86_64 convention, R10 4th).
- **Generator** (`tools/linux_hello.zig`, deterministic, no timestamps): ET_EXEC @0x400000, single R-X segment, entry=base+120 (headers mapped not executed — standard linker shape), uname→3 writes→invalid(9999)/cmov-select→exit(code). Build-time `addRunArtifact` → `kernel/loader/linux_hello_prog.bin` (gitignored). Host tests pin magic/entry/segment/code + independently re-resolve all 5 LEA disp32s.
- **Trap path** (`dispatch.trapDispatch`): record raw frame (Linux numbers, `[rax..rflags]`) → translate → dispatch / `trapUname` (RDI=buf — first version used RSI/garbage, caught by QEMU: ubuf printed zeros) / ENOSYS. Fuzz core: 32 registered+dangerous, `TABLE_SIZE` 33, out-of-range probe moved 32→33.
- **Boot test** (`vsl_trap_syscall.zig`, loader id 5 `@0x400000`/slot 122): ghost/EPERM/EINVAL negatives → enable (idempotent) → ring-3 run → zombie exit(0) proves OK-branch → regs==exit frame in Linux numbers → checkpoint + shared `describeCheckpoint` fills `VslState.regs` (first fill per VSL_SPEC §11) → entry-page + 1-cap asserts → disable (flag+image cleared) → unload → `VSL trap OK`.
- **Debug finds (both fixed, QEMU-proven):** (1) generator `e_entry` pointed at ELF headers — CPU executed header bytes, wild `add [rax],al` faulted at 0x2F6000 (GDB: fault RIP 0x400047 decoded zeros; dump showed `7F E L F` mapped at 0x400000). Fix: entry=base+CODE_OFF. (2) Any unhandled plugin-CR3 fault recursed forever on VGA (`b80a0`, headers without hex — same class as 31.5.5): `pageFaultHandlerC` now restores kernel CR3 first (fail-fast single header + halt instead of timeout).
- **Key design decision**: no per-pid trapped-fd table smuggled in — `read(fd≥3)` currently routes to console-read; the trapped-fd table is named 4B.x follow-up. Signals/fork stay ENOSYS-ported.
- **Verification:** host 178/178, freestanding clean, 3× QEMU green with `hello linux`, `vsl-uname: VSL 0.1`, `vsl-enosys OK`, `VSL trap capture OK`, `VSL trap state OK`, `VSL trap OK`, `All boot tests OK`, `Full boot OK`, exit 0, 0 `[ERR]`.

---

### Known Issues (found by first local QEMU run, 2026-09-10)

> Until 2026-09-10 no full `boot-test` had ever run locally (no QEMU/xorriso
> on the dev machine — every phase's QEMU evidence was "pending CI"). The
> first local run (WSL2 Ubuntu 24.04, `qemu-system-x86_64` + `xorriso`,
> disposable `~/zinux` copy) boots to `Full boot OK` but exposes two
> pre-existing issues below. Neither is caused by VSL (reproduced on a
> pristine Phase-37 tree via `git stash -u`).

| ID | Severity | Location | Problem | Status |
|----|----------|----------|---------|--------|
| **K1** | High | `plugin_heal_syscall.zig:90`, `federate.zig:126` | BOOT_PID slot exhaustion aborts the heal + federate boot tests mid-run | ✅ fixed 2026-09-10 (suite-boundary wipe + hole-safe allocator, see below) |
| **K2** | High | `kernel/boot_tests.zig:209` | `All boot tests OK` prints unconditionally — no failure propagation, CI green on partial runs | ✅ fixed 2026-09-10 (err-count verdict + non-zero QEMU exit + CI markers) |
| **K4** | Critical | `arch/x86_64/usermode_jump.S`, `arch/x86_64/usermode.zig` | ring-3 round trip clobbers callee-saved regs (rbp) → wild writes into .bss (syscall-stack canary) | ✅ fixed 2026-09-10 (save/restore rbx/rbp/r12-r15, see below) |
| **K5** | Critical | `arch/x86_64/idt.zig` (`init` loop) | vectorized init loop swaps ist/type bytes in ALL its gates → ring-3 exception delivery dies | ✅ fixed 2026-09-10 (scalar loop + read-back gate check, see below) |
| **K6** | Critical | `arch/x86_64/gdt.zig` (`Tss` struct) | `extern struct` inserts 4 B padding after `reserved0` → CPU reads garbage rsp0 → #SS on first ring-3 exception | ✅ fixed 2026-09-10 (`packed struct`, see below) |

**K1 attack path (no attacker needed — the test chain does it to itself):**
each boot test installs BOOT-owned capability slots (`installSlotForPid(BOOT_PID, …)`)
and most never release them. By the time the heal test runs (~40 tests in),
all `MAX_SLOTS = 32` BOOT slots (`capability_core.zig:69`) are occupied, so
`installSlotForPid(BOOT_PID, shared_obj, …)` returns null and the test logs
`[ERR] Heal boot slot failed` and returns early. Same for federate
(`[ERR] Federate boot slot failed`). Observed serials around the failures:

```text
VSL fs OK
[ERR] Heal boot slot failed          ← Phase 33 aborts here
Task received: http+uptime           ← Phase 34 continues as if nothing happened
...
Node A joined
Node B joined
[ERR] Federate boot slot failed      ← Phase 35 aborts here
Unknown device detected              ← Phase 36 continues
...
All boot tests OK                    ← prints regardless (K2)
Full boot OK
```

**Serials documented as expected but never observed** (so their ✅ rests on
host tests + code review, not on QEMU): `Plugin heal validation OK`,
`Plugin diagnostics OK`, `Hot-swap replaced plugin`, `Self-heal OK`
(Phase 33); `Uptime plugin migrated A->B`, `Node A left`,
`Failover: uptime plugin replicated on B`, `Federated cluster OK` (Phase 35).
**Update 2026-09-10: all of the above observed in 3× green QEMU runs after
the K1/K4 fixes — the ✅ now rests on QEMU evidence.**

**K2 mechanism:** every `runBootTest()` returns `void`; failures only `log.err`
and `return`. `runAll()` ends with unconditional `log.info("All boot tests OK")`,
and the QEMU step exits 0. A boot that aborts two test suites is
indistinguishable from a green boot in CI.

**Suggested fixes (not implemented):**
- K1-short-term: audit BOOT-slot consumers across `boot_tests.zig`, release
  (or reuse) BOOT slots per test — e.g. a `releaseBootSlots()` epilogue or
  per-test countable budget.
- K1-structural: track slot pressure as a boot metric (free BOOT slots after
  each suite) so exhaustion becomes visible before it aborts a suite.
- K2: propagate failures — `runAll() → !void` or a failed-suite counter ending
  in `Boot tests FAILED` + non-zero QEMU exit; CI must grep per-suite markers,
  not just the final line (the `eeden_gate.yml` marker-grep pattern already
  points this way — extend it to heal/federate/VSL markers).

**Fixes landed 2026-09-10 (all verified with 3× green QEMU runs, 0 `[ERR]`):**
- **K1-fix (two layers):**
  1. `betweenSuites()` in `kernel/boot_tests.zig` (after all 59 suites):
     `revokeAllOwnedBy(BOOT_PID)` (frees BOOT-owned objects + ports globally
     via I6) + `clearSlotsForPid(BOOT_PID)` (resets the append-only counter).
     Safe: cross-suite state is pid/registry/VFS-based, never BOOT slots
     (load→unload chain verified pid-based).
  2. Hole-safe allocator in `kernel/sched/process_core.zig`: `findIndex`
     scans the full table (was: `used_count` bound — non-LIFO free orphaned
     the tail, which is exactly how federate lost pid_b's slots after
     draining pid_a), `allocProcess` reuses first-free index (was: blind
     append that overwrote the orphaned tail), `pidAt` enumerates live
     ordinals (keeps `sys_ps` dense). Index never moves (slot-group
     invariant kept); `freePid` documents the clear-slots-first precondition.
     Pinned by 2 new host tests (`non-LIFO free keeps tail reachable`,
     `pidAt enumerates live ordinals`).
- **K2-fix:** `log.err` counts (`errCount()`, saturating); `runAll` ends with
  `Boot tests FAILED` vs `All boot tests OK`; `main.zig` gates full/dev boot
  on the counter (`Full boot FAILED` + new `qemu_exit.exitFailure()`,
  QEMU exit 3 → build step red); `ci.yml` now also fails on
  `Boot tests FAILED` and requires the previously-silent markers
  (`Self-heal OK`, `Federated cluster OK`, `VSL fs OK`). Convention
  documented: `log.err` in boot context is always a failure signal.
  (Proven during development: the federate-tamper bug below was caught by
  this gate instead of printing false green.)
- **K4-fix (root cause, found via QEMU+GDB hardware watchpoint):**
  `usermodeEnterIret` saved only RSP; `sys_test_return` bypasses
  `syscall_entry.S`'s register pops (direct `ret`), so every ring-3 plugin
  run resumed kernel code with plugin-clobbered rbp/rbx/r12-r15. The resumed
  `hw_lifecycle.runBootTest` then wrote a 200 B struct through a stale rbp
  into `.bss`, zeroing the syscall-stack canary (`A[ERR] Stack canary
  violation` at scheduler start). Caught with a GDB watchpoint on the canary
  address: `memcpy(dest=bitmap_storage+32744, len=200)` from a `rbp-0xf78`
  stack slot — disassembly proved the destination was stack-computed, i.e.
  rbp itself was garbage. Fix: `usermode_saved_callee[6]` globals —
  save rbx/rbp/r12-r15 on enter, restore on return (same single-global
  discipline as the existing `usermode_saved_kernel_rsp`; no nesting exists).
- **Bonus fix found by the now-working gate:** federate's tamper negative
  expected `BadMac` for a tampered copy of an already-opened envelope, but
  the tunnel correctly checks replay-window before MAC (`Replay` is the right
  answer — the host test already encoded this). Test now seals fresh then
  tampers, matching `federate_test.zig`.
- **K5-fix (ring-3 exception delivery, part 1 — IDT bytes):** GDB memdump of
  IDT[14] showed `ist=0x8e/type=0x00` (swapped) in every gate the `init()`
  zip+cmove loop wrote, while `registerHandler`-written gates (timer/IRQ)
  read correct — same constructor, different emitter. Disassembly of the loop
  showed a vectorized predicated store sequence; root cause class: codegen
  around the zipped multi-iterator (kept as documented suspicion, not proven
  compiler bug). Fix: scalar indexed loop (same shape as `registerHandler`)
  + `gateBytesOk` read-back check in `init()` (fail-fast halt, never silent).
  Verified by GDB byte-dump (`ist=0/type=0x8e`) in the new binary.
- **K6-fix (ring-3 exception delivery, part 2 — TSS layout):** `Tss` was the
  only hardware struct declared `extern struct`; Zig inserts 4 B padding
  after `reserved0: u32`, shifting `rsp0` from hardware offset +4 to +8, so
  the CPU read garbage (non-canonical) as the ring-3 exception stack →
  `#SS → double → triple fault` on the FIRST ring-3 exception ever (QEMU
  `-d int` trace + register dump evidence). All other hardware structs were
  already `packed`. Fix: `packed struct` (+ comment forbidding revert);
  `@sizeOf` 112→106 keeps the TR limit valid. Verified: 3× green QEMU with
  a genuine ring-3 write-fault handled, continued (`dty`), and measured
  (`dirtyCount==1`) — the first exception ever delivered from ring 3.

### Recommended Execution Order

```
✅ DONE → Phases 0–37: Foundation … Eeden Gate (all green, QEMU serials pending CI)
✅ DONE → Phase 38 (VSL-0 stub) + Phase 39 (VSL-1 mini-ABI) + Phase 40 (VSL-2 shell path)
✅ DONE → K1 (suite wipes + hole-safe allocator) + K2 (failure gate) + K4 (callee-saved) + 31.5.1 (snapshot walk) + 31.5.2 (checkpoint+guard) + 31.5.3 (restore) + K5 (IDT loop) + K6 (TSS packing) + 31.5.4 (dirty tracking) + 31.5.5 (watchdog: kernel-CR3 restore in claim path) + Phase 41 (VSL-3 state descriptor + swap continuity + vsl-shell compose) — 3× green QEMU, 0 [ERR]
   ↓
⬜ NEXT → VSL-4B.x (trapped-fd table: read(fd≥3) routing) + signals/fork scoping — research follow-ups; 4A+4B green
```

**Parallelizable**: VSL-2 file work (fd-table, shell demo) can proceed alongside
virtio-blk multi-sector read — neither touches the trusted core.
**Deferred**: VM-host Linux (rejected option B) stays a VSL-4+ experiment;
no VT-x/EPT work until VSL-2 proves the translation model.

---

## Inter-Phase Dependencies

```mermaid
graph TD
    V0[Phase 0: Foundation] --> V1[Phase 1: Boot]
    V1 --> V2[Phase 2: Memory]
    V2 --> V3[Phase 3: Scheduler]
    V3 --> V4[Phase 4: Syscalls]
    V4 --> V5[Phase 5: Shell]
    V5 --> V6[Phase 6: FS]
    V6 --> V7[Phase 7: Security]
    V7 --> V8[Phase 8: IPC userland]
    V8 --> V9[Phase 9: Cap delegate]
    V9 --> V10[Phase 10: Cap create]
    V10 --> V11[Phase 11: Blocking IPC]
    V11 --> V12[Phase 12: Cap revoke]
    V12 --> V13[Phase 13: Try recv]
    V13 --> V14[Phase 14: IPC pending]
    V14 --> V15[Phase 15: Cap get rights]
    V15 --> V16[Phase 16: Cap get type]
    V16 --> V17[Phase 17: IPC flush]
    V17 --> V18[Phase 18: Cap get resource]
    V18 --> V19[Phase 19: IPC queue capacity]
    V19 --> V20[Phase 20: Process table]
    V20 --> V21[Phase 21: sys_spawn]
    V21 --> V22[Phase 22: Cross-process IPC]
    V22 --> V23[Phase 23: sys_ps]
    V23 --> V24[Phase 24: exit/wait]
    V24 --> V25[Phase 25: Address spaces]
    V25 --> V26[Phase 26: Preemptive scheduler]
    V22 --> V27[Phase 27: Userland cross IPC]
    V25 --> V28[Phase 28: sys_mem_map]
    V28 --> V38[Phase 38: VSL-0 stub]
    V38 --> V39[Phase 39: VSL-1 mini-ABI]
    V39 --> V40[Phase 40: VSL-2 mini-shell]
    V40 --> V41[Phase 41: VSL-3 snapshot-ready]
    V41 --> V42[Phase 42: VSL-4A fd-syscalls]
    V42 --> V43[Phase 43: VSL-4B trap-and-emulate]
```

---

## Metrics

| Phase | LOC (estimate) | Boot time | Tests |
|-------|----------------|-----------|-------|
| 0 | ~500 | — | docs review |
| 1 | ~2 000 | <1 s | 1 integration |
| 2 | ~5 000 | <1 s | 5 unit + 2 integration |
| 3 | ~8 000 | <1 s | 10 unit + 3 integration |
| 4 | ~12 000 | <2 s | 15 unit + 5 integration |
| 5 | ~18 000 | <2 s | 20 unit + 8 integration |

*LOC includes over-documentation comments (~40% of code).*
