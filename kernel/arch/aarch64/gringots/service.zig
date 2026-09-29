//! Gringots service state v1 (roadmap Phase 3).
//!
//! Identity, boot counter, nonce stream, replay ring and ack flag live in
//! Gringots-owned storage (`storage.zig` region) behind an injectable file
//! backend (semihosting files on target, buffers on host tests). Every
//! mutation persists, so replay protection and nonce uniqueness survive
//! restarts once the backend file does.
//!
//! Storage layout (offsets in bytes, integers little-endian):
//!
//! ```text
//! 0..32    identity seed
//! 32..40   created_at wall time (0 = demo/unset)
//! 40..48   boot counter (++ per service init)
//! 48..52   magic "GRG1"
//! 52..56   reserved
//! 56..64   demo SOS count
//! 64..72   nonce stream state (splitmix64)
//! 72..80   flags (bit0 = acked)
//! 80..96   last demo nonce (16 B)
//! 96..104  replay validity bitmap (u64)
//! 104..3688 replay ring: 64 x (id 32 B + nonce 16 B + expires u64)
//! 3688..3696 replay cursor (u64)
//! ```

const std = @import("std");
const agent = @import("agent.zig");
const ed = @import("ed25519.zig");
const msg = @import("msg.zig");
const replay = @import("replay_cache.zig");
const types = @import("types.zig");

/// All storage goes through here (offsets/counts are this module's own
/// layout constants below). The guest wires `storage.zig` + semihosting
/// files; host tests wire a RAM buffer. Keeps this file inside its
/// module path (no `../` imports allowed).
pub const Backend = struct {
    read: *const fn (off: u64, dst: []u8) void,
    write: *const fn (off: u64, src: []const u8) void,
    load: *const fn (image: []u8) bool,
    store: *const fn (image: []const u8) bool,
};

pub const OFF_SEED: u64 = 0;
pub const OFF_CREATED: u64 = 32;
pub const OFF_COUNTER: u64 = 40;
pub const OFF_MAGIC: u64 = 48;
pub const OFF_SOS_COUNT: u64 = 56;
pub const OFF_STREAM: u64 = 64;
pub const OFF_FLAGS: u64 = 72;
pub const OFF_LAST_NONCE: u64 = 80;
pub const OFF_REPLAY_BITS: u64 = 96;
pub const OFF_REPLAY: u64 = 104;
pub const OFF_CURSOR: u64 = 3688;
pub const REPLAY_N: u64 = 64;
pub const ENTRY_LEN: u64 = 56;
pub const FLAG_ACKED: u64 = 1;

pub const INIT_FRESH: u8 = 0;
pub const INIT_LOADED: u8 = 1;

pub const ROT_OK: u8 = 0;
pub const ROT_STAMPED: u8 = 1;
pub const ROT_ROTATED: u8 = 2;

var inited: bool = false;
var be: Backend = undefined;
var seen: replay.Cache = .{};

/// Test isolation: drop RAM state (storage region is reset separately).
pub fn resetForTests() void {
    inited = false;
    seen = .{};
}

fn readU64(off: u64) u64 {
    var b: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    be.read(off, &b);
    return std.mem.readInt(u64, &b, .little);
}

fn writeU64(off: u64, v: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    be.write(off, &b);
}

fn readBytes(off: u64, dst: []u8) void {
    be.read(off, dst);
}

fn writeBytes(off: u64, src: []const u8) void {
    be.write(off, src);
}

fn seedU64() u64 {
    var seed: [32]u8 = undefined;
    readBytes(OFF_SEED, &seed);
    return std.mem.readInt(u64, seed[0..8], .little);
}

