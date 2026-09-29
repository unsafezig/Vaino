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
const agent = @import("gringots/agent.zig");
const service = @import("gringots/service.zig");

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
pub const SYS_GRINGOTS_SOS: u64 = 16;
pub const SYS_GRINGOTS_ACK: u64 = 17;
pub const SYS_GRINGOTS_STATUS: u64 = 18;
pub const SYS_GRINGOTS_MINT_UNIQUE: u64 = 19;
pub const SYS_GRINGOTS_VERIFY: u64 = 20;
pub const SYS_GRINGOTS_DESCRIBE: u64 = 21;
pub const SYS_GRINGOTS_SEND: u64 = 22;

/// Shared EL0/kernel out-structs (single x0 status + memory results).
pub const SosOut = struct { len: u64, frame: [521]u8 };
pub const DescOut = struct { len: u64, text: [512]u8 };
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
var status_a: service.Status linksection(".bss") = undefined;
var status_b: service.Status linksection(".bss") = undefined;
var uniq_a: [16]u8 linksection(".bss") = undefined;
var uniq_b: [16]u8 linksection(".bss") = undefined;
var sos_out: SosOut linksection(".bss") = undefined;
var desc_out: DescOut linksection(".bss") = undefined;

var init_process: process.Process = undefined;
var hello_process: process.Process = undefined;
var saved_init_frame: Aarch64ExceptionFrame = undefined;

pub extern fn aarch64_enter_init() callconv(.c) noreturn;

const STORE_PATH_LEN: u64 = shfile.STORE_PATH.len;

fn storeLoad(image: []u8) bool {
    const fd = shfile.open(shfile.STORE_PATH.ptr, STORE_PATH_LEN, shfile.MODE_R);
    if (fd < 0) return false;
    const n = shfile.flen(fd);
    var ok = false;
    if (n == 4096) {
        const dst: [*]u8 = @ptrCast(image.ptr);
        ok = shfile.readExact(fd, dst, 4096) == shfile.OK;
    }
    _ = shfile.close(fd);
    return ok;
}

fn storeSave(image: []const u8) bool {
    const fd = shfile.open(shfile.STORE_PATH.ptr, STORE_PATH_LEN, shfile.MODE_W);
    if (fd < 0) return false;
    const src: [*]const u8 = @ptrCast(image.ptr);
    const ok = shfile.writeAll(fd, src, 4096) == shfile.OK;
    _ = shfile.close(fd);
    return ok;
}

fn storeRead(off: u64, dst: []u8) void {
    _ = storage.read(off, dst.ptr, @as(u64, @intCast(dst.len)));
}

fn storeWrite(off: u64, src: []const u8) void {
    _ = storage.write(off, src.ptr, @as(u64, @intCast(src.len)));
}

const guest_backend = service.Backend{
    .read = storeRead,
    .write = storeWrite,
    .load = storeLoad,
    .store = storeSave,
};

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
    // Gringots service state: loads the persisted image when the store
    // file exists (restart), otherwise starts fresh. Prints only on load
    // so first-boot output stays stable.
    if (service.init(guest_backend) == service.INIT_LOADED) {
        uart.line("store load OK");
    }
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

fn el0GringotsSos(out: *SosOut, max: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_SOS),
          [out] "{x1}" (@intFromPtr(out)),
          [max] "{x2}" (max),
        : .{ .memory = true });
    return st;
}

fn el0Verify(raw: [*]const u8, len: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_VERIFY),
          [raw] "{x1}" (@intFromPtr(raw)),
          [len] "{x2}" (len),
        : .{ .memory = true });
    return st;
}

fn el0Describe(raw: [*]const u8, len: u64, out: *DescOut) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_DESCRIBE),
          [raw] "{x1}" (@intFromPtr(raw)),
          [len] "{x2}" (len),
          [out] "{x3}" (@intFromPtr(out)),
        : .{ .memory = true });
    return st;
}

fn el0SendFrame(raw: [*]const u8, len: u64) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_SEND),
          [raw] "{x1}" (@intFromPtr(raw)),
          [len] "{x2}" (len),
        : .{ .memory = true });
    return st;
}

fn el0GringotsAck() u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_ACK),
        : .{ .memory = true });
    return st;
}

fn el0Status(out: *service.Status) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_STATUS),
          [out] "{x1}" (@intFromPtr(out)),
        : .{ .memory = true });
    return st;
}

fn el0MintUnique(out: *[16]u8) u64 {
    const st: u64 = asm volatile ("svc #0"
        : [st] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_GRINGOTS_MINT_UNIQUE),
          [out] "{x1}" (@intFromPtr(out)),
        : .{ .memory = true });
    return st;
}

