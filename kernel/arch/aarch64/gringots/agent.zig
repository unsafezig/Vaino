//! First Gringots service logic in the Zinux guest (roadmap Phase 3).
//!
//! Deterministic by design: fixed demo seed, fixed timestamp, fixed SOS
//! nonce. Every boot mints byte-identical SOS bytes, so the file-shim
//! round trip needs no cross-boot persistence yet (real identity rotation
//! and Gringots-owned storage arrive with `gringotsd` proper).

const ed = @import("ed25519.zig");
const msg = @import("msg.zig");
const replay = @import("replay_cache.zig");

pub const T0: u64 = 1798675200;
pub const GUEST_SEED: [32]u8 = [_]u8{0x42} ** 32;
pub const SOS_NONCE: [16]u8 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

var has_sos: bool = false;
var last_sos_nonce: [16]u8 = [_]u8{0} ** 16;
var seen: replay.Cache = .{};

/// Test isolation: module state is shared across tests in one binary.
pub fn resetForTests() void {
    has_sos = false;
    last_sos_nonce = [_]u8{0} ** 16;
    seen = .{};
}

/// Mint the deterministic demo SOS into OUT_FRAME. Returns byte length,
/// or null on internal failure (never on bad input: inputs are fixed).
pub fn mintSos(out_frame: []u8) ?usize {
    const kp = ed.keypairFromSeed(GUEST_SEED) catch return null;
    const b = msg.Builder{
        .msg_type = .sos,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = SOS_NONCE,
    };
    var body: [512]u8 = undefined;
    var fr: [521]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch return null;
    if (out_frame.len < wire.len) return null;
    var i: usize = 0;
    while (i < wire.len) : (i += 1) out_frame[i] = wire[i];
    last_sos_nonce = SOS_NONCE;
    has_sos = true;
    return wire.len;
}

fn eql16(a: [16]u8, b: [16]u8) bool {
    var i: usize = 0;
    while (i < 16) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

/// Verify one inbound frame as the ACK to our SOS: valid signature and
/// time window, `ack` type, `ref` equal to our SOS nonce, replay-fresh.
pub fn verifyAck(raw: []const u8) bool {
    if (!has_sos) return false;
    const m = msg.verifyFrame(raw, T0) catch return false;
    if (m.msg_type != .ack) return false;
    const ref = m.ref orelse return false;
    if (!eql16(ref, last_sos_nonce)) return false;
    if (seen.check(m.ephemeral_id, m.nonce, m.expires, T0) != .fresh) return false;
    return true;
}

/// Staged variant returning the failing check (0 = accept). Lets the
/// syscall layer report which check failed without UART in this module.
pub const ACK_OK: u8 = 0;
pub const ACK_NO_SOS: u8 = 1;
pub const ACK_BAD_FRAME: u8 = 2;
pub const ACK_NOT_ACK: u8 = 3;
pub const ACK_NO_REF: u8 = 4;
pub const ACK_REF_MISMATCH: u8 = 5;
pub const ACK_REPLAY: u8 = 6;

pub fn verifyAckStage(raw: []const u8) u8 {
    if (!has_sos) return ACK_NO_SOS;
    const m = msg.verifyFrame(raw, T0) catch return ACK_BAD_FRAME;
    if (m.msg_type != .ack) return ACK_NOT_ACK;
    const ref = m.ref orelse return ACK_NO_REF;
    if (!eql16(ref, last_sos_nonce)) return ACK_REF_MISMATCH;
    if (seen.check(m.ephemeral_id, m.nonce, m.expires, T0) != .fresh) return ACK_REPLAY;
    return ACK_OK;
}

test {
    _ = @import("replay_cache.zig");
}

test "mint then verify-ack round trip with receiver-style ACK" {
    const testing = @import("std").testing;
    resetForTests();
    // Local ACK nonce: the bridge tests use 0xA5 in the same binary.
    const ack_nonce: [16]u8 = [_]u8{0xA6} ** 16;
    var fr: [521]u8 = undefined;
    const n = mintSos(&fr) orelse return error.MintFailed;
    try testing.expect(n >= 150 and n <= 521);
    // Deterministic: minting again yields identical bytes.
    var fr2: [521]u8 = undefined;
    const n2 = mintSos(&fr2) orelse return error.MintFailed;
    try testing.expectEqual(n, n2);
    try testing.expectEqualSlices(u8, fr[0..n], fr2[0..n2]);

    // A receiver-style ACK referencing our nonce verifies.
    const rkp = ed.keypairFromSeed([_]u8{0x52} ** 32) catch unreachable;
    const ab = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = rkp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 300,
        .nonce = ack_nonce,
        .ref = SOS_NONCE,
    };
    var abody: [512]u8 = undefined;
    var afr: [521]u8 = undefined;
    const awire = try msg.signAndFrame(&ab, rkp, &abody, &afr);
    try testing.expect(verifyAck(awire));
    // Replay of the same ACK must fail.
    try testing.expect(!verifyAck(awire));
}
