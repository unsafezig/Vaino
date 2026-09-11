//! Watchdog — crash-capture + restart-politiikka (31.5.5, mekanismi).
//!
//! **Vastuu**: Valvo checkpointattuja plugineja: kaappaa kaatuminen
//!   (#PF-koukku → restore + diag + laskuri), boot-testi toteuttaa
//!   restartin (unload + reload) turvallisessa kontekstissa — EI
//!   keskeytyskäsittelijässä.
//! **Riippuvuudet**: `watchdog_core.zig` (puhdas taulu+predikaatti),
//!   `snapshot.zig` (restore + checkpoint-kyselyt), `process_core`
//!   (PML4 + currentPid), `plugin_diag.zig` (syykirjaus), `lib/log.zig`,
//!   `arch/x86_64/paging.zig` (kernel-CR3-palautus ennen kirjausta),
//!   boot-testissä `syscall/dispatch.zig` + `plugin/loader.zig`
//! **Käytetään**: `arch/x86_64/idt.zig` (claimFault-koukku), `boot_tests.zig`
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Kaatumista ei jatketa (viallinen käsky faultaisi uudelleen) eikä
//!   restartata IRQ-kontekstissa (allokaatiot + ELF-lataus eivät kuulu
//!   käsittelijään): käsittelijä tekee vain turvallisen minimin (restore
//!   memcpy + kirjaus) ja palauttaa boot-testin kontekstiin, joka päättää.
//! - Diagin 3-vikaraja on pehmeiden vikojen seurantaa; watchdog käynnistyy
//!   ensimmäisestä kaapatusta crashista (containment, ei äänestystä).
//! - Invariantti: käyttäjätilan fault ⟹ enterUserAs on ajanut ⟹
//!   `usermode_saved_kernel_rsp` + `saved_kernel_cr3` ovat kelvolliset
//!   (crash-paluu nojaa molempiin; kernel-faultit eivät koskaan päädy
//!   claimiin, U-bitti vaaditaan).
//! - Kaappaus vaihtaa kernel-CR3:een ennen restorea/lokitusta: #PF saapuu
//!   pluginin CR3:lla, jonka alapuolisko ei kata kernel-kartoituksia
//!   (VGA 0xB8000). Kirjaus plugin-avaruudesta faultaisi sisäkkäin.

// Tuo puhdas valvontataulu + kelpoisuuspredikaatti.
const core = @import("watchdog_core.zig");
// Tuo snapshot — restore + checkpoint-kyselyt.
const snapshot = @import("snapshot.zig");
// Tuo prosessitaulukko — PML4 + currentPid-palautus boot-testille.
const process = @import("process_core");
// Tuo diagnostiikka — tarkan kaatumissyyn kirjaus.
const diag = @import("plugin_diag.zig");
// Tuo lokitus kaappausriville (info — K2 ei laske näitä).
const log = @import("lib/log.zig");
// Tuo paging — CR3-luku/palautus (kaappaus jatkuu kernel-avaruudessa).
const paging = @import("arch/x86_64/paging.zig");
// Tallennettu kernel-CR3 (usermode.zig export — luetaan, ei kirjoiteta).
// Asetettu enterUserAs:ssa ennen jokaista ring-3-siirtymää.
extern var saved_kernel_cr3: u64;
// Tuo dispatch — sys_plugin_load/unload/checkpoint invoke (boot-testi).
const dispatch = @import("syscall/dispatch.zig");
// Tuo loader — CRASH_EMBEDDED_ID + runPlugin (boot-testi).
const loader = @import("plugin/loader.zig");
// Tuo scope-maskit manifestivektoriin (boot-testi, vsl-kaava).
const scope = @import("plugin/scope.zig");
// Tuo jaettu ABI — syscall-numerot + virheet (boot-testi).
const abi = @import("zinuxabi");

// Aloita valvonta: rekisteröi diag-rivi (best-effort) + taulukko.
pub fn watch(pid: u64, cpid: u32) bool {
    // Hae PML4 CR3-täsmäykseen (fault-kontekstissa currentPid voi olla vanha).
    const pml4 = process.getPageTable(pid) orelse return false;
    // Jaettu/nolla-taulu ei kelpaa.
    if (pml4 == 0) return false;
    // Rekisteröi diag-rivi kaatumissyytä varten (täysi taulukko ei estä).
    _ = diag.registerDiagnostic(pid);
    // Sido valvontaan.
    return core.watch(pid, cpid, pml4);
}

// Lopeta valvonta + siivoa diag-rivi.
pub fn unwatch(pid: u64) bool {
    // Poista diag-rivi (vain oma pid — muiden rivit säilyvät).
    _ = diag.deregisterDiagnostic(pid);
    // Poista taulukosta.
    return core.unwatch(pid);
}

// Montako pluginia valvonnassa.
pub fn watchedCount() usize {
    // Delegoi ytimeen.
    return core.count();
}

