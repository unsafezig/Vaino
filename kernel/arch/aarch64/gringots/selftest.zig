//! On-target Gringots crypto self-test.
//!
//! RFC 8032 known-answer vector (proves the primitive independently)
//! plus an SOS mint/verify round trip at a fixed timestamp (proves the
//! framing + TLV + time + signature path coherently). Called from the
//! `SYS_CRYPTO_SELFTEST` handler; also host-tested through the same file.

const ed = @import("ed25519.zig");
const frame = @import("frame.zig");
const msg = @import("msg.zig");

pub const T0: u64 = 1798675200;

fn rfc8032() bool {
    var seed: [32]u8 = undefined;
    var want_pk: [32]u8 = undefined;
    var want_sig: [64]u8 = undefined;
    _ = frame.hexDecode("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", &seed) catch return false;
    _ = frame.hexDecode("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", &want_pk) catch return false;
    _ = frame.hexDecode("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", &want_sig) catch return false;

    const kp = ed.keypairFromSeed(seed) catch return false;
    if (!equal32(&kp.public_key.toBytes(), &want_pk)) return false;
    const got = ed.signDetached(kp, &[_]u8{}) catch return false;
    if (!equal64(&got, &want_sig)) return false;
    ed.verifyDetached(want_sig, &[_]u8{}, want_pk) catch return false;
    if (ed.verifyDetached(want_sig, "TEST", want_pk)) {
        return false;
    } else |_| {}
    return true;
}

fn equal32(a: *const [32]u8, b: *const [32]u8) bool {
    var i: usize = 0;
    while (i < 32) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

fn equal64(a: *const [64]u8, b: *const [64]u8) bool {
    var i: usize = 0;
    while (i < 64) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

fn sosRoundTrip() bool {
    const kp = ed.keypairFromSeed([_]u8{0x42} ** 32) catch return false;
    const b = msg.Builder{
        .msg_type = .sos,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
    };
    var body: [512]u8 = undefined;
    var fr: [521]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch return false;
    const m = msg.verifyFrame(wire, T0) catch return false;
    if (m.msg_type != .sos) return false;
    if (!equal32(&kp.public_key.toBytes(), &m.ephemeral_id)) return false;
    // Tampered copy must fail (exact bytes covered by CRC).
    var bad: [521]u8 = undefined;
    var i: usize = 0;
    while (i < wire.len) : (i += 1) bad[i] = wire[i];
    bad[10] ^= 0x01;
    if (msg.verifyFrame(bad[0..wire.len], T0)) |_| {
        return false;
    } else |_| {}
    return true;
}

pub fn run() bool {
    return rfc8032() and sosRoundTrip();
}

test {
    _ = @import("types.zig");
    _ = frame;
    _ = msg;
    _ = ed;
}

test "self-test passes on any target" {
    const testing = @import("std").testing;
    try testing.expect(run());
}