fn loadReplay() void {
    seen = .{};
    const bits = readU64(OFF_REPLAY_BITS);
    var i: u64 = 0;
    while (i < REPLAY_N) : (i += 1) {
        if ((bits >> @intCast(i)) & 1 == 0) continue;
        const base = OFF_REPLAY + i * ENTRY_LEN;
        var id: [32]u8 = undefined;
        var nonce: [16]u8 = undefined;
        readBytes(base, &id);
        readBytes(base + 32, &nonce);
        const expires = readU64(base + 48);
        seen.slots[i] = .{ .id = id, .nonce = nonce, .expires = expires };
    }
    seen.cursor = @intCast(readU64(OFF_CURSOR) % REPLAY_N);
}

fn storeReplay() void {
    var bits: u64 = 0;
    var i: u64 = 0;
    while (i < REPLAY_N) : (i += 1) {
        if (seen.slots[i]) |e| {
            bits |= @as(u64, 1) << @intCast(i);
            const base = OFF_REPLAY + i * ENTRY_LEN;
            writeBytes(base, &e.id);
            writeBytes(base + 32, &e.nonce);
            writeU64(base + 48, e.expires);
        }
    }
    writeU64(OFF_REPLAY_BITS, bits);
    writeU64(OFF_CURSOR, seen.cursor);
}

fn persist() void {
    var image: [4096]u8 = undefined;
    be.read(0, &image);
    _ = be.store(&image);
}

/// Load or freshly initialize. Returns INIT_LOADED when a valid image
/// came from the backend, INIT_FRESH otherwise. Idempotent per boot.
pub fn init(backend: Backend) u8 {
    if (inited) return if (readU64(OFF_COUNTER) > 1) INIT_LOADED else INIT_FRESH;
    be = backend;
    inited = true;
    var image: [4096]u8 = undefined;
    var magic_ok = false;
    if (be.load(&image)) {
        be.write(0, &image);
        var m: [4]u8 = undefined;
        readBytes(OFF_MAGIC, &m);
        magic_ok = m[0] == 'G' and m[1] == 'R' and m[2] == 'G' and m[3] == '1';
    }
    if (!magic_ok) {
        writeBytes(OFF_SEED, &agent.GUEST_SEED);
        writeU64(OFF_CREATED, 0);
        writeU64(OFF_COUNTER, 0);
        writeBytes(OFF_MAGIC, "GRG1");
        writeU64(OFF_SOS_COUNT, 0);
        writeU64(OFF_FLAGS, 0);
        var z16: [16]u8 = [_]u8{0} ** 16;
        writeBytes(OFF_LAST_NONCE, &z16);
        writeU64(OFF_REPLAY_BITS, 0);
        writeU64(OFF_CURSOR, 0);
    }
    writeU64(OFF_COUNTER, readU64(OFF_COUNTER) + 1);
    // Reseed the stream from seed + counter: unique per boot even for
    // identical images.
    writeU64(OFF_STREAM, seedU64() ^ (readU64(OFF_COUNTER) *% 0x9E3779B97F4A7C15));
    loadReplay();
    persist();
    return if (magic_ok) INIT_LOADED else INIT_FRESH;
}

pub fn counter() u64 {
    return readU64(OFF_COUNTER);
}

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// Drive identity against wall time. Fresh regions get stamped;
/// expired or backwards clocks start a new epoch (fresh stream-derived
/// seed, acked + SOS state cleared, replay ring kept). Returns
/// ROT_OK / ROT_STAMPED / ROT_ROTATED. No-op before init.
pub fn onWallTime(wall: u64) u8 {
    if (!inited) return ROT_OK;
    const created = readU64(OFF_CREATED);
    if (created == 0) {
        writeU64(OFF_CREATED, wall);
        persist();
        return ROT_STAMPED;
    }
    if (wall >= created and wall - created < types.IDENTITY_LIFETIME_S) return ROT_OK;
    rotateEpoch(wall);
    return ROT_ROTATED;
}

/// On-demand rotation (fresh epoch now, regardless of expiry).
pub fn rotateNow(wall: u64) void {
    rotateEpoch(wall);
}