// Kaapattujen crashien määrä — null jos ei valvota.
pub fn crashCount(pid: u64) ?u32 {
    // Delegoi ytimeen.
    return core.crashCount(pid);
}

// #PF-koukun kutsuma: kaappaa valvotun pluginin kaatuminen.
// Palauttaa true jos käsitelty (ei lokia K2-mielessä — vain info-rivi),
// false jos vieras (käsittelijä jatkaa vanhalla log+halt-polulla).
// RAJAUS: täsmäys on AVARUUS-tasolla (CR3), ei sivutasolla — kaatuminen
// kohdistuu tyypillisesti kartoittamattomaan sivuun (not-present), joka ei
// ole inventaarissa. Dirty-seuranta (W-suojausfaultit inventoiduille
// sivuille) tarkistetaan AINA ensin wrapperissa, joten tämä haara näkee
// vain todelliset kaatumiset.
pub fn claimFault(fault_cr3: u64, fault_virt: u64, error_code: u64) bool {
    // Sivuosoite vain lokituskontekstina (ei porttia — katso rajaus yllä).
    _ = fault_virt;
    // Etsi valvottu pid faulttaavasta avaruudesta (CR3-täsmäys).
    const pid = core.pidByCr3(fault_cr3) orelse return false;
    // Checkpoint oltava (mihin palata) — muuten ei kuulu.
    if (snapshot.findCheckpointForPid(pid) == null) return false;
    // Kelpoisuus: käyttäjätila (puhdas predikaatti, host-testattu).
    // P/W-bittejä ei vaadita (not-present-luku on tyypillisin kaatuminen).
    if (!core.eligibleForClaim(error_code, true)) return false;
    // Vaihda kernel-avaruuteen ENNEN sivukopioita/lokitusta: #PF saapuu
    // pluginin CR3:lla, jonka ala-puolisko ei sisällä kernel-kartoituksia
    // (VGA 0xB8000, matalat rakenteet). Ilman palautusta log.info:n VGA-
    // kirjoitus faultaa sisäkkäin ja paluu boot-testiin jatkuisi väärässä
    // avaruudessa (sama kuri kuin usermodeReturnToKernel, Vaihe 26).
    // fault_cr3-parametri on jo tallessa — haku ei tarvitse nykyistä CR3:a.
    const kcr3: u64 = saved_kernel_cr3;
    // Nolla tarkoittaa ettei ring-3-siirtymää ole tehty — ei pitäisi
    // tapahtua tässä (U-bitti vaadittu yllä), kieltäydy fail-closed.
    if (kcr3 == 0) return false;
    paging.setCr3(kcr3);
    // Palauta sivut checkpointista (best-effort — sisältö todennäköisesti
    // ehjä; restart ei tarvitse tätä, mutta jatkuvuus paranee).
    snapshot.restorePlugin(pid) catch {};
    // Kirjaa tarkka syy diag-riville (crashed_fault-luokka).
    diag.recordFaultTyped(pid, -14, .crashed_fault);
    // Laskuri (boot-testi todistaa kaappauksen tästä, ei arvailusta).
    _ = core.recordCrash(pid);
    // Kaappausrivi serialiin (info — ei K2-virhe).
    log.info("Watchdog captured crash");
    // Käsitelty — wrapper palaa boot-testin kontekstiin (RSP restore + ret),
    // nyt kernel-CR3:lla joten boot-koodi näkee kaikki kartoituksensa.
    return true;
}

// Lataa crash-test-ELF valvontavektorilla — palauttaa pid tai 0.
fn loadCrasher() u64 {
    // Port/send-manifesti, laaja scope (ei grantia).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.CRASH_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("Watchdog load failed");
        // Nolla = ei pid:iä.
        return 0;
    }
    // Palauta pid.
    return @intCast(pid_raw);
}

// Siivoa crash-demo: unwatch + unload (checkpointin delete hoituu unloadissa).
fn cleanupCrasher(pid: u64) void {
    // Poista valvonta + diag-rivi.
    _ = unwatch(pid);
    // Nykyinen pid bootiksi (crash jätti kaatuneen).
    _ = process.setCurrentPid(process.BOOT_PID);
    // Pura plugin (checkpoint-reclaim mukana).
    _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
}

