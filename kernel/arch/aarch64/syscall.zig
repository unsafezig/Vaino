//! ARM64 Phase 2:n pienin EL0-syscall-polku.

const uart = @import("uart.zig");
const semihost = @import("semihost.zig");
const frame_abi = @import("exception_frame.zig");
const process = @import("process.zig");
const cap_ipc = @import("cap_ipc.zig");
const storage = @import("storage.zig");
const clock = @import("clock.zig");
const datagram = @import("datagram.zig");
const shfile = @import("semihost_file.zig");
const crypto_selftest = @import("gringots/selftest.zig");

pub const Aarch64ExceptionFrame = frame_abi.Aarch64ExceptionFrame;

pub const SYS_IPC_SMOKE: u64 = 0;
pub const SYS_EXIT: u64 = 1;
pub const SYS_START_HELLO: u64 = 2;
pub const SYS_HELLO_DONE: u64 = 3;
pub const SYS_IPC_CREATE: u64 = 4;
pub const SYS_IPC_SEND: u64 = 5;
pub const SYS_IPC_RECV: u64 = 6;
pub const SYS_STORE_WRITE: u64 = 7;
pub const SYS_STORE_READ: u64 = 8;
pub const SYS_CLOCK_MONO: u64 = 9;
pub const SYS_CLOCK_WALL: u64 = 10;
pub const SYS_DATAGRAM_SEND: u64 = 11;
pub const SYS_DATAGRAM_RECV: u64 = 12;
pub const SYS_DATAGRAM_SYNC_OUT: u64 = 13;
pub const SYS_DATAGRAM_SYNC_IN: u64 = 14;
pub const SYS_CRYPTO_SELFTEST: u64 = 15;
pub const IPC_SMOKE_REQUEST: u64 = 0x49504331; // "IPC1"
pub const IPC_SMOKE_RESPONSE: u64 = 0x49504332; // "IPC2"

// EL0:n oma pino. Kernelin SP_EL1 säilyy exception-paluita varten.
pub export var init_stack: [4096]u8 align(16) linksection(".bss") = undefined;
pub export var hello_stack: [4096]u8 align(16) linksection(".bss") = undefined;

// Demo-portin kahva initiltä hellolle. Sama fyysinen muisti (MMU pois),
// joten pelkkä .bss-muuttuja riittää tässä vaiheessa.
pub var demo_port: u64 linksection(".bss") = 0;

// KiB-luokan puskurit staattisina: pinoalustus (`={0}`-literaali tai
// ReleaseSafen `undefined`-täyttö) kääntyisi NEON-muistioperaatioiksi,
// jotka kaatuvat ilman FP/SIMD-tilaa. .bss:n nollaa bootin skalaarisilmukka.
var dgram_buf: [1034]u8 linksection(".bss") = undefined;
var recv_slot: datagram.Slot linksection(".bss") = undefined;
var rx_tmp: datagram.Slot linksection(".bss") = undefined;
var sync_tmp: datagram.Slot linksection(".bss") = undefined;

var init_process: process.Process = undefined;
var hello_process: process.Process = undefined;
var saved_init_frame: Aarch64ExceptionFrame = undefined;

pub extern fn aarch64_enter_init() callconv(.c) noreturn;

pub fn initProcessRecords() void {
    init_process = .{
        .pid = process.init_pid,
        .state = .running,
        .entry = @intFromPtr(&aarch64_init_entry),
        .stack_top = @intFromPtr(&init_stack) + init_stack.len,
        .parent = 0,
    };
    hello_process = .{
        .pid = process.hello_pid,
        .state = .ready,
        .entry = @intFromPtr(&aarch64_hello_entry),
        .stack_top = @intFromPtr(&hello_stack) + hello_stack.len,
        .parent = process.init_pid,
    };
    cap_ipc.reset();
    storage.reset();
    clock.reset();
    datagram.reset();
    demo_port = 0;
}

inline fn setUserStack(stack_top: u64) void {
    asm volatile ("msr sp_el0, %[stack]"
        :
        : [stack] "r" (stack_top),
        : .{ .memory = true });
}

