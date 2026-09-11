//! Host-testit Linux-trap-ytimelle (VSL-4B).
//!
//! **Vastuu**: Käännösvektorit + uname-sisältö + linux_abi-vastaavuus ilman
//! laitteistoa. Kehys/kaappaus/emulaatio on boot-katettu.

const std = @import("std");
const trap = @import("linux_trap_core");
const linux_abi = @import("vsl_abi");

test "trap translates linux numbers" {
    // write(1) → 1.
    try std.testing.expectEqual(@as(u64, 1), trap.translate(1).zinux);
    // exit(60) → 2.
    try std.testing.expectEqual(@as(u64, 2), trap.translate(60).zinux);
    // read(0) → 11 (konsoli; tiedosto-fd:t 4B.x).
    try std.testing.expectEqual(@as(u64, 11), trap.translate(0).zinux);
    // getpid(39) → 3.
    try std.testing.expectEqual(@as(u64, 3), trap.translate(39).zinux);
    // brk/mmap → 23.
    try std.testing.expectEqual(@as(u64, 23), trap.translate(12).zinux);
    try std.testing.expectEqual(@as(u64, 23), trap.translate(9).zinux);
    // openat(257) → 29, close(3) → 31.
    try std.testing.expectEqual(@as(u64, 29), trap.translate(257).zinux);
    try std.testing.expectEqual(@as(u64, 31), trap.translate(3).zinux);
    // uname(63) → sisäinen (ei Zinux-numeroa).
    try std.testing.expect(trap.translate(63) == .internal_uname);
    // Tuntematon (9999) + signaali-esimerkki (rt_sigaction=13) → unsupported.
    try std.testing.expect(trap.translate(9999) == .unsupported);
    try std.testing.expect(trap.translate(13) == .unsupported);
    // Uname-tavut "VSL 0.1" (7 tavua).
    try std.testing.expectEqualSlices(u8, "VSL 0.1", trap.UNAME_BYTES);
}

test "trap agrees with linux_abi table" {
    // Jokainen linux_abi:n kääntämä numero kääntyy samoin trapissa —
    // kahta totuutta ei synny (scope-kaavan sopimustesti).
    const cases = [_]u64{
        linux_abi.LINUX_READ,
        linux_abi.LINUX_WRITE,
        linux_abi.LINUX_MMAP,
        linux_abi.LINUX_BRK,
        linux_abi.LINUX_GETPID,
        linux_abi.LINUX_EXIT,
        linux_abi.LINUX_OPENAT,
        linux_abi.LINUX_CLOSE,
    };
    for (cases) |lnr| {
        // Molemmat tuntevat numeron.
        const z1 = linux_abi.linuxToZinux(lnr) orelse return error.TestFailed;
        const act = trap.translate(lnr);
        // Suora käännös molemmissa — sama kohde.
        try std.testing.expectEqual(z1, act.zinux);
    }
    // uname: molemmissa ei-suora (sisäinen molemmilla puolilla).
    try std.testing.expect(linux_abi.linuxToZinux(linux_abi.LINUX_UNAME) == null);
    try std.testing.expect(linux_abi.isHandledInternally(linux_abi.LINUX_UNAME));
    try std.testing.expect(trap.translate(linux_abi.LINUX_UNAME) == .internal_uname);
}
