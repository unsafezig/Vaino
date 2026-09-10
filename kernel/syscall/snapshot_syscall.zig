//! Snapshot boot-testi — inventaario (31.5.1) + checkpoint (31.5.2).
//!
//! **Vastuu**: Lataa VSL, todenna PML4-kävely + checkpoint-kopio + W=0-suojaus
//!   + purku. Itse-contained: ei residenttejä, ei kirjoituksia suojattuihin
//!   sivuihin (W=0 faulttaa — dirty-seuranta on 31.5.4:ää).
//! **Riippuvuudet**: `dispatch.zig` (invoke), `../snapshot.zig` (walk +
//!   checkpoint), `../plugin/loader.zig` (VSL id), `../plugin/scope.zig`
//!   (manifest-vektori), `zinuxabi`, `../arch/x86_64/paging.zig` (PTE-luku),
//!   `../mm/vmm.zig` (HHDM-vertailu), log
//! **Käytetään**: `kernel/boot_tests.zig` (vsl_fs-testin jälkeen)

// Tuo dispatch — invoke() suoraan ilman ring 3.
const dispatch = @import("dispatch.zig");
// Tuo snapshot-ydin — walk + checkpoint + delete.
const snapshot = @import("../snapshot.zig");
// Tuo plugin-loader — VSL_EMBEDDED_ID.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit manifesti+scope-vektoriin (sama kuin vsl_syscall).
const scope = @import("../plugin/scope.zig");
// Tuo jaettu ABI — sys_plugin_load/unload/checkpoint-numerot + virheet.
const abi = @import("zinuxabi");
// Tuo paging — PTE W-bitin luku suojatodisteeseen.
const paging = @import("../arch/x86_64/paging.zig");
// Tuo VMM — HHDM-ikkuna kopiovertailuun.
const vmm = @import("../mm/vmm.zig");
// Tuo SMAP-yhteensopivuus — stac/clac HHDM-kirjoituksiin.
const user_access = @import("../arch/x86_64/user_access.zig");
// Tuo prosessitaulukko — page_table pid:llä.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// VSL-pluginin linkkiosoite (userland/vsl/user.ld) — inventaarion ankkuri.
const VSL_BASE: u64 = 0xFFFFFFFF90094000;

// Lataa VSL täydellä valvontapolulla — palauttaa pid tai 0 (virhe jo lokitettu).
fn loadVsl() u64 {
    // Port/send-manifesti, VSL-scope (portti+muisti, ei grant).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.VSL_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("Snapshot load failed");
        // Nolla = ei pid:iä.
        return 0;
    }
    // Palauta pid.
    return @intCast(pid_raw);
}

// Vertaa kahta 4 KiB sivua HHDM-osoitteista — true jos samat.
fn pagesEqual(a_phys: u64, b_phys: u64) bool {
    // Sivut CPU-osoitteisiin.
    const a: [*]const u8 = @ptrFromInt(vmm.physToVirt(a_phys));
    const b: [*]const u8 = @ptrFromInt(vmm.physToVirt(b_phys));
    // Käy tavut.
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        // Ero → eri sisältö.
        if (a[i] != b[i]) return false;
    }
    // Samat.
    return true;
}

// Onko PTE kirjoitettava (W-bitti) — false jos polku puuttuu.
fn pteWritable(pml4: u64, virt: u64) bool {
    // Hae raaka PTE.
    const raw = paging.getPteRaw(pml4, vmm.hhdm(), virt) orelse return false;
    // Bitti 1 ratkaisee.
    return (raw & 0x2) != 0;
}

// Kirjoita testikuvio live-sivun alkuun HHDM-ikkunasta (simuloi mutaatiota/
// tuhoa jota restore korjaa; plugin ei aja tässä testissä, joten koodisivun
// vahingoittaminen on turvallista — restore palauttaa sen välittömästi).
fn damagePage(live_phys: u64, pat: u8) void {
    // Sivu CPU-osoitteeseen.
    const p: [*]u8 = @ptrFromInt(vmm.physToVirt(live_phys));
    // SMAP: salli tilapäisesti.
    user_access.stac();
    // Kuvio ensimmäiseen 64 tavuun (riittää erotteluun, säästää aikaa).
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        // Kirjoita kuviotavu.
        p[i] = pat;
    }
    // Palauta SMAP-suojaus.
    user_access.clac();
}