// Keep the first context switch independent of EL1 FP/SIMD enablement.
inline fn copyFrame(dst: *volatile Aarch64ExceptionFrame, src: *const volatile Aarch64ExceptionFrame) void {
    dst.x0 = src.x0;
    dst.x1 = src.x1;
    dst.x2 = src.x2;
    dst.x3 = src.x3;
    dst.x4 = src.x4;
    dst.x5 = src.x5;
    dst.x6 = src.x6;
    dst.x7 = src.x7;
    dst.x8 = src.x8;
    dst.x9 = src.x9;
    dst.x10 = src.x10;
    dst.x11 = src.x11;
    dst.x12 = src.x12;
    dst.x13 = src.x13;
    dst.x14 = src.x14;
    dst.x15 = src.x15;
    dst.x16 = src.x16;
    dst.x17 = src.x17;
    dst.x18 = src.x18;
    dst.x19 = src.x19;
    dst.x20 = src.x20;
    dst.x21 = src.x21;
    dst.x22 = src.x22;
    dst.x23 = src.x23;
    dst.x24 = src.x24;
    dst.x25 = src.x25;
    dst.x26 = src.x26;
    dst.x27 = src.x27;
    dst.x28 = src.x28;
    dst.x29 = src.x29;
    dst.x30 = src.x30;
    dst.esr_el1 = src.esr_el1;
    dst.elr_el1 = src.elr_el1;
    dst.spsr_el1 = src.spsr_el1;
    // FP state follows the service across the hello handoff (FP is
    // enabled guest-wide; the vector preserves q-regs around SVC).
    var qi: usize = 0;
    while (qi < 32) : (qi += 1) dst.q[qi] = src.q[qi];
    dst.fpcr = src.fpcr;
    dst.fpsr = src.fpsr;
}

// EL0-demo: kiinteät 8-tavuiset tunnisteet capability-, storage- ja
// hello-vaihdon tarkastukseen QEMU-portissa.
const HELLO_WORD: u64 = 0x48454C4C4F212121; // "HELLO!!!"
const STORAGE_WORD: u64 = 0x53544F5245442121; // "STORED!!"
const STORAGE_OFF: u64 = 0;

fn el0Fail() noreturn {
    while (true) asm volatile ("wfi" ::: .{ .memory = true });
}

fn el0Smoke() void {
    asm volatile ("mov w0, #0x4331; movk w0, #0x4950, lsl #16; mov x8, xzr; svc #0" ::: .{ .memory = true });
}

// Yksi asm-ulostulo (x0) per kutsu; loput kulkevat EL0-osoittimien kautta
// (sama fyysinen muisti, MMU pois). Osoitin sisään, status x0:sta ulos.
const RecvOut = struct { len: u64, word: u64 };

fn el0Create(rights: u64) u64 {
    var h: u64 = 0;
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_IPC_CREATE),
          [rights] "{x1}" (rights),
          [out] "{x2}" (@intFromPtr(&h)),
        : .{ .memory = true });
    if (st != cap_ipc.OK) el0Fail();
    return h;
}

fn el0Send(handle: u64, len: u64, word: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_IPC_SEND),
          [handle] "{x1}" (handle),
          [len] "{x2}" (len),
          [word] "{x3}" (word),
        : .{ .memory = true });
    return st;
}

fn el0Recv(handle: u64) struct { st: u64, len: u64, word: u64 } {
    var out: RecvOut = .{ .len = 0, .word = 0 };
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_IPC_RECV),
          [handle] "{x1}" (handle),
          [out] "{x2}" (@intFromPtr(&out)),
        : .{ .memory = true });
    return .{ .st = st, .len = out.len, .word = out.word };
}

fn el0StoreWrite(offset: u64, word: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_STORE_WRITE),
          [offset] "{x1}" (offset),
          [word] "{x2}" (word),
        : .{ .memory = true });
    return st;
}

fn el0StoreRead(offset: u64) struct { st: u64, word: u64 } {
    var word: u64 = 0;
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_STORE_READ),
          [offset] "{x1}" (offset),
          [out] "{x2}" (@intFromPtr(&word)),
        : .{ .memory = true });
    return .{ .st = st, .word = word };
}

fn el0Mono() u64 {
    var ticks: u64 = 0;
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_CLOCK_MONO),
          [out] "{x1}" (@intFromPtr(&ticks)),
        : .{ .memory = true });
    if (st != clock.OK) el0Fail();
    return ticks;
}

fn el0Wall() u64 {
    var v: u64 = 0;
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_CLOCK_WALL),
          [out] "{x1}" (@intFromPtr(&v)),
        : .{ .memory = true });
    return st;
}

fn el0DgramSend(raw: [*]const u8, len: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_DATAGRAM_SEND),
          [raw] "{x1}" (@intFromPtr(raw)),
          [len] "{x2}" (len),
        : .{ .memory = true });
    return st;
}

fn el0DgramRecv(out: *datagram.Slot, max: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_DATAGRAM_RECV),
          [out] "{x1}" (@intFromPtr(out)),
          [max] "{x2}" (max),
        : .{ .memory = true });
    return st;
}

