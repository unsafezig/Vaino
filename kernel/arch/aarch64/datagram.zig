//! Virtual datagram device for the ARM64 Phase 2 guest.
//!
//! Bounded TX (guest -> host) and RX (host -> guest) rings carrying
//! `Gringots/zinux/HOST_PROTOCOL.md` v1 datagrams (max 1034 B). The guest
//! validates framing on enqueue; oversized, malformed and overflowing
//! datagrams fail closed. All copies are scalar: EL1 runs with FP/SIMD
//! disabled, so vectorized loops would fault under QEMU.
//!
//! Lengths are u64 on the SVC boundary; byte buffers are many-pointers.

pub const SLOT: u64 = 1034;
pub const DEPTH: u64 = 4;

pub const OK: u64 = 0;
pub const BAD_DATAGRAM: u64 = 1;
pub const TOO_LARGE: u64 = 2;
pub const FULL: u64 = 3;
pub const EMPTY: u64 = 4;

pub const MAGIC0: u8 = 0x5A;
pub const MAGIC1: u8 = 0x47;
pub const VERSION: u8 = 0x01;
pub const HEADER_LEN: u64 = 6;
pub const CRC_LEN: u64 = 4;
pub const MAX_PAYLOAD: u64 = 1024;

pub const Slot = struct {
    len: u64 = 0,
    data: [1034]u8 = [_]u8{0} ** 1034,
};

var tx: [4]Slot = [_]Slot{.{}} ** 4;
var tx_head: u64 = 0;
var tx_count: u64 = 0;
var rx: [4]Slot = [_]Slot{.{}} ** 4;
var rx_head: u64 = 0;
var rx_count: u64 = 0;

pub fn reset() void {
    tx_head = 0;
    tx_count = 0;
    rx_head = 0;
    rx_count = 0;
    for (&tx) |*s| s.len = 0;
    for (&rx) |*s| s.len = 0;
}

pub fn crc32Ieee(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc ^= b;
        var i: u64 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 1 == 1) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc ^ 0xFFFFFFFF;
}

// noinline: blocks literal specialization that would copy short payloads
// with SIMD loads/stores (faults with FP/SIMD disabled).
noinline fn copyBytes(dst: [*]volatile u8, src: [*]const volatile u8, len: u64) void {
    var i: u64 = 0;
    while (i < len) : (i += 1) dst[i] = src[i];
}

fn copySlot(dst: *Slot, src: [*]const volatile u8, len: u64) void {
    const d: [*]volatile u8 = @ptrCast(&dst.data);
    const s: [*]const volatile u8 = @ptrCast(src);
    copyBytes(d, s, len);
    dst.len = len;
}

/// Encode one v1 datagram. OUT must hold 6 + payload.len + 4.
pub fn encode(op: u8, payload: []const u8, out: []u8) u64 {
    const plen: u64 = @intCast(payload.len);
    if (plen > MAX_PAYLOAD) return TOO_LARGE;
    const total: u64 = HEADER_LEN + plen + CRC_LEN;
    if (out.len < total) return TOO_LARGE;
    out[0] = MAGIC0;
    out[1] = MAGIC1;
    out[2] = VERSION;
    out[3] = op;
    out[4] = @truncate((plen >> 8) & 0xFF);
    out[5] = @truncate(plen & 0xFF);
    const dst: [*]volatile u8 = @ptrCast(out.ptr + HEADER_LEN);
    const psrc: [*]const volatile u8 = @ptrCast(payload.ptr);
    copyBytes(dst, psrc, plen);
    const crc = crc32Ieee(out[0 .. HEADER_LEN + plen]);
    const base: usize = @intCast(HEADER_LEN + plen);
    out[base] = @truncate((crc >> 24) & 0xFF);
    out[base + 1] = @truncate((crc >> 16) & 0xFF);
    out[base + 2] = @truncate((crc >> 8) & 0xFF);
    out[base + 3] = @truncate(crc & 0xFF);
    return OK;
}

/// Validate framing only (crypto validation stays in Gringots proper).
/// Volatile reads keep this scalar: EL1 runs with FP/SIMD disabled.
pub fn validate(raw: [*]const volatile u8, len: u64) u64 {
    if (len < HEADER_LEN + CRC_LEN) return BAD_DATAGRAM;
    if (len > SLOT) return TOO_LARGE;
    const buf: *const volatile [1034]u8 = @ptrCast(raw);
    if (buf[0] != MAGIC0 or buf[1] != MAGIC1) return BAD_DATAGRAM;
    if (buf[2] != VERSION) return BAD_DATAGRAM;
    const plen: u64 = (@as(u64, buf[4]) << 8) | buf[5];
    if (plen > MAX_PAYLOAD) return BAD_DATAGRAM;
    if (len != HEADER_LEN + plen + CRC_LEN) return BAD_DATAGRAM;
    const base: usize = @intCast(HEADER_LEN + plen);
    const want: u32 = (@as(u32, buf[base]) << 24) |
        (@as(u32, buf[base + 1]) << 16) |
        (@as(u32, buf[base + 2]) << 8) |
        buf[base + 3];
    // Inline CRC over the volatile view: passing a volatile slice to
    // crc32Ieee would discard the qualifier.
    var crc: u32 = 0xFFFFFFFF;
    var bi: usize = 0;
    while (bi < base) : (bi += 1) {
        crc ^= buf[bi];
        var i: u64 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 1 == 1) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    if ((crc ^ 0xFFFFFFFF) != want) return BAD_DATAGRAM;
    return OK;
}

