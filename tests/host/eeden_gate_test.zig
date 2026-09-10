//! Host-testit Eeden-portille: simulaation mittarit + kynnykset (Vaihe 37.2).
//!
//! **Vastuu**: Simulaation tarkat luvut (vika-aikataulu → laskurit),
//!   deterministisyys (kaksi ajoa → sama raportti) sekä portin läpäisy +
//!   pettäminen nimetyllä bitillä. QEMU-mekanismi on `kernel/eeden.zig`:ssä.

// Tuo standardikirjasto testiasserteja varten.
const std = @import("std");
// Tuo simulaatioydin (30 päivää pikakelattuna).
const sim = @import("eeden_sim");
// Tuo porttikriteerit (kynnykset + maski).
const metrics = @import("eeden_metrics");

test "eeden sim produces exact lifecycle metrics" {
    // Aja 30 päivää.
    const rep = sim.run();
    // Boot + tehtävä päivänä 0.
    try std.testing.expect(rep.boot_ok);
    try std.testing.expect(rep.task_ok);
    // Yksi kokoonpano alusta purkuun.
    try std.testing.expectEqual(@as(u64, 1), rep.compositions_started);
    try std.testing.expectEqual(@as(u64, 1), rep.compositions_done);
    // Viisi vikapäivää, päivänä 12 kaksoisinjektio → 6 vikaa, 1 kaatuminen.
    try std.testing.expectEqual(@as(u64, 6), rep.faults);
    try std.testing.expectEqual(@as(u64, 5), rep.fault_days);
    try std.testing.expectEqual(@as(u64, 1), rep.crashes);
    // Jokainen vikapäivä päättyi parannukseen (5/5).
    try std.testing.expectEqual(@as(u64, 5), rep.heals);
    // Yksi migraatio (päivä 14) + yksi todennettu tunnelityöntö.
    try std.testing.expectEqual(@as(u64, 1), rep.migrations);
    try std.testing.expectEqual(@as(u64, 1), rep.tunnel_grants_ok);
    // Yksi häviö (päivä 21→22) → yksi ylennys.
    try std.testing.expectEqual(@as(u64, 1), rep.failovers);
    // Täysi 30 päivää, deadline johdotettu, ydin yksin lopussa.
    try std.testing.expectEqual(@as(u64, 30), rep.uptime_days);
    try std.testing.expect(rep.deadline_ok);
    try std.testing.expect(rep.core_only);
}

test "eeden sim is deterministic" {
    // Kaksi ajoa → identtinen raportti (ei satunnaisuutta, ei vuotoa).
    const a = sim.run();
    const b = sim.run();
    try std.testing.expect(std.meta.eql(a, b));
}

test "eeden gate passes good report and names bad checks" {
    // Aito raportti läpäisee portin (maski nolla).
    const good = sim.run();
    const verdict = metrics.evaluate(good);
    try std.testing.expect(verdict.passed());
    try std.testing.expectEqual(@as(u32, 0), verdict.failed_mask);
    // Rikottu raportti (orpo + parantumaton) nimeää tarkistukset.
    var bad = good;
    bad.core_only = false;
    bad.heals = 0;
    const v2 = metrics.evaluate(bad);
    try std.testing.expect(!v2.passed());
    try std.testing.expect(v2.failed_mask & metrics.CHECK_CORE_ONLY != 0);
    try std.testing.expect(v2.failed_mask & metrics.CHECK_HEALED != 0);
    // Ehjä raportti ei sytytä vieraita bittejä.
    try std.testing.expect(v2.failed_mask & metrics.CHECK_BOOT == 0);
    try std.testing.expect(v2.failed_mask & metrics.CHECK_UPTIME == 0);
    // Tarkistusnimiä yhtä monta kuin bittejä (työkalun tulostus).
    try std.testing.expectEqual(@as(usize, 10), metrics.CHECK_NAMES.len);
}
