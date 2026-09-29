//! Semihosting file I/O for the ARM64 desktop file-shim bridge.
//!
//! The QEMU guest cannot share memory with a host process, so the first
//! guest-host datagram hop crosses the VM boundary as files: the kernel
//! writes TX datagrams with SYS_OPEN/WRITE/CLOSE and reads RX datagrams
//! with SYS_OPEN/FLEN/READ/CLOSE. Requires QEMU
//! `-semihosting-config enable=on,target=native`; paths resolve against
//! the host QEMU working directory (the repo root in our gates).
//!
//! ARM semihosting v2 numbers (HLT 0xF000, x0 = number, x1 = param block).
//! Scalar asm only; param blocks are caller-owned u64 arrays.

pub const SYS_OPEN: u64 = 0x01;
pub const SYS_CLOSE: u64 = 0x02;
pub const SYS_WRITE: u64 = 0x05;
pub const SYS_READ: u64 = 0x06;
pub const SYS_FLEN: u64 = 0x0C;

// Open modes (QEMU arm-compat-semi fopen mapping).
pub const MODE_R: u64 = 0;
pub const MODE_W: u64 = 4;

pub const OK: u64 = 0;
pub const NOT_FOUND: u64 = 1;
pub const IO_ERROR: u64 = 2;

/// Guest-host shim paths, host-relative (repo root in gates).
pub const TX_PATH: []const u8 = "zig-out/guest-tx.dat";
pub const RX_PATH: []const u8 = "zig-out/host-rx.dat";

/// Open PATH with MODE. Returns fd (>= 0) or -1.
pub fn open(path: [*]const u8, path_len: u64, mode: u64) i64 {
    const addr: u64 = @intCast(@intFromPtr(path));
    var block: [3]u64 = .{ addr, mode, path_len };
    const fd: i64 = asm volatile ("hlt 0xF000"
        : [fd] "={x0}" (-> i64),
        : [nr] "{x0}" (SYS_OPEN),
          [block] "{x1}" (&block),
        : .{ .memory = true });
    return fd;
}

pub fn close(fd: i64) u64 {
    var block: [1]u64 = .{@bitCast(fd)};
    const rc: u64 = asm volatile ("hlt 0xF000"
        : [rc] "={x0}" (-> u64),
        : [nr] "{x0}" (SYS_CLOSE),
          [block] "{x1}" (&block),
        : .{ .memory = true });
    return rc;
}

/// Write LEN bytes. Returns OK iff QEMU reports zero bytes unwritten.
pub fn writeAll(fd: i64, buf: [*]const u8, len: u64) u64 {
    const addr: u64 = @intCast(@intFromPtr(buf));
    var block: [3]u64 = .{ @bitCast(fd), addr, len };
    const left: u64 = asm volatile ("hlt 0xF000"
        : [left] "={x0}" (-> u64),
        : [nr] "{x0}" (SYS_WRITE),
          [block] "{x1}" (&block),
        : .{ .memory = true });
    return if (left == 0) OK else IO_ERROR;
}

/// File length via SYS_FLEN. Returns -1 on failure.
pub fn flen(fd: i64) i64 {
    var block: [1]u64 = .{@bitCast(fd)};
    const n: i64 = asm volatile ("hlt 0xF000"
        : [n] "={x0}" (-> i64),
        : [nr] "{x0}" (SYS_FLEN),
          [block] "{x1}" (&block),
        : .{ .memory = true });
    return n;
}

/// Read exactly LEN bytes. Returns OK iff QEMU reports zero bytes unread.
pub fn readExact(fd: i64, buf: [*]u8, len: u64) u64 {
    const addr: u64 = @intCast(@intFromPtr(buf));
    var block: [3]u64 = .{ @bitCast(fd), addr, len };
    const left: u64 = asm volatile ("hlt 0xF000"
        : [left] "={x0}" (-> u64),
        : [nr] "{x0}" (SYS_READ),
          [block] "{x1}" (&block),
        : .{ .memory = true });
    return if (left == 0) OK else IO_ERROR;
}

const testing = @import("std").testing;

test "semihosting file call numbers match spec" {
    try testing.expectEqual(@as(u64, 0x01), SYS_OPEN);
    try testing.expectEqual(@as(u64, 0x02), SYS_CLOSE);
    try testing.expectEqual(@as(u64, 0x05), SYS_WRITE);
    try testing.expectEqual(@as(u64, 0x06), SYS_READ);
    try testing.expectEqual(@as(u64, 0x0C), SYS_FLEN);
}

test "shim paths are the gate-relative files" {
    try testing.expectEqualStrings("zig-out/guest-tx.dat", TX_PATH);
    try testing.expectEqualStrings("zig-out/host-rx.dat", RX_PATH);
}