fn el0SyncOut() u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_DATAGRAM_SYNC_OUT),
        : .{ .memory = true });
    return st;
}

fn el0SyncIn() u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_DATAGRAM_SYNC_IN),
        : .{ .memory = true });
    return st;
}

fn el0CryptoSelftest() u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_CRYPTO_SELFTEST),
        : .{ .memory = true });
    return st;
}

// Canned host reply the file-shim writes (tools/datagram_shim.zig).
// EL0 verifies the full RX datagram against it.
const BRIDGE_REPLY = "BRIDGE-REPLY-01";

// Ensimmäinen oikea ARM64-userland entry. Se kulkee SVC-rajapinnan kautta.
pub export fn aarch64_init_entry() callconv(.c) noreturn {
    el0Smoke();

    const h1 = el0Create(cap_ipc.RIGHT_ALL);
    demo_port = h1;
    if (el0Send(h1, 8, HELLO_WORD) != cap_ipc.OK) el0Fail();

    const h2 = el0Create(cap_ipc.RIGHT_SEND);
    if (el0Send(99, 1, 0) != cap_ipc.BAD_HANDLE) el0Fail();
    const rej = el0Recv(h2);
    if (rej.st != cap_ipc.BAD_RIGHTS) el0Fail();
    if (el0Send(h1, 999, 0) != cap_ipc.TOO_LARGE) el0Fail();

    if (el0StoreWrite(STORAGE_OFF, STORAGE_WORD) != storage.OK) el0Fail();
    const sr = el0StoreRead(STORAGE_OFF);
    if (sr.st != storage.OK or sr.word != STORAGE_WORD) el0Fail();
    const sr_bad = el0StoreRead(storage.SIZE);
    if (sr_bad.st != storage.BAD_RANGE) el0Fail();

    const t1 = el0Mono();
    const t2 = el0Mono();
    if (t2 < t1) el0Fail();
    if (el0Wall() != clock.NOT_READY) el0Fail();

    {
        // encode() writes every byte SEND reads; RECV fills recv_slot on
        // success (EMPTY here, so its old contents are never read).
        if (datagram.encode(0x01, "HELLO-DATAGRAM", &dgram_buf) != datagram.OK) el0Fail();
        const total: u64 = datagram.HEADER_LEN + 14 + datagram.CRC_LEN;
        const draw: [*]const u8 = @ptrCast(&dgram_buf);
        if (el0DgramSend(draw, total) != datagram.OK) el0Fail();
        if (el0DgramSend(draw, 2000) != datagram.TOO_LARGE) el0Fail();
        dgram_buf[0] ^= 0xFF;
        if (el0DgramSend(draw, total) != datagram.BAD_DATAGRAM) el0Fail();
        if (el0DgramRecv(&recv_slot, datagram.SLOT) != datagram.EMPTY) el0Fail();
    }

    // On-target Gringots crypto must pass before any service may use it.
    if (el0CryptoSelftest() != 0) el0Fail();

    // File-shim hop: TX queue -> host file, host reply file -> RX queue.
    // First boot has no reply file (NOT_FOUND is the normal case there).
    if (el0SyncOut() != shfile.OK) el0Fail();
    {
        const st = el0SyncIn();
        if (st != shfile.NOT_FOUND) {
            if (st != shfile.OK) el0Fail();
            if (el0DgramRecv(&recv_slot, datagram.SLOT) != datagram.OK) el0Fail();
            const want: u64 = datagram.HEADER_LEN + BRIDGE_REPLY.len + datagram.CRC_LEN;
            if (recv_slot.len != want) el0Fail();
            if (recv_slot.data[3] != 0x02) el0Fail();
            var i: usize = 0;
            while (i < BRIDGE_REPLY.len) : (i += 1) {
                if (recv_slot.data[6 + i] != BRIDGE_REPLY[i]) el0Fail();
            }
        }
    }

    asm volatile ("mov x8, #2; svc #0" ::: .{ .memory = true });

    asm volatile ("mov x0, #0; mov x8, #1; svc #0" ::: .{ .memory = true });
    el0Fail();
}

pub export fn aarch64_hello_entry() callconv(.c) noreturn {
    const r = el0Recv(demo_port);
    if (r.st != cap_ipc.OK or r.len != 8 or r.word != HELLO_WORD) el0Fail();
    asm volatile ("mov x8, #3; svc #0" ::: .{ .memory = true });
    el0Fail();
}