pub fn txEnqueue(raw: [*]const volatile u8, len: u64) u64 {
    const v = validate(raw, len);
    if (v != OK) return v;
    if (tx_count >= DEPTH) return FULL;
    copySlot(&tx[(tx_head + tx_count) % DEPTH], raw, len);
    tx_count += 1;
    return OK;
}

/// Copy the oldest TX entry without consuming (file-shim peek).
pub fn txFront(out: *Slot) u64 {
    if (tx_count == 0) return EMPTY;
    const src = &tx[tx_head % DEPTH];
    const s: [*]const volatile u8 = @ptrCast(&src.data);
    copySlot(out, s, src.len);
    return OK;
}

pub fn rxDequeue(out: *Slot) u64 {
    if (rx_count == 0) return EMPTY;
    const src = &rx[rx_head % DEPTH];
    const s: [*]const volatile u8 = @ptrCast(&src.data);
    copySlot(out, s, src.len);
    src.len = 0;
    rx_head = (rx_head + 1) % DEPTH;
    rx_count -= 1;
    return OK;
}

/// Host-fill hook (used by tests now, by the semihosting-file RX path
/// later). Validated like guest input: the host is not trusted either.
pub fn rxInject(raw: [*]const volatile u8, len: u64) u64 {
    const v = validate(raw, len);
    if (v != OK) return v;
    if (rx_count >= DEPTH) return FULL;
    copySlot(&rx[(rx_head + rx_count) % DEPTH], raw, len);
    rx_count += 1;
    return OK;
}

test "crc32 matches IEEE check value" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32Ieee("123456789"));
}

test "encode/validate round trip" {
    const testing = @import("std").testing;
    reset();
    var buf: [1034]u8 = undefined;
    try testing.expectEqual(OK, encode(0x01, "HELLO-DATAGRAM", &buf));
    const total: u64 = HEADER_LEN + 14 + CRC_LEN;
    const raw: [*]const volatile u8 = @ptrCast(&buf);
    try testing.expectEqual(OK, validate(raw, total));
    try testing.expectEqual(OK, txEnqueue(raw, total));
}

test "bad magic, version and crc fail closed" {
    const testing = @import("std").testing;
    reset();
    var buf: [1034]u8 = undefined;
    _ = encode(0x01, "HELLO-DATAGRAM", &buf);
    const total: u64 = HEADER_LEN + 14 + CRC_LEN;
    const raw: [*]const volatile u8 = @ptrCast(&buf);
    var bad: [1034]u8 = undefined;
    const braw: [*]const volatile u8 = @ptrCast(&bad);
    const bdst: [*]volatile u8 = @ptrCast(&bad);
    copyBytes(bdst, raw, total);
    bad[0] ^= 0xFF;
    try testing.expectEqual(BAD_DATAGRAM, validate(braw, total));
    copyBytes(bdst, raw, total);
    bad[2] = 0x7F;
    try testing.expectEqual(BAD_DATAGRAM, validate(braw, total));
    copyBytes(bdst, raw, total);
    bad[total - 1] ^= 0x01;
    try testing.expectEqual(BAD_DATAGRAM, validate(braw, total));
    try testing.expectEqual(BAD_DATAGRAM, validate(raw, 4));
}

test "oversize, full and empty fail closed" {
    const testing = @import("std").testing;
    reset();
    var buf: [1034]u8 = undefined;
    _ = encode(0x01, "x", &buf);
    const raw: [*]const volatile u8 = @ptrCast(&buf);
    const one: u64 = HEADER_LEN + 1 + CRC_LEN;
    try testing.expectEqual(TOO_LARGE, validate(raw, SLOT + 1));
    try testing.expectEqual(OK, txEnqueue(raw, one));
    try testing.expectEqual(OK, txEnqueue(raw, one));
    try testing.expectEqual(OK, txEnqueue(raw, one));
    try testing.expectEqual(OK, txEnqueue(raw, one));
    try testing.expectEqual(FULL, txEnqueue(raw, one));
    var out: Slot = .{};
    try testing.expectEqual(EMPTY, rxDequeue(&out));
    try testing.expectEqual(OK, rxInject(raw, one));
    try testing.expectEqual(OK, rxDequeue(&out));
    try testing.expectEqual(one, out.len);
}
