//! Eeden-elinkaari — synny → palvele → hajoa QEMU:ssa (Vaihe 37, freestanding).
//!
//! **Vastuu**: Todista mekanismi oikealla kernelillä: vastaanota TDL-tehtävä,
//!   sävellä minimaaliympäristö (`composer`), aja se ring 3:ssa, pura LIFO:ssa
//!   ja palaa ydin-yksin-tilaan. 30 päivän autonomia on host-simulaation asia
//!   (`tests/eeden_metrics` + `zig build eeden-gate`); tämä todistaa että
//!   jokainen elinkaaren nivel toimii raudalla (QEMU) scope-portin läpi.
//! **Riippuvuudet**: `composer.zig` (suhteellinen, orkestraattori),
//!   `composer_task` (build-moduuli, TDL-teksti), log.
//! **Käytetään**: `kernel/boot_tests.zig::runAll()` (viimeinen boot-testi).
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Ei uutta mekanismia: pelkkä integraatio vaiheen 34 orkestraattorin päällä.
//!   Jos tämä pettää, vika on elinkaaren liitoksissa, ei yksiköissä (siksi
//!   viimeinen boot-testi — kaikki vaiheet alla on jo todistettu).
//! - Serialit ovat QEMU-rehellisiä (ei "30 päivää" -väitettä raudalla):
//!   pikakelaus-serialit tuottaa host-työkalu; kumpikin puoli dokumentoitu
//!   EEDEN_DEMO:ssa. CI greppaa molemmista saman `Eeden Gate: PASSED`-rivin.
//! - Hajoaminen on onnistuminen: `decomposeTask` + nolla pluginia + ei
//!   aktiivista koostumusta = portti auki. Ydin yksin on tavoitetila.

// Tuo tehtäväorkestraattori — compose/run/decompose (suhteellinen).
const composer = @import("composer.zig");
// Tuo puhdas TDL-ydin (tehtävätekstin laskenta, build-moduuli).
const task = @import("composer_task");
// Tuo lokitus boot-viesteihin (vain staattiset merkkijonot).
const log = @import("lib/log.zig");

// Eeden-tehtävä (sama muoto kuin simulaatiossa — 2 tarvetta, katto 2).
pub const EEDEN_TASK = "task \"serve\" { need port:send+recv; need port:recv; timeout 30000; plugins 2; }";

// Boot-testi — elinkaari päästä päähän oikealla kernelillä (Vaihe 37).
pub fn runBootTest() void {
    // Syntymä: ydin vastaanottaa tehtävän (kiinteä merkkijono — log on comptime).
    log.info("Eeden boot");
    log.info("Eeden task received: serve");
    // Laske tehtävä binäärimuotoon (sama parseri kuin simulaatiossa).
    const spec = task.parse(EEDEN_TASK) catch {
        log.err("Eeden task parse failed");
        return;
    };
    // Sävelllys: minimaaliympäristö scope-portin läpi (ei osittaista).
    log.info("Eeden composing...");
    if (composer.composeTask(spec) != .ok) {
        log.err("Eeden compose failed");
        return;
    }
    // Kaksi pluginia (1:1-minimaalisuus — ei bonusprosesseja).
    if (composer.compositionCount() != 2) {
        log.err("Eeden compose count wrong");
        _ = composer.decomposeTask();
        return;
    }
    // Elämä: aja jokainen ring 3:ssa (tulostaa "plg" per plugin).
    log.info("Eeden running...");
    if (!composer.runComposition()) {
        log.err("Eeden run failed");
        _ = composer.decomposeTask();
        return;
    }
    log.info("Eeden task complete");
    // Hajoaminen: pura LIFO:ssa, mitään ei jää (tavoitetila, ei tragedia).
    log.info("Eeden decomposing...");
    if (!composer.decomposeTask()) {
        log.err("Eeden decompose failed");
        return;
    }
    if (composer.isComposing() or composer.compositionCount() != 0) {
        log.err("Eeden decompose leaked");
        return;
    }
    log.info("Eeden core only");
    // Portti auki raudalla (QEMU-puolisko; simulaatio on toinen).
    log.info("Eeden Gate: PASSED");
}