// The vector owns save/restore. The dispatcher may only alter frame.x0 and
// the saved exception state explicitly, never compiler scratch registers.
pub export fn aarch64_exception_sync(frame: *Aarch64ExceptionFrame) void {
    const ec = (frame.esr_el1 >> 26) & 0x3f;
    // EC=0x15 = SVC instruction executed from AArch64 EL0.
    if (ec != 0x15) {
        while (true) asm volatile ("wfi" ::: .{ .memory = true });
    }

    switch (frame.x8) {
        SYS_IPC_SMOKE => {
            uart.line("Zinux init EL0");
            uart.line("IPC request/response OK");
            frame.x0 = IPC_SMOKE_RESPONSE;
        },
        SYS_EXIT => {
            uart.line("Zinux init exit");
            semihost.exit(0);
        },
        SYS_IPC_CREATE => {
            var h: u64 = 0;
            const st = cap_ipc.create(frame.x1, &h);
            const out: *u64 = @ptrFromInt(frame.x2);
            out.* = h;
            frame.x0 = st;
        },
        SYS_IPC_SEND => {
            const st = cap_ipc.sendWord(frame.x1, frame.x3, frame.x2);
            frame.x0 = st;
            if (st == cap_ipc.OK) {
                uart.line("IPC port OK");
            } else if (st == cap_ipc.TOO_LARGE) {
                uart.line("IPC port reject OK");
            }
        },
        SYS_IPC_RECV => {
            var w: u64 = 0;
            var n: u64 = 0;
            const st = cap_ipc.recvWord(frame.x1, &w, &n);
            const out: *RecvOut = @ptrFromInt(frame.x2);
            out.len = n;
            out.word = w;
            frame.x0 = st;
        },
        SYS_STORE_WRITE => {
            frame.x0 = storage.writeWord(frame.x1, frame.x2);
        },
        SYS_STORE_READ => {
            var v: u64 = 0;
            const st = storage.readWord(frame.x1, &v);
            const out: *u64 = @ptrFromInt(frame.x2);
            out.* = v;
            frame.x0 = st;
            if (st == storage.OK) {
                uart.line("storage OK");
            } else {
                uart.line("storage reject OK");
            }
        },
        SYS_CLOCK_MONO => {
            const out: *u64 = @ptrFromInt(frame.x1);
            out.* = clock.mono();
            frame.x0 = clock.OK;
        },
        SYS_CLOCK_WALL => {
            var v: u64 = 0;
            const st = clock.wall(&v);
            const out: *u64 = @ptrFromInt(frame.x1);
            out.* = v;
            frame.x0 = st;
            if (st == clock.NOT_READY) uart.line("clock OK");
        },
        SYS_DATAGRAM_SEND => {
            if (frame.x2 > datagram.SLOT) {
                frame.x0 = datagram.TOO_LARGE;
                uart.line("datagram reject OK");
            } else {
                const raw: [*]const volatile u8 = @ptrFromInt(frame.x1);
                const st = datagram.txEnqueue(raw, frame.x2);
                frame.x0 = st;
                if (st == datagram.OK) {
                    uart.line("datagram TX OK");
                } else {
                    uart.line("datagram reject OK");
                }
            }
        },
        SYS_DATAGRAM_SYNC_OUT => {
            // Peek TX front and spill it to the host file. No dequeue:
            // the queue stays intact for inspection across boots.
            if (datagram.txFront(&sync_tmp) != datagram.OK) {
                frame.x0 = datagram.EMPTY;
            } else {
                const tx_len: u64 = @intCast(shfile.TX_PATH.len);
                const fd = shfile.open(shfile.TX_PATH.ptr, tx_len, shfile.MODE_W);
                var rc: u64 = shfile.IO_ERROR;
                if (fd >= 0) {
                    const s: [*]const u8 = @ptrCast(&sync_tmp.data);
                    rc = shfile.writeAll(fd, s, sync_tmp.len);
                    _ = shfile.close(fd);
                }
                frame.x0 = rc;
                if (rc == shfile.OK) uart.line("bridge TX file OK");
            }
        },
        SYS_DATAGRAM_SYNC_IN => {
            const rx_len: u64 = @intCast(shfile.RX_PATH.len);
            const fd = shfile.open(shfile.RX_PATH.ptr, rx_len, shfile.MODE_R);
            if (fd < 0) {
                // Normal on first boot: the host has not replied yet.
                frame.x0 = shfile.NOT_FOUND;
            } else {
                var rc: u64 = shfile.IO_ERROR;
                const n = shfile.flen(fd);
                if (n >= 0) {
                    const un: u64 = @intCast(n);
                    if (un > datagram.SLOT) {
                        rc = datagram.TOO_LARGE;
                    } else {
                        const dst: [*]u8 = @ptrCast(&sync_tmp.data);
                        if (shfile.readExact(fd, dst, un) == shfile.OK) {
                            const s: [*]const volatile u8 = @ptrCast(&sync_tmp.data);
                            rc = datagram.rxInject(s, un);
                        }
                    }
                }
                _ = shfile.close(fd);
                frame.x0 = rc;
                if (rc == shfile.OK) uart.line("bridge RX file OK");
            }
        },
        SYS_CRYPTO_SELFTEST => {
            // Runs the RFC 8032 + SOS self-test on target (EL1). Prints
            // only on success; EL0 treats any nonzero status as fatal.
            if (crypto_selftest.run()) {
                uart.line("crypto OK");
                frame.x0 = 0;
            } else {
                frame.x0 = 1;
            }
        },
        SYS_DATAGRAM_RECV => {
            if (frame.x2 < datagram.SLOT) {
                frame.x0 = datagram.TOO_LARGE;
            } else {
                // Static scratch: a stack Slot would need a KiB init that
                // vectorizes into NEON. Dequeue fills len + data on
                // success; EMPTY leaves rx_tmp untouched and unread.
                const st = datagram.rxDequeue(&rx_tmp);
                if (st == datagram.OK) {
                    const out: *datagram.Slot = @ptrFromInt(frame.x1);
                    var i: u64 = 0;
                    const dst: [*]volatile u8 = @ptrCast(&out.data);
                    const s: [*]const volatile u8 = @ptrCast(&rx_tmp.data);
                    while (i < rx_tmp.len) : (i += 1) dst[i] = s[i];
                    out.len = rx_tmp.len;
                }
                frame.x0 = st;
            }
        },
        SYS_START_HELLO => {
            if (init_process.state != .running or hello_process.state != .ready) {
                uart.line("hello start state invalid");
                while (true) asm volatile ("wfi" ::: .{ .memory = true });
            }
            copyFrame(&saved_init_frame, frame);
            init_process.state = .waiting;
            hello_process.state = .running;
            frame.elr_el1 = hello_process.entry;
            frame.x0 = 0;
            frame.x8 = 0;
            setUserStack(hello_process.stack_top);
            uart.line("hello service EL0");
        },
        SYS_HELLO_DONE => {
            if (hello_process.state != .running or init_process.state != .waiting) {
                uart.line("hello done state invalid");
                while (true) asm volatile ("wfi" ::: .{ .memory = true });
            }
            hello_process.state = .exited;
            init_process.state = .running;
            copyFrame(frame, &saved_init_frame);
            frame.x0 = 0;
            setUserStack(init_process.stack_top);
            uart.line("hello service done");
        },
        else => while (true) asm volatile ("wfi" ::: .{ .memory = true }),
    }
}