fn rotateEpoch(wall: u64) void {
    var st = readU64(OFF_STREAM);
    var seed: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        std.mem.writeInt(u64, seed[i * 8 ..][0..8], splitmix(&st), .little);
    }
    writeU64(OFF_STREAM, st);
    writeBytes(OFF_SEED, &seed);
    writeU64(OFF_CREATED, wall);
    writeU64(OFF_FLAGS, readU64(OFF_FLAGS) & ~FLAG_ACKED);
    writeU64(OFF_SOS_COUNT, 0);
    var z16: [16]u8 = [_]u8{0} ** 16;
    writeBytes(OFF_LAST_NONCE, &z16);
    persist();
}

/// Mint the deterministic demo SOS (bridge path) and record it.
pub fn createDemoSos(out_frame: []u8) ?usize {
    const n = agent.mintSos(out_frame) orelse return null;
    writeU64(OFF_SOS_COUNT, readU64(OFF_SOS_COUNT) + 1);
    writeBytes(OFF_LAST_NONCE, &agent.SOS_NONCE);
    persist();
    return n;
}

/// Mint a unique 16-byte nonce from the persisted stream.
pub fn mintUnique(out: *[16]u8) void {
    var st = readU64(OFF_STREAM);
    const a = splitmix(&st);
    const b = splitmix(&st);
    writeU64(OFF_STREAM, st);
    std.mem.writeInt(u64, out[0..8], a, .little);
    std.mem.writeInt(u64, out[8..16], b, .little);
    persist();
}

/// Verify one inbound frame as our ACK; persists replay + acked flag.
pub fn verifyAckFrame(raw: []const u8) u8 {
    const stage = agent.verifyAckStageCached(raw, &seen);
    if (stage == agent.ACK_OK) {
        writeU64(OFF_FLAGS, readU64(OFF_FLAGS) | FLAG_ACKED);
    }
    storeReplay();
    persist();
    return stage;
}

pub const Status = struct {
    bits: u64,
    nonce: [16]u8,
};

/// bits: bit0 = acked, bit1 = has SOS.
pub fn status() Status {
    const flags = readU64(OFF_FLAGS);
    const count = readU64(OFF_SOS_COUNT);
    var nonce: [16]u8 = [_]u8{0} ** 16;
    readBytes(OFF_LAST_NONCE, &nonce);
    var bits: u64 = 0;
    if (flags & FLAG_ACKED != 0) bits |= 1;
    if (count > 0) bits |= 2;
    return .{ .bits = bits, .nonce = nonce };
}

test {
    _ = agent;
}

// Module-level shims: function-local statics cannot back a Backend.
var t_region: [4096]u8 = [_]u8{0} ** 4096;
var t_saved: [4096]u8 = [_]u8{0} ** 4096;
var t_has_file: bool = false;

fn tRead(off: u64, dst: []u8) void {
    @memcpy(dst, t_region[off..][0..dst.len]);
}

fn tWrite(off: u64, src: []const u8) void {
    @memcpy(t_region[off..][0..src.len], src);
}

fn tLoad(image: []u8) bool {
    if (!t_has_file) return false;
    @memcpy(image, &t_saved);
    return true;
}

fn tStore(image: []const u8) bool {
    @memcpy(&t_saved, image);
    t_has_file = true;
    return true;
}

const t_be = Backend{ .read = tRead, .write = tWrite, .load = tLoad, .store = tStore };

fn tResetRegion() void {
    for (&t_region) |*b| b.* = 0;
}