// Boot-testi — kaappaa aito ring-3-kaatuminen + restart-policy (31.5.5).
pub fn runBootTest() void {
    // Negatiivit: haamu-pid ei valvontaan, tuntematon ei pois.
    if (watch(9999, 1)) {
        // Haamu valvontaan → väärin.
        log.err("Watchdog ghost watched");
        return;
    }
    if (unwatch(9999)) {
        // Tuntemattoman purku onnistui → väärin.
        log.err("Watchdog ghost unwatched");
        return;
    }
    // Lataa kaatuja.
    const pid = loadCrasher();
    // Lataus epäonnistui (virhe jo lokitettu).
    if (pid == 0) return;
    // Checkpoint ennen ajoa (terve tila talteen).
    const cpid_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, pid, 0, 0, 0, 0, 0);
    // Varmista positiivinen cpid.
    if (cpid_raw <= 0) {
        // Checkpoint epäonnistui.
        log.err("Watchdog checkpoint failed");
        // Siivoa lataus.
        cleanupCrasher(pid);
        return;
    }
    // Checkpoint-id u32:na.
    const cpid: u32 = @intCast(cpid_raw);
    // Valvonta päälle.
    if (!watch(pid, cpid)) {
        // Valvonta epäonnistui.
        log.err("Watchdog watch failed");
        // Siivoa checkpoint (unload hoitaa) + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    }
    // Ei kaatumisia vielä.
    const c0 = crashCount(pid) orelse {
        // Laskuri puuttuu heti valvonnan jälkeen.
        log.err("Watchdog count missing");
        // Siivoa.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    };
    if (c0 != 0) {
        // Tuore valvonta ei ole puhdas.
        log.err("Watchdog count not zero");
        // Siivoa.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    }
    // Aja kaatuja ring 3:ssa: not-present-luku → AITO #PF → watchdog
    // kaappaa (restore + diag + laskuri) → crash-paluu boot-testiin.
    if (!loader.runPlugin(pid)) {
        // Ajo epäonnistui (paluuta ei tullut).
        log.err("Watchdog run failed");
        // Siivoa.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    }
    // Nykyinen pid takaisin bootiksi (crash jätti kaatuneen).
    _ = process.setCurrentPid(process.BOOT_PID);
    // Tasan yksi kaapattu crash (laitetodiste, ei arvailu).
    const c1 = crashCount(pid) orelse {
        // Laskuri katosi ajon aikana.
        log.err("Watchdog count lost");
        // Siivoa.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    };
    if (c1 != 1) {
        // Väärä kaatumamäärä (odota 1).
        log.err("Watchdog count not one");
        // Siivoa.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    }
    // Diag integroitu: yksi vika → degraded (ei healthy, ei vielä crashed).
    if (diag.getHealth(pid) != .degraded) {
        // Diag-luokka väärä.
        log.err("Watchdog health not degraded");
        // Siivoa.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupCrasher(pid);
        return;
    }
    // Kaappaus todistettu.
    log.info("Crash captured");
    // Restart-policy: pura kaatunut (unload poistaa checkpointin).
    _ = process.setCurrentPid(process.BOOT_PID);
    if (dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("Watchdog unload failed");
        // Siivoa valvonta silti.
        _ = unwatch(pid);
        return;
    }
    // Poista valvonta (diag-rivi mukana).
    _ = unwatch(pid);
    // Uusi instanssi samasta ELF:stä (restart).
    const pid2 = loadCrasher();
    // Lataus epäonnistui.
    if (pid2 == 0) return;
    // Checkpoint + valvonta uudelle instanssille.
    const cpid2_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, pid2, 0, 0, 0, 0, 0);
    // Varmista positiivinen cpid.
    if (cpid2_raw <= 0) {
        // Checkpoint epäonnistui.
        log.err("Watchdog recheckpoint failed");
        // Siivoa lataus.
        cleanupCrasher(pid2);
        return;
    }
    // Valvonta päälle.
    if (!watch(pid2, @intCast(cpid2_raw))) {
        // Valvonta epäonnistui.
        log.err("Watchdog rewatch failed");
        // Siivoa lataus (unload hoitaa checkpointin).
        cleanupCrasher(pid2);
        return;
    }
    // Aja uudelleen — kaatuu deterministisesti (sama ELF).
    if (!loader.runPlugin(pid2)) {
        // Ajo epäonnistui.
        log.err("Watchdog rerun failed");
        // Siivoa.
        cleanupCrasher(pid2);
        return;
    }
    // Nykyinen pid takaisin bootiksi.
    _ = process.setCurrentPid(process.BOOT_PID);
    // Toinenkin kaatuminen kaapattu (politiikka toistettavissa).
    const c2 = crashCount(pid2) orelse {
        // Laskuri katosi.
        log.err("Watchdog recount missing");
        // Siivoa.
        cleanupCrasher(pid2);
        return;
    };
    if (c2 != 1) {
        // Väärä kaatumamäärä uusinnassa.
        log.err("Watchdog recount not one");
        // Siivoa.
        cleanupCrasher(pid2);
        return;
    }
    // Siivoa toinen instanssi.
    cleanupCrasher(pid2);
    // Valvonta tyhjä (ei vuotoja).
    if (watchedCount() != 0) {
        // Valvonta jäi roikkumaan.
        log.err("Watchdog leak");
        return;
    }
    // Kaappaus + restart-policy + purku OK.
    log.info("Watchdog restart OK");
}
