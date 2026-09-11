//! Watchdog-ydin — valvontataulu + kelpoisuuspredikaatti (31.5.5, puhdas).
//!
//! **Vastuu**: Koneisto ilman laitteistoa: ketä valvotaan (pid→cpid+pml4),
//!   milloin fault kuuluu watchdogille (P&W&U + checkpoint olemassa) —
//!   päätös, ei mekanismia. Mekanismi (`watchdog.zig`) ja #PF-koukku
//!   (`idt.zig`) käyttävät näitä.
//! **Riippuvuudet**: ei (puhdas logiikka — sama kaava kuin `scope.zig`)
//! **Käytetään**: `kernel/watchdog.zig`, host-testit.
//!
//! ## Politiikka (AGENTS.md: kernel päättää, dokumentoi rajat)
//! - Watchdog käynnistyy ENSIMMÄISESTÄ kaapatusta crashista (ei 3-strikea):
//!   kaatumista ei voi jatkaa (viallinen käsky faultaisi uudelleen), joten
//!   ainoa turvallinen vastaus on containment (restore + restart).
//!   Diagin 3-vikaraja on DEGRADED-seurantaa varten (pehmeät viat), eri asia.
//! - Vain checkpointatut plugin-prosessit: ilman kopiota ei ole mihin palata.

// Montako pluginia valvonnassa (pieni, mitattava raja).
pub const MAX_WATCHED: usize = 4;

// #PF-virhekoodin bitit (x86_64 fault error code).
pub const PF_BIT_PRESENT: u64 = 1 << 0;
pub const PF_BIT_WRITE: u64 = 1 << 1;
pub const PF_BIT_USER: u64 = 1 << 2;

// Yksi valvottu plugin.
pub const Watched = struct {
    // Onko paikka käytössä.
    used: bool,
    // Valvotun pluginin pid.
    pid: u64,
    // Checkpoint-id palautusta varten.
    cpid: u32,
    // PML4 watch-hetkellä (CR3-täsmäys faultissa).
    pml4_phys: u64,
    // Kaapattujen crashien määrä (saturaatio alla).
    crashes: u32,
};

// Kiinteä valvontataulukko — ei allokaatiota.
var watched: [MAX_WATCHED]Watched = undefined;
// Onko taulukko nollattu.
var watched_init: bool = false;

// Nollaa taulukko tarvittaessa.
fn ensureInit() void {
    // Jo alustettu — ei työtä.
    if (watched_init) return;
    // Tyhjennä jokainen paikka.
    for (&watched) |*w| {
        // Merkitse vapaa.
        w.used = false;
        // Nollaa pid.
        w.pid = 0;
        // Nollaa cpid.
        w.cpid = 0;
        // Nollaa PML4.
        w.pml4_phys = 0;
        // Nollaa laskuri.
        w.crashes = 0;
    }
    // Merkitse alustetuksi.
    watched_init = true;
}

// Kuuluuko fault watchdogille: käyttäjätila + checkpoint olemassa.
// P/W-bittejä ei vaadita (not-present-luku on tyypillisin kaatuminen).
// Kernel-/SMAP-faultit eivät kuulu (vanhalle log+halt-polulle).
// Puhdas predikaatti — host-testattava.
pub fn eligibleForClaim(error_code: u64, has_checkpoint: bool) bool {
    // Ei checkpointia → ei mihin palata → ei kuulu.
    if (!has_checkpoint) return false;
    // Vaadi käyttäjätila: kernel-tilan fault (ml. SMAP) on todellinen vika.
    if ((error_code & PF_BIT_USER) == 0) return false;
    // P- ja W-bittejä EI vaadita: not-present-luku (P=0) on yleisin
    // kaatumisluokka, eikä kirjoitusvaatimus kuulu crash-politiikkaan.
    // Dirty-seuranta (W-suojausfaultit) tarkistetaan AINA ensin wrapperissa
    // tiukemmalla P&W&U+inventaarilla, joten tämä haara näkee vain kaatumiset.
    return true;
}