test "fresh init, counter bumps, unique nonces differ" {
    const testing = std.testing;
    tResetRegion();
    resetForTests();
    t_has_file = false;
    try testing.expectEqual(INIT_FRESH, init(t_be));
    try testing.expectEqual(@as(u64, 1), counter());
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    mintUnique(&a);
    mintUnique(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    var fr: [521]u8 = undefined;
    _ = createDemoSos(&fr) orelse return error.MintFailed;
    const st = status();
    try testing.expect(st.bits & 2 != 0);
    try testing.expectEqualSlices(u8, &agent.SOS_NONCE, &st.nonce);
}

test "restart loads state: counter, acked, replay and nonce survive" {
    const testing = std.testing;
    // Verify a receiver-style ACK before the restart (sets acked + ring).
    const rkp = ed.keypairFromSeed([_]u8{0x52} ** 32) catch unreachable;
    const ab = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = rkp.public_key.toBytes(),
        .timestamp = agent.T0,
        .expires = agent.T0 + 300,
        .nonce = [_]u8{0xB0} ** 16,
        .ref = agent.SOS_NONCE,
    };
    var abody: [512]u8 = undefined;
    var afr: [521]u8 = undefined;
    const awire = try msg.signAndFrame(&ab, rkp, &abody, &afr);
    try testing.expectEqual(agent.ACK_OK, verifyAckFrame(awire));
    try testing.expect(status().bits & 1 != 0);

    // Simulate reboot: RAM statics and region wiped, file survives.
    resetForTests();
    tResetRegion();
    try testing.expectEqual(INIT_LOADED, init(t_be));
    try testing.expectEqual(@as(u64, 2), counter());
    const st = status();
    try testing.expect(st.bits & 1 != 0); // acked survived
    try testing.expect(st.bits & 2 != 0); // demo SOS still known
    try testing.expectEqualSlices(u8, &agent.SOS_NONCE, &st.nonce);
    // Same ACK is now a replay (ring survived).
    try testing.expectEqual(agent.ACK_REPLAY, verifyAckFrame(awire));
    // Stream continued (differs from itself across mints).
    var c: [16]u8 = undefined;
    var d: [16]u8 = undefined;
    mintUnique(&c);
    mintUnique(&d);
    try testing.expect(!std.mem.eql(u8, &c, &d));
}

test "wall clock stamps fresh regions, rotates after lifetime" {
    const testing = std.testing;
    const T: u64 = 1798675200;
    tResetRegion();
    resetForTests();
    t_has_file = false;
    _ = init(t_be);
    // Fresh region stamps silently.
    try testing.expectEqual(ROT_STAMPED, onWallTime(T));
    try testing.expectEqual(T, readU64(OFF_CREATED));
    // Within lifetime: no rotation, seed stable.
    var s0: [32]u8 = undefined;
    readBytes(OFF_SEED, &s0);
    try testing.expectEqual(ROT_OK, onWallTime(T + types.IDENTITY_LIFETIME_S - 1));
    var s1: [32]u8 = undefined;
    readBytes(OFF_SEED, &s1);
    try testing.expectEqualSlices(u8, &s0, &s1);
    // Past lifetime: new epoch (seed, created, cleared ack/SOS state).
    var demofr: [521]u8 = undefined;
    _ = createDemoSos(&demofr) orelse return error.MintFailed;
    try testing.expectEqual(ROT_ROTATED, onWallTime(T + types.IDENTITY_LIFETIME_S));
    var s2: [32]u8 = undefined;
    readBytes(OFF_SEED, &s2);
    try testing.expect(!std.mem.eql(u8, &s1, &s2));
    try testing.expectEqual(T + types.IDENTITY_LIFETIME_S, readU64(OFF_CREATED));
    const st = status();
    try testing.expect(st.bits & 1 == 0);
    try testing.expect(st.bits & 2 == 0);
    // Backwards clock also rotates.
    try testing.expectEqual(ROT_ROTATED, onWallTime(T));
    var s2b: [32]u8 = undefined;
    readBytes(OFF_SEED, &s2b);
    // Rotation survives restart with the newest seed.
    resetForTests();
    tResetRegion();
    try testing.expectEqual(INIT_LOADED, init(t_be));
    var s3: [32]u8 = undefined;
    readBytes(OFF_SEED, &s3);
    try testing.expectEqualSlices(u8, &s2b, &s3);
}