fn noncesDiffer(a: *const [16]u8, b: *const [16]u8) bool {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (a[i] != b[i]) return true;
    }
    return false;
}

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

    // On-target Gringots crypto must pass before any service may use it.
    if (el0CryptoSelftest() != 0) el0Fail();

    // Mint SOS first so it sits at TX[0] for the file shim.
    if (el0GringotsSos(&sos_out, 521) != 0) el0Fail();
    {
        // VERIFY / DESCRIBE / SEND against our own SOS bytes.
        const sos: [*]const u8 = @ptrCast(&sos_out.frame);
        if (el0Verify(sos, sos_out.len) != agent.V_OK) el0Fail();
        // Corrupted copy must not verify (CRC covers exact bytes).
        var i: usize = 0;
        while (i < sos_out.len) : (i += 1) dgram_buf[i] = sos_out.frame[i];
        dgram_buf[10] ^= 0x01;
        const bad: [*]const u8 = @ptrCast(&dgram_buf);
        if (el0Verify(bad, sos_out.len) == agent.V_OK) el0Fail();
        if (el0Describe(sos, sos_out.len, &desc_out) != 0) el0Fail();
        const want_prefix = "GRINGOTTS/1";
        var pi: usize = 0;
        while (pi < want_prefix.len) : (pi += 1) {
            if (desc_out.text[pi] != want_prefix[pi]) el0Fail();
        }
        if (el0SendFrame(sos, sos_out.len) != 0) el0Fail();
        if (el0SendFrame(sos, 0) == 0) el0Fail();
    }

    // Service stream: two unique mints must differ; status carries bits.
    if (el0MintUnique(&uniq_a) != 0) el0Fail();
    if (el0Status(&status_a) != 0) el0Fail();
    if (el0MintUnique(&uniq_b) != 0) el0Fail();
    if (el0Status(&status_b) != 0) el0Fail();
    if (!noncesDiffer(&uniq_a, &uniq_b)) el0Fail();
    if (status_b.bits & 2 == 0) el0Fail();

    // File-shim hop: TX queue -> host file, host reply file -> RX queue.
    // First boot has no reply file (NOT_FOUND is the normal case there).
    if (el0SyncOut() != shfile.OK) el0Fail();

    {
        // Device demo runs after the SOS spill so TX[0] stays the SOS.
        // RX is still empty here (sync-in runs below): EMPTY must hold.
        // encode() writes every byte SEND reads.
        if (datagram.encode(0x01, "HELLO-DATAGRAM", &dgram_buf) != datagram.OK) el0Fail();
        const total: u64 = datagram.HEADER_LEN + 14 + datagram.CRC_LEN;
        const draw: [*]const u8 = @ptrCast(&dgram_buf);
        if (el0DgramSend(draw, total) != datagram.OK) el0Fail();
        if (el0DgramSend(draw, 2000) != datagram.TOO_LARGE) el0Fail();
        dgram_buf[0] ^= 0xFF;
        if (el0DgramSend(draw, total) != datagram.BAD_DATAGRAM) el0Fail();
        if (el0DgramRecv(&recv_slot, datagram.SLOT) != datagram.EMPTY) el0Fail();
    }

    {
        const st = el0SyncIn();
        if (st != shfile.NOT_FOUND) {
            if (st != shfile.OK) el0Fail();
            if (el0GringotsAck() != 0) el0Fail();
            // Post-ACK status must report acknowledgement.
            if (el0Status(&status_a) != 0) el0Fail();
            if (status_a.bits & 1 == 0) el0Fail();
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
        SYS_GRINGOTS_SOS => {
            // Mint the deterministic demo SOS through the service (recorded
            // + persisted), hand the bytes to EL0, and queue them as
            // GUEST_SOS_SEND. The file shim carries TX[0] to the host.
            const out: *SosOut = @ptrFromInt(frame.x1);
            if (frame.x2 < 521) {
                frame.x0 = 2;
            } else {
                var fr: [521]u8 = undefined;
                const n = service.createDemoSos(&fr);
                if (n == null) {
                    frame.x0 = 1;
                } else {
                    var i: usize = 0;
                    while (i < n.?) : (i += 1) out.frame[i] = fr[i];
                    out.len = n.?;
                    const enc = datagram.encode(0x01, fr[0..n.?], &sync_tmp.data);
                    if (enc != datagram.OK) {
                        frame.x0 = 1;
                    } else {
                        const raw: [*]const volatile u8 = @ptrCast(&sync_tmp.data);
                        const total: u64 = datagram.HEADER_LEN + @as(u64, @intCast(n.?)) + datagram.CRC_LEN;
                        frame.x0 = datagram.txEnqueue(raw, total);
                        if (frame.x0 == datagram.OK) uart.line("gringots SOS OK");
                    }
                }
            }
        },
        SYS_GRINGOTS_VERIFY => {
            const raw: [*]const u8 = @ptrFromInt(frame.x1);
            frame.x0 = agent.verifyVerdict(raw[0..frame.x2]);
        },
        SYS_GRINGOTS_DESCRIBE => {
            const raw: [*]const u8 = @ptrFromInt(frame.x1);
            const out: *DescOut = @ptrFromInt(frame.x3);
            const n = agent.describeFrame(raw[0..frame.x2], out.text[0..]);
            if (n == null) {
                frame.x0 = 1;
            } else {
                out.len = n.?;
                frame.x0 = 0;
            }
        },
        SYS_GRINGOTS_SEND => {
            const raw: [*]const u8 = @ptrFromInt(frame.x1);
            const bytes = raw[0..frame.x2];
            if (agent.sendCheck(bytes) != agent.S_OK) {
                frame.x0 = 1;
            } else {
                const enc = datagram.encode(0x01, bytes, &sync_tmp.data);
                if (enc != datagram.OK) {
                    frame.x0 = 1;
                } else {
                    const vol: [*]const volatile u8 = @ptrCast(&sync_tmp.data);
                    const total: u64 = datagram.HEADER_LEN + @as(u64, @intCast(bytes.len)) + datagram.CRC_LEN;
                    frame.x0 = datagram.txEnqueue(vol, total);
                    if (frame.x0 == datagram.OK) uart.line("gringots send OK");
                }
            }
        },
        SYS_GRINGOTS_STATUS => {
            // Service status through the EL0 out-pointer: bits (bit0 =
            // acked, bit1 = has SOS) plus the last demo nonce.
            const out: *service.Status = @ptrFromInt(frame.x1);
            out.* = service.status();
            frame.x0 = 0;
        },
        SYS_GRINGOTS_MINT_UNIQUE => {
            // Unique-nonce mint for the service path (not enqueued).
            const out: *[16]u8 = @ptrFromInt(frame.x1);
            service.mintUnique(out);
            frame.x0 = 0;
        },
        SYS_GRINGOTS_ACK => {
            // Verify one RX datagram as the ACK to our SOS. Strips host
            // framing first: only HOST_FRAME_DELIVER payloads reach Gringots.
            // Replay + acked flag persist through the service.
            if (datagram.rxDequeue(&rx_tmp) != datagram.OK) {
                uart.line("ack: no rx");
                frame.x0 = 1;
            } else {
                const draw: [*]const volatile u8 = @ptrCast(&rx_tmp.data);
                if (datagram.opOf(draw) != 0x02) {
                    uart.line("ack: not deliver");
                    frame.x0 = 1;
                } else {
                    const plen = datagram.payloadLen(draw);
                    const stage = service.verifyAckFrame(rx_tmp.data[6 .. 6 + plen]);
                    frame.x0 = stage;
                    switch (stage) {
                        agent.ACK_OK => uart.line("ACK OK"),
                        agent.ACK_NO_SOS => uart.line("ack: no sos"),
                        agent.ACK_BAD_FRAME => uart.line("ack: bad frame"),
                        agent.ACK_NOT_ACK => uart.line("ack: not ack"),
                        agent.ACK_NO_REF => uart.line("ack: no ref"),
                        agent.ACK_REF_MISMATCH => uart.line("ack: ref mismatch"),
                        agent.ACK_REPLAY => uart.line("ack: replay"),
                        else => uart.line("ack: unknown"),
                    }
                }
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
    try testing.expectEqual(@as(u64, 16), SYS_GRINGOTS_SOS);
    try testing.expectEqual(@as(u64, 17), SYS_GRINGOTS_ACK);
    try testing.expectEqual(@as(u64, 18), SYS_GRINGOTS_STATUS);
    try testing.expectEqual(@as(u64, 19), SYS_GRINGOTS_MINT_UNIQUE);
    try testing.expectEqual(@as(u64, 20), SYS_GRINGOTS_VERIFY);
    try testing.expectEqual(@as(u64, 21), SYS_GRINGOTS_DESCRIBE);
    try testing.expectEqual(@as(u64, 22), SYS_GRINGOTS_SEND);
    try testing.expectEqual(@as(u64, 0x49504332), IPC_SMOKE_RESPONSE);
    try testing.expectEqual(@as(usize, 800), frame_abi.size);
}