// Lue live-sivun ensimmäinen tavu HHDM-ikkunasta (vahinkotarkistus).
fn firstByte(live_phys: u64) u8 {
    // Sivu CPU-osoitteeseen (vain luku — ei stac-tarvetta supervisor-aliaksessa).
    const p: [*]const u8 = @ptrFromInt(vmm.physToVirt(live_phys));
    // Palauta tavu.
    return p[0];
}

// Boot-testi — walk (31.5.1, siirretty snapshot.zig:stä) + checkpoint (31.5.2).
pub fn runBootTest() void {
    // --- 31.5.1: inventaario ---
    // Lataa VSL.
    const pid = loadVsl();
    // Lataus epäonnistui (virhe jo lokitettu).
    if (pid == 0) return;
    // Hae per-process PML4 + HHDM (I2-eristys).
    const pml4 = process.getPageTable(pid) orelse {
        // Ei sivutaulua — pura ja lopeta.
        log.err("Snapshot no page table");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    };
    // Jaettu/nolla-taulu ei kelpaa.
    if (pml4 == 0) {
        // Jaettu/nolla-taulu — pura ja lopeta.
        log.err("Snapshot shared page table");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Inventaario pinossa.
    var snap = snapshot.Snapshot.init(pid, pml4);
    // Kävele user-sivut.
    const st = snapshot.walkUserPages(pml4, &snap);
    // Vähintään teksti+data+pino.
    if (st.user_pages < 3) {
        // Liian vähän sivuja.
        log.err("Snapshot too few pages");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // VSL-koodin perussivu inventaarissa.
    if (!snap.contains(VSL_BASE)) {
        // Ankkurisivu puuttuu.
        log.err("Snapshot missing VSL base");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Kernel-puolisko todella ohitettu.
    if (st.supervisor_skipped == 0) {
        // Ei ohituksia.
        log.err("Snapshot no supervisor skip");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Inventaario ehjä.
    log.info("Snapshot walk OK");

    // --- 31.5.2: checkpoint-kopio + W=0-suojaus ---
    // Negatiivi: haamu-pid ei ole plugin → ESRCH.
    const ghost = dispatch.invoke(abi.SYS_plugin_checkpoint, 0xFFFF, 0, 0, 0, 0, 0);
    // Varmista ESRCH eikä cpid.
    if (ghost != abi.ESRCH) {
        // Haamu meni läpi.
        log.err("Snapshot ghost not ESRCH");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Checkpoint VSL:stä syscallin kautta.
    const cpid_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, pid, 0, 0, 0, 0, 0);
    // Varmista positiivinen cpid.
    if (cpid_raw <= 0) {
        // Checkpoint epäonnistui.
        log.err("Snapshot checkpoint failed");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Checkpoint-id u32:na.
    const cpid: u32 = @intCast(cpid_raw);
    // Sivumäärä täsmää inventaarioon (sama kävely).
    const n = snapshot.checkpointPageCount(cpid) orelse {
        // Tuntematon cpid heti luonnin jälkeen.
        log.err("Snapshot count missing");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    };
    if (n != snap.count) {
        // Kopioitu eri määrä kuin inventoitu.
        log.err("Snapshot count mismatch");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Kopion sisältö = live-sivu (vertaa ensimmäistä 4K-lehteä tavuittain).
    // (Huge-sivuja plugineilla ei ole — checkpoint kieltäytyisi niistä.)
    var pi: usize = 0;
    var compared: usize = 0;
    while (pi < n) : (pi += 1) {
        // Kopion kehysosoite.
        const fphys = snapshot.checkpointPageFrame(cpid, pi) orelse continue;
        // Live-sivun phys inventaariosta (sama indeksi, sama kävely).
        if (pi < snap.count) {
            // Vertaa sisältö.
            if (pagesEqual(fphys, snap.pages[pi].phys)) compared += 1;
        }
    }
    // Vähintään yksi sivu varmennettu identtiseksi.
    if (compared == 0) {
        // Yksikään kopio ei täsmää liveen.
        log.err("Snapshot copy mismatch");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // W=0-suojaus: jokainen alun perin kirjoitettava sivu on nyt read-only.
    // Etsi kirjoitettava sivu inventaariosta (pino/data — teksti voi olla RX).
    var wvirt: ?u64 = null;
    var wi: usize = 0;
    while (wi < snap.count) : (wi += 1) {
        // 4K + kirjoitettava (huge ohitetaan — niitä ei checkpointattu).
        if (!snap.pages[wi].huge and snap.pages[wi].writable) {
            // Tallenna ensimmäinen.
            wvirt = snap.pages[wi].virt;
            break;
        }
    }
    // Kirjoitettava sivu löytyi (pino takaa tämän plugineilla).
    const wv = wvirt orelse {
        // Ei kirjoitettavaa sivua — suojaa ei voi todistaa.
        log.err("Snapshot no writable page");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    };
    // Varmista W-bitti nollattu PTE:ssä.
    if (pteWritable(pml4, wv)) {
        // Sivu yhä kirjoitettava — suojaus puuttuu.
        log.err("Snapshot guard missing");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // --- 31.5.3: restore-demo (damage → restore → verify, kahdesti) ---
    // Vahingoita ensimmäistä inventoitua sivua (plugin ei aja — turvallista).
    // Live-phys inventaariosta (sama kävely kuin checkpointissa).
    const dmg_phys = snap.pages[0].phys;
    // Kierros 1: kuvio A5 → restore → sisältö + W-bitit ennalleen.
    damagePage(dmg_phys, 0xA5);
    // Vahinko näkyvissä (sanity: kirjoitus osui).
    if (firstByte(dmg_phys) != 0xA5) {
        // Kirjoitus ei uponnut — testiympäristö rikki.
        log.err("Snapshot damage failed");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Restore syscallin kautta (cpid säilyy — toistettava rollback).
    if (dispatch.invoke(abi.SYS_plugin_restore, pid, 0, 0, 0, 0, 0) != 0) {
        // Restore epäonnistui.
        log.err("Snapshot restore failed");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Sisältö palautunut checkpoint-kopioon (vertaa kehystä liveen).
    const f0 = snapshot.checkpointPageFrame(cpid, 0) orelse {
        // Kehys katosi restoren aikana.
        log.err("Snapshot frame lost");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    };
    if (!pagesEqual(f0, dmg_phys)) {
        // Live ei täsmää kopiota restoren jälkeen.
        log.err("Snapshot restore mismatch");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // W-bitti palautunut ajokelpoiseksi (was_writable → true).
    if (!pteWritable(pml4, wv)) {
        // Sivu yhä suojattu restoren jälkeen — ei ajokelpoinen.
        log.err("Snapshot restore nowrite");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Kierros 2: eri kuvio (5A) → restore → toistettavuustodiste.
    damagePage(dmg_phys, 0x5A);
    // Vahinko näkyvissä.
    if (firstByte(dmg_phys) != 0x5A) {
        // Toinen kirjoitus ei uponnut.
        log.err("Snapshot redamage failed");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Restore uudelleen (sama checkpoint — ei uutta kopiota).
    if (dispatch.invoke(abi.SYS_plugin_restore, pid, 0, 0, 0, 0, 0) != 0) {
        // Toinen restore epäonnistui.
        log.err("Snapshot rerestore failed");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Sisältö jälleen kopion mukainen (sama kehys, sama live).
    if (!pagesEqual(f0, dmg_phys)) {
        // Toinen palautus ei täsmää.
        log.err("Snapshot rerestore mismatch");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Negatiivi: restore ilman checkpointia (haamu-pid) → ESRCH.
    if (dispatch.invoke(abi.SYS_plugin_restore, 0xFFFF, 0, 0, 0, 0, 0) != abi.ESRCH) {
        // Haamu-restore meni läpi.
        log.err("Snapshot ghost restore not ESRCH");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(cpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Kaksi damage/restore-kierrosta + ghost-hylkäys OK.
    log.info("Snapshot restore OK");
    // Poista checkpoint: W-bitit palautuvat + kehykset vapautuvat.
    if (!snapshot.deleteCheckpoint(cpid)) {
        // Poisto epäonnistui.
        log.err("Snapshot delete failed");
        // Siivoa lataus (checkpoint jää — laskuri paljastaa).
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Säilö tyhjä poiston jälkeen (ei vuotoja).
    if (snapshot.checkpointCount() != 0) {
        // Checkpoint jäi roikkumaan.
        log.err("Snapshot leak");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // W-bitti palautunut PTE:hen (turvallinen unload + myöhemmät suitet).
    if (!pteWritable(pml4, wv)) {
        // Suojaus jäi päälle poiston jälkeen.
        log.err("Snapshot unguard missing");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Kopio + suojaus + purku OK — pura LIFO-puhtaasti.
    const unloaded = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
    // Varmista purku.
    if (unloaded != 0) {
        // Purku epäonnistui.
        log.err("Snapshot unload failed");
        return;
    }
    // Checkpoint-kopio + W=0-suojaus + reversiibeli purku OK.
    log.info("Snapshot checkpoint OK");

    // --- 31.5.4: aito dirty-fault ring 3:ssa + inkrementaalinen checkpoint ---
    // Lataa dirty-test-ELF (kirjoittaa omaan pinoonsa → #PF odotettu).
    const dpid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.DIRTY_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (dpid_raw <= 1) {
        // Dirty-lataus epäonnistui.
        log.err("Dirty load failed");
        return;
    }
    // Dirty-pid u64:na.
    const dpid: u64 = @intCast(dpid_raw);
    // Checkpoint dirty-pluginista (täysi kopio + W=0-suojaus).
    const dcpid_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, dpid, 0, 0, 0, 0, 0);
    // Varmista positiivinen cpid.
    if (dcpid_raw <= 0) {
        // Checkpoint epäonnistui.
        log.err("Dirty checkpoint failed");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // Checkpoint-id u32:na.
    const dcpid: u32 = @intCast(dcpid_raw);
    // Ei likaisia sivuja vielä (vasta checkpointattu).
    const d0 = snapshot.checkpointDirtyCount(dcpid) orelse {
        // Laskuri puuttuu heti luonnin jälkeen.
        log.err("Dirty count missing");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    };
    if (d0 != 0) {
        // Tuore checkpoint ei ole puhdas.
        log.err("Dirty count not zero");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // #PF-laskuri ennen ajoa (todistaa laitepolun, ei suoraa kutsua).
    const faults_before = snapshot.dirtyFaultCount();
    // Aja dirty-plugin ring 3:ssa: pinokirjoitus → AITO #PF → handler
    // merkitsee likaiseksi + myöntää kirjoituksen → "dty" jatkuu.
    if (!loader.runPlugin(dpid)) {
        // Ajo epäonnistui (faulttia ei käsitelty).
        log.err("Dirty run failed");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // #PF-käsittelijä todella ajoi (laski faultin).
    if (snapshot.dirtyFaultCount() <= faults_before) {
        // Yksikään fault ei kulkenut handlerin läpi.
        log.err("Dirty fault not counted");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // Tasan yksi sivu likaantui (pinokirjoitus — yksi 4K-sivu).
    const d1 = snapshot.checkpointDirtyCount(dcpid) orelse {
        // Laskuri katosi ajon aikana.
        log.err("Dirty count lost");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    };
    if (d1 != 1) {
        // Väärä likamäärä (odota 1).
        log.err("Dirty count not one");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // Inkrementaalinen checkpoint samalla syscallilla: sama cpid takaisin,
    // likalippu nollautuu (kopioitu uudelleen + suojattu).
    const dcpid2_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, dpid, 0, 0, 0, 0, 0);
    // Varmista sama cpid (inkrementti, ei uusi checkpoint).
    if (dcpid2_raw != dcpid_raw) {
        // Uusi cpid täyden kopion sijaan — inkrementti ei toiminut.
        log.err("Dirty cpid changed");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // Likamäärä nollautunut inkrementin jälkeen.
    const d2 = snapshot.checkpointDirtyCount(dcpid) orelse {
        // Laskuri katosi inkrementissä.
        log.err("Dirty recount missing");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    };
    if (d2 != 0) {
        // Lika ei nollautunut inkrementissä.
        log.err("Dirty not cleared");
        // Siivoa checkpoint + lataus.
        _ = snapshot.deleteCheckpoint(dcpid);
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // Siivoa checkpoint + pura LIFO-puhtaasti.
    if (!snapshot.deleteCheckpoint(dcpid)) {
        // Poisto epäonnistui.
        log.err("Dirty delete failed");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    // Säilö tyhjä (ei vuotoja).
    if (snapshot.checkpointCount() != 0) {
        // Checkpoint jäi roikkumaan.
        log.err("Dirty leak");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0);
        return;
    }
    if (dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("Dirty unload failed");
        return;
    }
    // Aito ring-3-fault + dirty-merkintä + inkrementti + purku OK.
    log.info("Dirty tracking OK");
}
