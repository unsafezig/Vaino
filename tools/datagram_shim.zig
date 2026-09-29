//! Desktop file-shim for the guest-host datagram hop (Phase 4 setup).
//!
//! Reads the guest TX file the QEMU guest spilled via semihosting,
//! validates v1 framing (magic/version/length/CRC32, same rules as
//! `kernel/arch/aarch64/datagram.zig`), and writes a canned
//! `HOST_FRAME_DELIVER` reply the guest picks up on its next boot.
//! Framing codec is reimplemented here on purpose: Zig 0.16 forbids two
//! modules sharing one root file, and this stays a test-only tool.
//!
//! Canonical paths live in `kernel/arch/aarch64/semihost_file.zig`
//! (`zig-out/guest-tx.dat`, `zig-out/host-rx.dat`); the gate runs from
//! the repo root so the defaults below match without arguments.

const std = @import("std");

pub const MAGIC0: u8 = 0x5A;
pub const MAGIC1: u8 = 0x47;
pub const VERSION: u8 = 0x01;
pub const HEADER_LEN: usize = 6;
pub const CRC_LEN: usize = 4;
pub const MAX_PAYLOAD: usize = 1024;
pub const MAX_DATAGRAM: usize = HEADER_LEN + MAX_PAYLOAD + CRC_LEN;

pub const OP_GUEST_SOS_SEND: u8 = 0x01;
pub const OP_HOST_FRAME_DELIVER: u8 = 0x02;

/// Must match `BRIDGE_REPLY` in `kernel/arch/aarch64/syscall.zig`.
pub const REPLY_PAYLOAD: []const u8 = "BRIDGE-REPLY-01";

pub const ShimError = error{
    TooSmall,
    BadMagic,
    BadVersion,
    BadLength,
    CrcMismatch,
    WrongOp,
    ReplyTooLarge,
};

pub fn crc32Ieee(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| {
            if (crc & 1 == 1) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc ^ 0xFFFFFFFF;
}

pub const Decoded = struct {
    op: u8,
    payload: []const u8,
};

pub fn decode(raw: []const u8) ShimError!Decoded {
    if (raw.len < HEADER_LEN + CRC_LEN) return error.TooSmall;
    if (raw[0] != MAGIC0 or raw[1] != MAGIC1) return error.BadMagic;
    if (raw[2] != VERSION) return error.BadVersion;
    const len = std.mem.readInt(u16, raw[4..][0..2], .big);
    if (len > MAX_PAYLOAD) return error.BadLength;
    if (raw.len != HEADER_LEN + len + CRC_LEN) return error.BadLength;
    const want = std.mem.readInt(u32, raw[HEADER_LEN + len ..][0..4], .big);
    if (crc32Ieee(raw[0 .. HEADER_LEN + len]) != want) return error.CrcMismatch;
    return .{ .op = raw[3], .payload = raw[HEADER_LEN .. HEADER_LEN + len] };
}

pub fn encode(op: u8, payload: []const u8, out: []u8) ShimError![]u8 {
    if (payload.len > MAX_PAYLOAD) return error.BadLength;
    const total = HEADER_LEN + payload.len + CRC_LEN;
    if (out.len < total) return error.ReplyTooLarge;
    out[0] = MAGIC0;
    out[1] = MAGIC1;
    out[2] = VERSION;
    out[3] = op;
    std.mem.writeInt(u16, out[4..][0..2], @intCast(payload.len), .big);
    @memcpy(out[HEADER_LEN .. HEADER_LEN + payload.len], payload);
    const crc = crc32Ieee(out[0 .. HEADER_LEN + payload.len]);
    std.mem.writeInt(u32, out[HEADER_LEN + payload.len ..][0..4], crc, .big);
    return out[0..total];
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: std.Io = threaded.io();
    const alloc = std.heap.page_allocator;
    const cwd = std.Io.Dir.cwd();

    const tx = std.Io.Dir.readFileAlloc(cwd, io, "zig-out/guest-tx.dat", alloc, .limited(MAX_DATAGRAM + 1)) catch {
        std.debug.print("datagram-shim: cannot read zig-out/guest-tx.dat\n", .{});
        return error.MissingTx;
    };
    const m = decode(tx) catch |err| {
        std.debug.print("datagram-shim: TX framing invalid: {t}\n", .{err});
        return err;
    };
    if (m.op != OP_GUEST_SOS_SEND) {
        std.debug.print("datagram-shim: unexpected op 0x{x:0>2}\n", .{m.op});
        return error.WrongOp;
    }
    var rx: [MAX_DATAGRAM]u8 = undefined;
    const dgram = try encode(OP_HOST_FRAME_DELIVER, REPLY_PAYLOAD, &rx);
    try std.Io.Dir.writeFile(cwd, io, .{ .sub_path = "zig-out/host-rx.dat", .data = dgram });
    std.debug.print("datagram-shim: op=0x{x:0>2} payload={d}B -> reply {d}B written\n", .{ m.op, m.payload.len, dgram.len });
}

const testing = std.testing;

test "crc32 matches IEEE check value" {
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32Ieee("123456789"));
}

test "encode/decode round trip with reply payload" {
    var buf: [MAX_DATAGRAM]u8 = undefined;
    const d = try encode(OP_HOST_FRAME_DELIVER, REPLY_PAYLOAD, &buf);
    try testing.expectEqual(@as(usize, HEADER_LEN + 15 + CRC_LEN), d.len);
    const m = try decode(d);
    try testing.expectEqual(OP_HOST_FRAME_DELIVER, m.op);
    try testing.expectEqualStrings(REPLY_PAYLOAD, m.payload);
}

test "each corruption is rejected" {
    var buf: [MAX_DATAGRAM]u8 = undefined;
    const d = try encode(OP_GUEST_SOS_SEND, "HELLO-DATAGRAM", &buf);
    var bad: [MAX_DATAGRAM]u8 = undefined;
    @memcpy(bad[0..d.len], d);
    bad[0] ^= 0xFF;
    try testing.expectError(error.BadMagic, decode(bad[0..d.len]));
    @memcpy(bad[0..d.len], d);
    bad[2] = 0x7F;
    try testing.expectError(error.BadVersion, decode(bad[0..d.len]));
    @memcpy(bad[0..d.len], d);
    bad[d.len - 1] ^= 0x01;
    try testing.expectError(error.CrcMismatch, decode(bad[0..d.len]));
    try testing.expectError(error.TooSmall, decode(d[0..4]));
}