test "minimal ARM64 syscall ABI is stable" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u64, 0), SYS_IPC_SMOKE);
    try testing.expectEqual(@as(u64, 1), SYS_EXIT);
    try testing.expectEqual(@as(u64, 2), SYS_START_HELLO);
    try testing.expectEqual(@as(u64, 3), SYS_HELLO_DONE);
    try testing.expectEqual(@as(u64, 4), SYS_IPC_CREATE);
    try testing.expectEqual(@as(u64, 5), SYS_IPC_SEND);
    try testing.expectEqual(@as(u64, 6), SYS_IPC_RECV);
    try testing.expectEqual(@as(u64, 7), SYS_STORE_WRITE);
    try testing.expectEqual(@as(u64, 8), SYS_STORE_READ);
    try testing.expectEqual(@as(u64, 9), SYS_CLOCK_MONO);
    try testing.expectEqual(@as(u64, 10), SYS_CLOCK_WALL);
    try testing.expectEqual(@as(u64, 11), SYS_DATAGRAM_SEND);
    try testing.expectEqual(@as(u64, 12), SYS_DATAGRAM_RECV);
    try testing.expectEqual(@as(u64, 13), SYS_DATAGRAM_SYNC_OUT);
    try testing.expectEqual(@as(u64, 14), SYS_DATAGRAM_SYNC_IN);
    try testing.expectEqual(@as(u64, 15), SYS_CRYPTO_SELFTEST);
    try testing.expectEqual(@as(u64, 0x49504332), IPC_SMOKE_RESPONSE);
    try testing.expectEqual(@as(usize, 800), frame_abi.size);
}
