//! Stub monotonic and wall clocks for the ARM64 Phase 2 guest.
//!
//! Monotonic time is a simple tick counter advanced by each `tick`
//! (the SVC layer ticks once per read). Wall time has no RTC behind it
//! yet, so reads fail closed with NOT_READY until a future phase wires
//! an Android-consent-bound provider.

pub const OK: u64 = 0;
pub const NOT_READY: u64 = 1;

var ticks: u64 = 0;

pub fn reset() void {
    ticks = 0;
}

/// Advance one tick and return the new value. Wrapping add keeps the
/// interface total; ordering (never going backwards except on wrap) is
/// what the guest relies on.
pub fn mono() u64 {
    ticks = ticks +% 1;
    return ticks;
}

pub fn wall(out: *u64) u64 {
    _ = out;
    return NOT_READY;
}

test "monotonic ticks never go backwards" {
    const testing = @import("std").testing;
    reset();
    const a = mono();
    const b = mono();
    const c = mono();
    try testing.expect(a >= 1);
    try testing.expect(b == a + 1);
    try testing.expect(c == b + 1);
}

test "wall clock is not ready before a provider exists" {
    const testing = @import("std").testing;
    reset();
    var v: u64 = 0xdead;
    try testing.expectEqual(NOT_READY, wall(&v));
    try testing.expectEqual(@as(u64, 0xdead), v);
}