// Etsi valvontapaikan indeksi pid:llä — null jos ei valvota.
fn findIdx(pid: u64) ?usize {
    // Varmista nollattu taulukko.
    ensureInit();
    // Käy paikat.
    var i: usize = 0;
    while (i < MAX_WATCHED) : (i += 1) {
        // Käytössä + pid täsmää.
        if (watched[i].used and watched[i].pid == pid) return i;
    }
    // Ei valvonnassa.
    return null;
}

// Onko pid valvonnassa.
pub fn isWatched(pid: u64) bool {
    // Indeksi löytyy → valvotaan.
    return findIdx(pid) != null;
}

// Hae paikka jaettuna viitteenä pid:llä — null jos ei valvota.
pub fn slotByPid(pid: u64) ?*Watched {
    // Hae indeksi.
    const idx = findIdx(pid) orelse return null;
    // Palauta osoitin paikkaan.
    return &watched[idx];
}

// Hae pid valvonta-CR3:lla (fault-konteksti, currentPid voi olla vanha).
pub fn pidByCr3(cr3: u64) ?u64 {
    // Varmista nollattu taulukko.
    ensureInit();
    // Käy paikat.
    var i: usize = 0;
    while (i < MAX_WATCHED) : (i += 1) {
        // Käytössä + PML4 täsmää.
        if (watched[i].used and watched[i].pml4_phys == cr3) return watched[i].pid;
    }
    // Ei täsmää.
    return null;
}

// Montako pluginia valvonnassa.
pub fn count() usize {
    // Varmista nollattu taulukko.
    ensureInit();
    // Laskuri.
    var n: usize = 0;
    // Käy paikat.
    for (watched) |w| {
        // Käytössä → laske.
        if (w.used) n += 1;
    }
    // Palauta määrä.
    return n;
}

// Aloita valvonta — false jos täynnä (fail-closed).
pub fn watch(pid: u64, cpid: u32, pml4_phys: u64) bool {
    // Varmista nollattu taulukko.
    ensureInit();
    // Jo valvonnassa → päivitä cpid/PML4 (uusi checkpoint samalle pidille).
    if (findIdx(pid)) |idx| {
        // Päivitä checkpoint-viite.
        watched[idx].cpid = cpid;
        // Päivitä PML4 (swap on saattanut vaihtaa).
        watched[idx].pml4_phys = pml4_phys;
        // Onnistui.
        return true;
    }
    // Etsi vapaa paikka.
    var i: usize = 0;
    while (i < MAX_WATCHED) : (i += 1) {
        // Vapaa paikka löytyi.
        if (!watched[i].used) {
            // Merkitse käytetyksi.
            watched[i].used = true;
            // Sido pidiin.
            watched[i].pid = pid;
            // Tallenna checkpoint-viite.
            watched[i].cpid = cpid;
            // Tallenna PML4 CR3-täsmäykseen.
            watched[i].pml4_phys = pml4_phys;
            // Nollaa crash-laskuri.
            watched[i].crashes = 0;
            // Onnistui.
            return true;
        }
    }
    // Taulukko täynnä.
    return false;
}

// Lopeta valvonta — false jos ei ollut valvonnassa.
pub fn unwatch(pid: u64) bool {
    // Hae paikka.
    const slot = slotByPid(pid) orelse return false;
    // Merkitse vapaaksi.
    slot.used = false;
    // Nollaa crash-laskuri.
    slot.crashes = 0;
    // Onnistui.
    return true;
}

// Kirjaa kaapattu crash (saturaatio) — false jos ei valvota.
pub fn recordCrash(pid: u64) bool {
    // Hae paikka.
    const slot = slotByPid(pid) orelse return false;
    // Kasvata kattoon asti (ei kierry nollaan).
    slot.crashes +|= 1;
    // Onnistui.
    return true;
}

// Kaapattujen crashien määrä — null jos ei valvota.
pub fn crashCount(pid: u64) ?u32 {
    // Hae paikka.
    const slot = slotByPid(pid) orelse return null;
    // Palauta laskuri.
    return slot.crashes;
}
