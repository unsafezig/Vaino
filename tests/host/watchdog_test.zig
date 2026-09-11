//! Host-testit watchdog-ytimelle (31.5.5).
//!
//! **Vastuu**: Kelpoisuusmatriisi + valvontataulun elinkaari ilman laitteistoa.
//! Mekanismi (restore/diag/boot-ajo) on boot-katettu.

const std = @import("std");
const wd = @import("watchdog_core");

test "watchdog eligibility matrix" {
    // P&W&U + checkpoint → kuuluu.
    try std.testing.expect(wd.eligibleForClaim(0x7, true));
    // Ei checkpointia → ei kuulu (ei mihin palata).
    try std.testing.expect(!wd.eligibleForClaim(0x7, false));
    // Not-present-luku (P=0, crasher-luokka) + checkpoint → KUULUU.
    try std.testing.expect(wd.eligibleForClaim(0x4, true));
    // Not-present-kirjoitus + checkpoint → kuuluu.
    try std.testing.expect(wd.eligibleForClaim(0x6, true));
    // Present-luku + checkpoint → kuuluu (villi osoite).
    try std.testing.expect(wd.eligibleForClaim(0x5, true));
    // Nolla + checkpoint → ei kuulu (U puuttuu — kernel-konteksti).
    try std.testing.expect(!wd.eligibleForClaim(0x0, true));
    // Supervisor (U=0, ml. SMAP) → ei kuulu koskaan.
    try std.testing.expect(!wd.eligibleForClaim(0x3, true));
    try std.testing.expect(!wd.eligibleForClaim(0x2, true));
    try std.testing.expect(!wd.eligibleForClaim(0x1, true));
    // Nolla ilman checkpointia → ei kuulu.
    try std.testing.expect(!wd.eligibleForClaim(0x0, false));
}

test "watchdog table watch unwatch crash" {
    // Haamu: ei valvota, ei laskuria, ei purkua.
    try std.testing.expect(!wd.isWatched(42));
    try std.testing.expect(wd.crashCount(42) == null);
    try std.testing.expect(!wd.unwatch(42));
    try std.testing.expectEqual(@as(usize, 0), wd.count());
    try std.testing.expect(wd.pidByCr3(0xDEAD) == null);
    // Valvonta päälle (cpid 5, PML4 0xB000).
    try std.testing.expect(wd.watch(42, 5, 0xB000));
    try std.testing.expect(wd.isWatched(42));
    try std.testing.expectEqual(@as(usize, 1), wd.count());
    // CR3-täsmäys löytää pidin.
    try std.testing.expectEqual(@as(u64, 42), wd.pidByCr3(0xB000) orelse return error.TestFailed);
    // Väärä CR3 ei täsmää.
    try std.testing.expect(wd.pidByCr3(0xB001) == null);
    // Uudelleen-watch päivittää (sama pid, uusi cpid) — ei tuplaa.
    try std.testing.expect(wd.watch(42, 6, 0xB000));
    try std.testing.expectEqual(@as(usize, 1), wd.count());
    // Crash-kirjaus + saturating-laskuri.
    try std.testing.expect(wd.recordCrash(42));
    try std.testing.expectEqual(@as(u32, 1), wd.crashCount(42) orelse return error.TestFailed);
    try std.testing.expect(wd.recordCrash(42));
    try std.testing.expectEqual(@as(u32, 2), wd.crashCount(42) orelse return error.TestFailed);
    // Haamun kirjaus epäonnistuu.
    try std.testing.expect(!wd.recordCrash(43));
    // Purku + tyhjä taulu.
    try std.testing.expect(wd.unwatch(42));
    try std.testing.expect(!wd.isWatched(42));
    try std.testing.expectEqual(@as(usize, 0), wd.count());
}

test "watchdog table full rejects fifth" {
    // Täytä kaikki 4 paikkaa.
    var i: u64 = 0;
    while (i < 4) : (i += 1) {
        try std.testing.expect(wd.watch(200 + i, @intCast(i + 1), 0xC000 + i * 0x1000));
    }
    // Laskuri täynnä.
    try std.testing.expectEqual(@as(usize, 4), wd.count());
    // Viides → false (fail-closed).
    try std.testing.expect(!wd.watch(999, 9, 0xF000));
    // Vapauta yksi → tilaa yhdelle.
    try std.testing.expect(wd.unwatch(201));
    try std.testing.expect(wd.watch(999, 9, 0xF000));
    // Siivoa loput.
    try std.testing.expect(wd.unwatch(200));
    try std.testing.expect(wd.unwatch(202));
    try std.testing.expect(wd.unwatch(203));
    try std.testing.expect(wd.unwatch(999));
    try std.testing.expectEqual(@as(usize, 0), wd.count());
}
