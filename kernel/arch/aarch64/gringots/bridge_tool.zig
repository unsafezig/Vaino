//! Desktop file-bridge responder (roadmap Phase 4).
//!
//! Reads the guest TX file the QEMU guest spilled via semihosting,
//! verifies the SOS inside (framing -> TLV -> time -> signature ->
//! replay, same rules as the guest), mints a real ACK under a fixed
//! test receiver key, and writes it back as `HOST_FRAME_DELIVER` for the
//! guest's next boot to verify. Test keys only; production receivers
//! hold their own keys.
//!
//! This file is also the host-test root for the whole vendored Gringots
//! subset (single module for exe + tests: Zig 0.16 forbids two modules
//! sharing one root file).

const std = @import("std");
const msg = @import("msg.zig");
const frame = @import("frame.zig");
const ed = @import("ed25519.zig");
const replay = @import("replay_cache.zig");
const agent = @import("agent.zig");

// --- Host-datagram framing (v1, same rules as ../datagram.zig). ---

pub const MAGIC0: u8 = 0x5A;
pub const MAGIC1: u8 = 0x47;
pub const VERSION: u8 = 0x01;
pub const HEADER_LEN: usize = 6;
pub const CRC_LEN: usize = 4;
pub const MAX_PAYLOAD: usize = 1024;
pub const MAX_DATAGRAM: usize = HEADER_LEN + MAX_PAYLOAD + CRC_LEN;

pub const OP_GUEST_SOS_SEND: u8 = 0x01;
pub const OP_HOST_FRAME_DELIVER: u8 = 0x02;

pub const T0: u64 = agent.T0;
/// Fixed test receiver key (NOT a secret; mirrors test_receiver).
pub const RECEIVER_SEED: [32]u8 = [_]u8{0x52} ** 32;
pub const ACK_NONCE: [16]u8 = [_]u8{0xA5} ** 16;

pub const BridgeError = error{
    TooSmall,
    BadMagic,
    BadVersion,
    BadLength,
    CrcMismatch,
    WrongOp,
    BadSos,
    NotSos,
    Replayed,
    AckFailed,
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

pub fn decode(raw: []const u8) BridgeError!Decoded {
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

pub fn encode(op: u8, payload: []const u8, out: []u8) BridgeError![]u8 {
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

var seen: replay.Cache = .{};

/// Test isolation: module state is shared across tests in one binary.
pub fn resetForTests() void {
    seen = .{};
}

/// Turn one guest TX file image into a host reply datagram. Pure.
pub fn respond(tx_raw: []const u8, rx_out: []u8) BridgeError![]u8 {
    const d = try decode(tx_raw);
    if (d.op != OP_GUEST_SOS_SEND) return error.WrongOp;
    const m = msg.verifyFrame(d.payload, T0) catch return error.BadSos;
    if (m.msg_type != .sos) return error.NotSos;
    if (seen.check(m.ephemeral_id, m.nonce, m.expires, T0) != .fresh)
        return error.Replayed;
    const rkp = ed.keypairFromSeed(RECEIVER_SEED) catch return error.AckFailed;
    const ab = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = rkp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 300,
        .nonce = ACK_NONCE,
        .ref = m.nonce,
    };
    var abody: [512]u8 = undefined;
    var afr: [521]u8 = undefined;
    const awire = msg.signAndFrame(&ab, rkp, &abody, &afr) catch return error.AckFailed;
    return encode(OP_HOST_FRAME_DELIVER, awire, rx_out);
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: std.Io = threaded.io();
    const alloc = std.heap.page_allocator;
    const cwd = std.Io.Dir.cwd();

    const tx = std.Io.Dir.readFileAlloc(cwd, io, "zig-out/guest-tx.dat", alloc, .limited(MAX_DATAGRAM + 1)) catch {
        std.debug.print("file-bridge: cannot read zig-out/guest-tx.dat\n", .{});
        return error.MissingTx;
    };
    var rx: [MAX_DATAGRAM]u8 = undefined;
    const reply = respond(tx, &rx) catch |err| {
        std.debug.print("file-bridge: SOS rejected: {t}\n", .{err});
        return err;
    };
    try std.Io.Dir.writeFile(cwd, io, .{ .sub_path = "zig-out/host-rx.dat", .data = reply });
    std.debug.print("file-bridge: SOS verified, ACK {d}B written\n", .{reply.len});
}

const testing = std.testing;

test {
    _ = @import("agent.zig");
    _ = @import("selftest.zig");
}

test "codec round trip" {
    var buf: [MAX_DATAGRAM]u8 = undefined;
    const d = try encode(OP_GUEST_SOS_SEND, "HELLO-DATAGRAM", &buf);
    const m = try decode(d);
    try testing.expectEqual(OP_GUEST_SOS_SEND, m.op);
    try testing.expectEqualStrings("HELLO-DATAGRAM", m.payload);
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

test "respond mints a verifiable ACK for the guest SOS" {
    resetForTests();
    agent.resetForTests();
    var sos_fr: [521]u8 = undefined;
    const n = agent.mintSos(&sos_fr) orelse return error.MintFailed;
    var up: [MAX_DATAGRAM]u8 = undefined;
    const up_dgram = try encode(OP_GUEST_SOS_SEND, sos_fr[0..n], &up);
    var rx: [MAX_DATAGRAM]u8 = undefined;
    const reply = try respond(up_dgram, &rx);
    const dm = try decode(reply);
    try testing.expectEqual(OP_HOST_FRAME_DELIVER, dm.op);
    // The guest agent itself accepts this ACK (loop closed in-process).
    try testing.expect(agent.verifyAck(dm.payload));
}

test "respond rejects wrong op, garbage and replays" {
    resetForTests();
    var rx: [MAX_DATAGRAM]u8 = undefined;
    var up: [MAX_DATAGRAM]u8 = undefined;
    const wrong = try encode(0x03, &[_]u8{}, &up);
    try testing.expectError(error.WrongOp, respond(wrong, &rx));
    var sos_fr: [521]u8 = undefined;
    const n = agent.mintSos(&sos_fr) orelse return error.MintFailed;
    sos_fr[10] ^= 0x01;
    const bad_up = try encode(OP_GUEST_SOS_SEND, sos_fr[0..n], &up);
    try testing.expectError(error.BadSos, respond(bad_up, &rx));
    // Fresh SOS passes once, then replays (deterministic mint).
    var sos2: [521]u8 = undefined;
    const n2 = agent.mintSos(&sos2) orelse return error.MintFailed;
    const up2 = try encode(OP_GUEST_SOS_SEND, sos2[0..n2], &up);
    var rx2: [MAX_DATAGRAM]u8 = undefined;
    _ = try respond(up2, &rx2);
    try testing.expectError(error.Replayed, respond(up2, &rx));
}
