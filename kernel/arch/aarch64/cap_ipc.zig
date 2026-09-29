//! Minimal capability-backed IPC ports for the ARM64 Phase 2 guest.
//!
//! One kernel-global table, but EL0 never names a port directly: every
//! operation takes a handle issued by `create`. Handles are small indices
//! with validity and rights checks on each use. Fail closed.

pub const MAX_PORTS: u64 = 8;
pub const MAX_MSG: u64 = 256;

pub const RIGHT_SEND: u64 = 1;
pub const RIGHT_RECV: u64 = 2;
pub const RIGHT_ALL: u64 = RIGHT_SEND | RIGHT_RECV;

pub const OK: u64 = 0;
pub const BAD_HANDLE: u64 = 1;
pub const BAD_RIGHTS: u64 = 2;
pub const TOO_LARGE: u64 = 3;
pub const EMPTY: u64 = 4;
pub const TABLE_FULL: u64 = 5;

pub const Port = struct {
    valid: bool = false,
    rights: u64 = 0,
    len: u64 = 0,
    data: [256]u8 = [_]u8{0} ** 256,
};

var ports: [8]Port = [_]Port{.{}} ** 8;

// Scalar-only zeroing: EL1 runs with FP/SIMD disabled, so the compiler
// must not emit NEON for these paths (volatile blocks autovectorization).
fn zeroData(p: *Port) void {
    const dst: *volatile [256]u8 = @ptrCast(&p.data);
    var i: u64 = 0;
    while (i < 256) : (i += 1) dst[i] = 0;
}

pub fn reset() void {
    for (&ports) |*p| {
        p.valid = false;
        p.rights = 0;
        p.len = 0;
        zeroData(p);
    }
}

fn lookup(handle: u64) ?*Port {
    if (handle >= MAX_PORTS) return null;
    const p = &ports[handle];
    if (!p.valid) return null;
    return p;
}

pub fn create(rights: u64, out_handle: *u64) u64 {
    if (rights == 0 or (rights & ~RIGHT_ALL) != 0) return BAD_RIGHTS;
    for (&ports, 0..) |*p, i| {
        if (!p.valid) {
            p.valid = true;
            p.rights = rights;
            p.len = 0;
            out_handle.* = i;
            return OK;
        }
    }
    return TABLE_FULL;
}

pub fn send(handle: u64, src: [*]const u8, len: u64) u64 {
    const p = lookup(handle) orelse return BAD_HANDLE;
    if ((p.rights & RIGHT_SEND) == 0) return BAD_RIGHTS;
    if (len > MAX_MSG) return TOO_LARGE;
    const dst: *volatile [256]u8 = @ptrCast(&p.data);
    var i: u64 = 0;
    while (i < len) : (i += 1) dst[i] = src[i];
    p.len = len;
    return OK;
}

/// Word-granular demo transport used by the SVC layer: one 8-byte payload
/// word plus an explicit length. Lengths above 8 fail closed here so EL0
/// can prove the oversized path without passing pointers across EL0/EL1.
pub fn sendWord(handle: u64, word: u64, len: u64) u64 {
    if (len > 8) return TOO_LARGE;
    const p = lookup(handle) orelse return BAD_HANDLE;
    if ((p.rights & RIGHT_SEND) == 0) return BAD_RIGHTS;
    const dst: *volatile [256]u8 = @ptrCast(&p.data);
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        dst[i] = @truncate((word >> @intCast(i * 8)) & 0xff);
    }
    p.len = len;
    return OK;
}

pub fn recv(handle: u64, dst: [*]u8, max: u64, out_len: *u64) u64 {
    const p = lookup(handle) orelse return BAD_HANDLE;
    if ((p.rights & RIGHT_RECV) == 0) return BAD_RIGHTS;
    if (p.len == 0) return EMPTY;
    if (p.len > max) return TOO_LARGE;
    const src: *volatile [256]u8 = @ptrCast(&p.data);
    var i: u64 = 0;
    while (i < p.len) : (i += 1) dst[i] = src[i];
    out_len.* = p.len;
    p.len = 0;
    return OK;
}

