//! Eeden-portti — pikakelattu 30 päivän elinkaaritarkistus (Vaihe 37, host-työkalu).
//!
//! **Vastuu**: Aja `eeden_sim.run()` (todelliset puhtaat ytimet, virtuaalikello),
//!   tulosta eeden-serialit + mittarit, arvioi `eeden_metrics`-kynnykset ja
//!   poistu 0 (PASSED) / 1 (FAILED + pettäneet tarkistukset nimettynä).
//!   `zig build eeden-gate` ajaa tämän; CI-portti kaatuu nollasta poikkeavaan.
//! **Riippuvuudet**: `eeden_sim`, `eeden_metrics`, std (host).
//! **Käytetään**: `build.zig` (`eeden-gate`-askel ajaa tämän).
//!
//! ## Arkkitehtuurihuomiot
//! - Serialit ovat simulaation — `[Zinux]`-etuliite on kirjaimellinen osa
//!   riviä (QEMU-puoli tulostaa omat rivinsä ilman etuliitettä; CI greppaa
//!   molemmista saman `Eeden Gate: PASSED`-alimerkkijonon).
//! - Mittaririvi tulostaa AINA todelliset laskurit (ei kovakoodattuja) —
//!   työkalu ei voi väittää PASSEDia väärillä luvuilla (numero + tuomio
//!   samassa ajossa, samasta raportista).

// Tuo Zig std — host-työkalu (tulostus, poistumiskoodi).
const std = @import("std");
// Tuo simulaatioydin (30 päivää, build-moduuli).
const sim = @import("eeden_sim");
// Tuo porttikriteerit (kynnykset, build-moduuli).
const metrics = @import("eeden_metrics");

// Pääohjelma — simu + serialit + tuomio (0 = portti auki, 1 = kiinni).
pub fn main() void {
    // Aja elinkaari (deterministinen — sama raportti joka kerta).
    const rep = sim.run();
    // Eeden-serialit (liite EEDEN_DEMO — pikakelaus, ei 30 oikeaa päivää).
    std.debug.print("[Zinux] Boot\n", .{});
    std.debug.print("[Zinux] Task received\n", .{});
    std.debug.print("[Zinux] Composing...\n", .{});
    std.debug.print("[Zinux] Running (30 days simulated)\n", .{});
    std.debug.print("[Zinux] Task complete\n", .{});
    std.debug.print("[Zinux] Decomposing...\n", .{});
    std.debug.print("[Zinux] Core only\n", .{});
    // Mittaririvi todellisilla laskureilla (työkalu ei keksi lukuja).
    std.debug.print(
        "eeden-metrics: compositions={}/{} faults={} crashes={} heals={} migrations={} failovers={} tunnel_grants={} uptime_days={}\n",
        .{
            rep.compositions_done,
            rep.compositions_started,
            rep.faults,
            rep.crashes,
            rep.heals,
            rep.migrations,
            rep.failovers,
            rep.tunnel_grants_ok,
            rep.uptime_days,
        },
    );
    // Porttituomio samoista luvuista.
    const verdict = metrics.evaluate(rep);
    if (verdict.passed()) {
        // Portti auki.
        std.debug.print("[Zinux] Eeden Gate: PASSED\n", .{});
        return;
    }
    // Portti kiinni — nimeä pettäneet tarkistukset (vastalause, ei hiljaisuus).
    var i: usize = 0;
    while (i < metrics.CHECK_NAMES.len) : (i += 1) {
        if (verdict.failed_mask & (@as(u32, 1) << @intCast(i)) != 0) {
            std.debug.print("eeden-gate: FAILED check '{s}'\n", .{metrics.CHECK_NAMES[i]});
        }
    }
    std.debug.print("[Zinux] Eeden Gate: FAILED\n", .{});
    // Nollasta poikkeava kaataa build-askeleen + CI-portin.
    std.process.exit(1);
}
