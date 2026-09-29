//! Stub persistent storage for the ARM64 Phase 2 guest.
//!
//! A single Gringots-owned 4 KiB region with strict bounds checks. Byte
//! access is the core API (host-tested); the SVC layer adds a word-granular
//! demo wrapper. Out-of-range access fails closed and never wraps.

pub const SIZE: u64 = 4096;

pub const OK: u64 = 0;
pub const BAD_RANGE: u64 = 1;

var region: [4096]u8 = [_]u8{0} ** 4096;

pub fn reset() void {
    const dst: *volatile [4096]u8 = @ptrCast(&region);
    var i: u64 = 0;
    while (i < SIZE) : (i += 1) dst[i] = 0;
}

fn check(offset: u64, len: u64) bool {
    if (len > SIZE) return false;
    if (offset > SIZE) return false;
    return offset + len <= SIZE;
}

pub fn write(offset: u64, src: *const u8, len: u64) u64 {
    if (!check(offset, len)) return BAD_RANGE;
    const dst: *volatile [4096]u8 = @ptrCast(&region);
    var i: u64 = 0;
    while (i < len) : (i += 1) dst[offset + i] = src[i];
    return OK;
}

pub fn read(offset: u64, dst: *u8, len: u64) u64 {
    if (!check(offset, len)) return BAD_RANGE;
    const src: *volatile [4096]u8 = @ptrCast(&region);
    var i: u64 = 0;
    while (i < len) : (i += 1) dst[i] = src[offset + i];
    return OK;
}

// Single scalar accesses: fixed-count byte-shift loops get autovectorized
// into NEON, which faults while EL1 runs with FP/SIMD disabled.
pub fn writeWord(offset: u64, word: u64) u64 {
    if (!check(offset, 8)) return BAD_RANGE;
    const dst: *volatile u64 = @ptrFromInt(@intFromPtr(&region) + offset);
    dst.* = word;
    return OK;
}

pub fn readWord(offset: u64, out: *u64) u64 {
    if (!check(offset, 8)) return BAD_RANGE;
    const src: *volatile u64 = @ptrFromInt(@intFromPtr(&region) + offset);
    out.* = src.*;
    return OK;
}

test "word round trip at offset zero" {
    const testing = @import("std").testing;
    reset();
    try testing.expectEqual(OK, writeWord(0, 0x48454c4c4f202132));
    var v: u64 = 0;
    try testing.expectEqual(OK, readWord(0, &v));
    try testing.expectEqual(@as(u64, 0x48454c4c4f202132), v);
}

test "out-of-range access fails closed" {
    const testing = @import("std").testing;
    reset();
    var b = [_]u8{1};
    try testing.expectEqual(BAD_RANGE, write(SIZE, &b, 1));
    try testing.expectEqual(BAD_RANGE, write(SIZE - 4, &b, 8));
    try testing.expectEqual(BAD_RANGE, read(SIZE, &b, 1));
    var w: u64 = 0;
    try testing.expectEqual(BAD_RANGE, readWord(SIZE - 7, &w));
    try testing.expectEqual(BAD_RANGE, writeWord(1 << 40, 0));
}