pub fn recvWord(handle: u64, out_word: *u64, out_len: *u64) u64 {
    const p = lookup(handle) orelse return BAD_HANDLE;
    if ((p.rights & RIGHT_RECV) == 0) return BAD_RIGHTS;
    if (p.len == 0) return EMPTY;
    if (p.len > 8) return TOO_LARGE;
    const src: *volatile [256]u8 = @ptrCast(&p.data);
    var word: u64 = 0;
    var i: u64 = 0;
    while (i < p.len) : (i += 1) {
        word |= @as(u64, src[i]) << @intCast(i * 8);
    }
    out_word.* = word;
    out_len.* = p.len;
    p.len = 0;
    return OK;
}

test "create/send/recv round trip" {
    const testing = @import("std").testing;
    reset();
    var h: u64 = 99;
    try testing.expectEqual(OK, create(RIGHT_ALL, &h));
    var src = [_]u8{ 1, 2, 3 };
    const sraw: [*]const u8 = @ptrCast(&src);
    try testing.expectEqual(OK, send(h, sraw, 3));
    var dst = [_]u8{0} ** 8;
    const draw: [*]u8 = @ptrCast(&dst);
    var n: u64 = 0;
    try testing.expectEqual(OK, recv(h, draw, 8, &n));
    try testing.expectEqual(@as(u64, 3), n);
    try testing.expectEqualSlices(u8, src[0..], dst[0..3]);
}

test "invalid handles fail closed" {
    const testing = @import("std").testing;
    reset();
    var src = [_]u8{9};
    const sraw: [*]const u8 = @ptrCast(&src);
    try testing.expectEqual(BAD_HANDLE, send(99, sraw, 1));
    var dst = [_]u8{0};
    const draw: [*]u8 = @ptrCast(&dst);
    var n: u64 = 0;
    try testing.expectEqual(BAD_HANDLE, recv(99, draw, 1, &n));
    try testing.expectEqual(BAD_HANDLE, sendWord(99, 1, 1));
    var w: u64 = 0;
    try testing.expectEqual(BAD_HANDLE, recvWord(99, &w, &n));
}

test "wrong rights fail closed" {
    const testing = @import("std").testing;
    reset();
    var hs: u64 = 0;
    var hr: u64 = 0;
    try testing.expectEqual(OK, create(RIGHT_SEND, &hs));
    try testing.expectEqual(OK, create(RIGHT_RECV, &hr));
    var dst = [_]u8{0};
    const draw: [*]u8 = @ptrCast(&dst);
    var n: u64 = 0;
    try testing.expectEqual(BAD_RIGHTS, recv(hs, draw, 1, &n));
    var src = [_]u8{7};
    const sraw: [*]const u8 = @ptrCast(&src);
    try testing.expectEqual(BAD_RIGHTS, send(hr, sraw, 1));
    try testing.expectEqual(BAD_RIGHTS, create(0, &hs));
    try testing.expectEqual(BAD_RIGHTS, create(4, &hs));
}

test "oversized and empty messages fail closed" {
    const testing = @import("std").testing;
    reset();
    var h: u64 = 0;
    try testing.expectEqual(OK, create(RIGHT_ALL, &h));
    var big = [_]u8{0} ** 300;
    const braw: [*]const u8 = @ptrCast(&big);
    try testing.expectEqual(TOO_LARGE, send(h, braw, 300));
    try testing.expectEqual(TOO_LARGE, sendWord(h, 0, 9));
    var dst = [_]u8{0} ** 8;
    const draw: [*]u8 = @ptrCast(&dst);
    var n: u64 = 0;
    try testing.expectEqual(EMPTY, recv(h, draw, 8, &n));
    var src = [_]u8{ 1, 2, 3, 4 };
    const sraw: [*]const u8 = @ptrCast(&src);
    try testing.expectEqual(OK, send(h, sraw, 4));
    try testing.expectEqual(TOO_LARGE, recv(h, draw, 2, &n));
}
