//! Plugin-snapshotit — inventaario + checkpoint + W=0-suojaus (31.5.1–31.5.2).
//!
//! **Vastuu**: Listaa prosessin user-sivut (31.5.1), kopioi ne PMM-kehyksiin
//!   ja suojaa originaalit kirjoitukselta (31.5.2). Ei palauta sivuja
//!   (31.5.3), ei likaisuusseurantaa (31.5.4), ei watchdogia (31.5.5).
//! **Riippuvuudet**: `snapshot_core.zig` (puhdas matematiikka),
//!   `mm/vmm.zig` (physToVirt), `arch/x86_64/paging.zig` (PTE W-bitti +
//!   flush), `mm/pmm.zig` (kopiokehykset), `process_core` (page_table),
//!   `arch/x86_64/user_access.zig` (stac/clac kopioihin)
//! **Käytetään**: `syscall/dispatch.zig` (sys_plugin_checkpoint +
//!   unload-reclaim), `syscall/snapshot_syscall.zig` (boot-testi)
//!
//! ## Arkkitehtuurihuomiot
//! - U/S-raja, ei puoliskoraja: user-half-indeksit (0..255) + higher-half
//!   USER-lehdet (plugin-koodi 0xFFFFFFFF900xxxxx) kuuluvat; supervisor
//!   lasketaan ohitetuiksi (todistaa kernel-puoliskon poissulkemisen).
//! - Kiinteä 64 merkintää per checkpoint: plugin-ELF ≤8 segmenttiä + pino
//!   mahtuu; täysi inventaario kieltäytyy (Truncated) eikä tee osittaista.
//! - Checkpoint korvaa saman pidin vanhan (replace): yksi totuus per plugin.
//!   unload-reclaim (`deleteCheckpointsForPid`) kutsutaan dispatchin
//!   sys_plugin_unloadista — loaderiin ei kiertoa (loader → snapshot olisi
//!   sykli snapshot→loaderin boot-importtien kautta; boot-testi elää siksi
//!   `snapshot_syscall.zig`:ssä, ei täällä).
//! - W=0-suojaus on EHDOTON tässä vaiheessa: kirjoitus suojattuun sivuun
//!   faultaa (#PF lokittaa, ei käsittele). Boot-testi ei kirjoita suojattuihin
//!   sivuihin; delete palauttaa W-bitit ennen unloadia. Dirty-seuranta (31.5.4)
//!   tekee faultista myöhemmin merkityksellisen.

// Tuo puhdas kävelymatematiikka — jaettu instanssi build-moduulina
// (ei suhteellinen import: sama tiedosto kahdessa moduulissa on virhe).
const core = @import("snapshot_core");
// Tuo VMM — physToVirt HHDM-ikkunaan + hhdm-offset.
const vmm = @import("mm/vmm.zig");
// Tuo paging — PTE W-bitti + TLB-flush + CR3-reload.
const paging = @import("arch/x86_64/paging.zig");
// Tuo PMM — kopiokehysten allokaatio/vapautus + phys/frame-muunnokset.
const pmm = @import("mm/pmm.zig");
// Tuo prosessitaulukko — page_table (PML4 phys) pid:llä.
const process = @import("process_core");
// Tuo SMAP-yhteensopivuus — stac/clac HHDM-kopioihin (loader-precedentti).
const user_access = @import("arch/x86_64/user_access.zig");

// Montako lehteä snapshot-inventaarioon mahtuu (plugin: segmentit + pino).
pub const MAX_SNAP_PAGES: usize = 64;
// VSL-pluginin linkkiosoite (userland/vsl/user.ld) — inventaarion ankkuri.
const VSL_BASE: u64 = 0xFFFFFFFF90094000;

// Yksi inventoitu sivu.
pub const SnapPage = struct {
    // Virtuaalinen perusosoite (4K-aligned; hugella lohkon alku).
    virt: u64,
    // Fyysinen perusosoite.
    phys: u64,
    // Kirjoitettava lehti.
    writable: bool,
    // Huge-lohko (2M/1G) yksittäisenä merkintänä.
    huge: bool,
};

// Kävelyn tilastot — todistusaineisto boot-testille.
pub const WalkStats = struct {
    // User-lehtiä inventaarissa.
    user_pages: usize,
    // Supervisor-lehtiä ohitettu (kernel-puolisko poissuljettu).
    supervisor_skipped: usize,
    // Huge-lohkoja user-tilassa.
    huge_pages: usize,
    // Inventaario täyttyi kesken (katkaistu, ei kaatumista).
    truncated: bool,
};

// Snapshot-inventaario — kiinteä taulukko, ei allokaatiota.
pub const Snapshot = struct {
    // Kohdeprosessi.
    pid: u64,
    // Kävelty PML4 (fyysinen).
    pml4_phys: u64,
    // Montako merkintää käytössä.
    count: usize,
    // Lehtitaulukko.
    pages: [MAX_SNAP_PAGES]SnapPage,

    // Tyhjä inventaario prosessille.
    pub fn init(pid: u64, pml4_phys: u64) Snapshot {
        // Nollattu taulukko suorana paluuarvona (undefined-tavut eivät vuoda).
        return Snapshot{
            // Kohde.
            .pid = pid,
            // Lähde-PML4.
            .pml4_phys = pml4_phys,
            // Ei merkintöjä vielä.
            .count = 0,
            // Nollaa jokainen sivu.
            .pages = [_]SnapPage{.{ .virt = 0, .phys = 0, .writable = false, .huge = false }} ** MAX_SNAP_PAGES,
        };
    }

    // Lisää lehti — false jos täynnä (katkaisu, ei ylivuotoa).
    pub fn add(self: *Snapshot, virt: u64, phys: u64, writable: bool, huge: bool) bool {
        // Taulukko täynnä.
        if (self.count >= MAX_SNAP_PAGES) return false;
        // Tallenna merkintä.
        self.pages[self.count] = .{ .virt = virt, .phys = phys, .writable = writable, .huge = huge };
        // Kasvata laskuria.
        self.count += 1;
        // Onnistui.
        return true;
    }

    // Löytyykö virtuaaliosoite inventaarista (ankkuritarkistus)?
    pub fn contains(self: *const Snapshot, virt: u64) bool {
        // Käy merkinnät.
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            // Täsmäävä perusosoite.
            if (self.pages[i].virt == virt) return true;
        }
        // Ei löytynyt.
        return false;
    }
};

// Lue taulukkomerkintä fyysisestä osoitteesta HHDM-ikkunaan.
fn readEntry(table_phys: u64, idx: u64) u64 {
    // Taulukko CPU-osoitteeseen.
    const tab: [*]const u64 = @ptrFromInt(vmm.physToVirt(table_phys));
    // Palauta raaka merkintä.
    return tab[idx];
}

// Kävele PML4 ja inventoi user-lehdet — palauttaa tilastot.
// Supervisor-lehdet lasketaan ohitetuiksi (ei inventoida).
pub fn walkUserPages(pml4_phys: u64, out: *Snapshot) WalkStats {
    // Tilastot nollasta.
    var st = WalkStats{ .user_pages = 0, .supervisor_skipped = 0, .huge_pages = 0, .truncated = false };
    // PML4-taso: kaikki 512 indeksiä (molemmat puoliskot — U/S-bitti rajaa).
    var l3: u64 = 0;
    while (l3 < 512) : (l3 += 1) {
        // PML4-merkintä.
        const e3 = readEntry(pml4_phys, l3);
        // Ei present → koko alipuu puuttuu.
        if ((e3 & core.FLAG_PRESENT) == 0) continue;
        // PML4-huge ei validi x86_64:ssa — ohita rakenteena.
        if ((e3 & core.FLAG_HUGE) != 0) continue;
        // PDPT-taso.
        const pdpt = core.nextTablePhys(e3);
        var l2: u64 = 0;
        while (l2 < 512) : (l2 += 1) {
            // PDPT-merkintä.
            const e2 = readEntry(pdpt, l2);
            // Ei present → haara puuttuu.
            if ((e2 & core.FLAG_PRESENT) == 0) continue;
            // 1G huge-lehti.
            if (core.isHugeLeaf(e2)) {
                // Kirjaa vain user-lohkot.
                if (!core.isUser(e2)) {
                    // Supervisor-lohko ohitettu.
                    st.supervisor_skipped += 1;
                    continue;
                }
                // Virt-osoite lohkon alkuun.
                const v = core.canonicalize(core.composeVirt(l3, l2, 0, 0));
                // Inventoi (katkaisu merkitään).
                if (!out.add(v, core.leafPhys(e2), core.isWritable(e2), true)) st.truncated = true;
                // Tilastoi (vain mahtuneet).
                if (!st.truncated) {
                    st.user_pages += 1;
                    st.huge_pages += 1;
                }
                continue;
            }
            // PD-taso.
            const pd = core.nextTablePhys(e2);
            var l1: u64 = 0;
            while (l1 < 512) : (l1 += 1) {
                // PD-merkintä.
                const e1 = readEntry(pd, l1);
                // Ei present → haara puuttuu.
                if ((e1 & core.FLAG_PRESENT) == 0) continue;
                // 2M huge-lehti.
                if (core.isHugeLeaf(e1)) {
                    // Kirjaa vain user-lohkot.
                    if (!core.isUser(e1)) {
                        // Supervisor-lohko ohitettu.
                        st.supervisor_skipped += 1;
                        continue;
                    }
                    // Virt-osoite lohkon alkuun.
                    const v = core.canonicalize(core.composeVirt(l3, l2, l1, 0));
                    // Inventoi (katkaisu merkitään).
                    if (!out.add(v, core.leafPhys(e1), core.isWritable(e1), true)) st.truncated = true;
                    // Tilastoi (vain mahtuneet).
                    if (!st.truncated) {
                        st.user_pages += 1;
                        st.huge_pages += 1;
                    }
                    continue;
                }
                // PT-taso.
                const pt = core.nextTablePhys(e1);
                var l0: u64 = 0;
                while (l0 < 512) : (l0 += 1) {
                    // PT-merkintä (4K-lehti).
                    const e0 = readEntry(pt, l0);
                    // Ei present → sivu puuttuu.
                    if (!core.isPageLeaf(e0)) continue;
                    // Supervisor-sivu ohitetaan (kernel-puolisko).
                    if (!core.isUser(e0)) {
                        // Laske ohitus todisteeksi.
                        st.supervisor_skipped += 1;
                        continue;
                    }
                    // Virt-osoite sivun alkuun.
                    const v = core.canonicalize(core.composeVirt(l3, l2, l1, l0));
                    // Inventoi (katkaisu merkitään).
                    if (!out.add(v, core.leafPhys(e0), core.isWritable(e0), false)) st.truncated = true;
                    // Tilastoi (vain mahtuneet).
                    if (!st.truncated) st.user_pages += 1;
                }
            }
        }
    }
    // Palauta tilastot.
    return st;
}

// --- Checkpoint-orkestraatio (31.5.2) ---
//
// Taulukko elää `snapshot_ckpt_core.zig`:ssä (puhdas, host-testattava);
// tässä kehys- (PMM), kopio- ja PTE-työ. Boot-testi ja syscall-handler
// kutsuvat näitä; suorat taulukoskaivelut on kielletty (mene coren läpi).

// Tuo checkpoint-säilön ydin — jaettu instanssi build-moduulina.
const ckpt = @import("snapshot_ckpt_core");

// Checkpoint-virheet — dispatch kartoittaa errnoiksi (Truncated/HasHuge →
// EINVAL: viallinen kohde; NoMemory/TableFull → ENOMEM: resurssit loppu).
pub const CkptError = error{
    // Ei per-process PML4:ää (jaettu/nolla-taulu).
    NoPageTable,
    // Huge user-lohko (vain 4K tuettu — ei osittaista).
    HasHuge,
    // Inventaario katkesi (yli 64 lehteä — ei osittaista).
    Truncated,
    // Säilö täynnä (4 checkpointia).
    TableFull,
    // Kehysallokaatio epäonnistui (rollback tehty).
    NoMemory,
    // W-bitin asetus epäonnistui (rollback tehty).
    NoGuard,
    // Checkpoint-id tuntematon.
    NotFound,
};

// Etsi pluginin checkpoint — null jos ei ole (replace-päätös).
pub fn findCheckpointForPid(pid: u64) ?u32 {
    // Delegoi ytimeen.
    return ckpt.findForPid(pid);
}

// Montako checkpointia säilössä (boot-hygieniatarkistus).
pub fn checkpointCount() usize {
    // Delegoi ytimeen.
    return ckpt.count();
}

// Kopioidun sivun virtuaaliosoite (boot-verifiointi) — null jos rajat ulkona.
pub fn checkpointPageVirt(cpid: u32, idx: usize) ?u64 {
    // Delegoi ytimeen.
    return ckpt.pageVirt(cpid, idx);
}

// Kopioidun sivun kehysosoite (boot-verifiointi) — null jos rajat ulkona.
pub fn checkpointPageFrame(cpid: u32, idx: usize) ?u64 {
    // Delegoi ytimeen.
    return ckpt.pageFrame(cpid, idx);
}

// Kopioitujen sivujen määrä (boot-verifiointi) — null jos tuntematon cpid.
pub fn checkpointPageCount(cpid: u32) ?usize {
    // Delegoi ytimeen.
    return ckpt.pageCount(cpid);
}

// Vapauta osittainen checkpoint rollbackissa: palauta W-bitit ja kehykset.
fn rollbackPartial(cpid: u32, pml4: u64, hhdm: u64, done: usize) void {
    // Käy kopioidut sivut (done kpl täytetty).
    var j: usize = 0;
    while (j < done) : (j += 1) {
        // Metatieto säilöstä.
        const w = ckpt.pageWasWritable(cpid, j) orelse false;
        const v = ckpt.pageVirt(cpid, j) orelse continue;
        const f = ckpt.pageFrame(cpid, j) orelse continue;
        // Palauta kirjoitettavuus jos oli kirjoitettava.
        if (w) {
            // Best-effort (taulu juuri kävelty — pitäisi onnistua).
            _ = paging.setPteWritable(pml4, hhdm, v, true);
        }
        // Vapauta kopiokehys takaisin PMM:ään.
        if (pmm.physToFrame(f)) |frame| {
            // Palauta kehys.
            pmm.freeFrame(frame);
        }
    }
    // Vapauta paikka (laskuri nollautuu).
    _ = ckpt.releaseSlot(cpid);
    // Päivitä TLB koko taulun osalta (W-palautukset).
    paging.setCr3(paging.getCr3());
}

// Checkpoint pluginin user-sivut: kopioi kehykset + W=0-suojaa originaalit.
// Korvaa saman pidin vanhan checkpointin. Palauttaa cpid:n (indeksi+1).
pub fn checkpointPlugin(pid: u64) CkptError!u32 {
    // Hae per-process PML4 (I2-eristys).
    const pml4 = process.getPageTable(pid) orelse return CkptError.NoPageTable;
    // Jaettu/nolla-taulu ei kelpaa.
    if (pml4 == 0) return CkptError.NoPageTable;
    // HHDM-offset kopiointi-ikkunaan.
    const hhdm = vmm.hhdm();
    // Inventoi user-sivut pinossa (1.5 KiB — boot-pinossa tilaa).
    var snap = Snapshot.init(pid, pml4);
    const st = walkUserPages(pml4, &snap);
    // Huge-lohkot: ei 4K-kopiota → kieltäydy (ei osittaista).
    if (st.huge_pages > 0) return CkptError.HasHuge;
    // Katkennut inventaario: ei osittaista checkpointia.
    if (st.truncated) return CkptError.Truncated;
    // Korvaa vanha saman pidin checkpoint (yksi totuus per plugin).
    _ = deleteCheckpointsForPid(pid);
    // Varaa säilöpaikka (null → täynnä).
    const cpid = ckpt.allocSlot(pid, pml4) orelse return CkptError.TableFull;
    // Hae varattu paikka täyttöä varten.
    const slot = ckpt.slotByCpid(cpid) orelse return CkptError.TableFull;
    // Käy inventoidut sivut.
    var k: usize = 0;
    while (k < snap.count) : (k += 1) {
        // Kopioi vain 4K-lehdet (huge jo hylätty yllä — vyö+henkselit).
        if (snap.pages[k].huge) {
            // Siivoa osittainen + palaa virheellä.
            rollbackPartial(cpid, pml4, hhdm, k);
            return CkptError.HasHuge;
        }
        // Allokoi kopiokehys PMM:stä.
        const frame = pmm.allocFrame() orelse {
            // Kehykset loppu — siivoa osittainen.
            rollbackPartial(cpid, pml4, hhdm, k);
            return CkptError.NoMemory;
        };
        // Kehys → fyysinen osoite.
        const fphys = pmm.frameToPhys(frame);
        // Tallenna metatieto heti (rollback löytää sen).
        slot.pages[k] = .{ .virt = snap.pages[k].virt, .frame_phys = fphys, .was_writable = snap.pages[k].writable };
        slot.page_count = k + 1;
        // Kopioi 4 KiB HHDM-ikkunassa (lähde + kohde supervisor-aliaksia).
        const src: [*]const u8 = @ptrFromInt(vmm.physToVirt(snap.pages[k].phys));
        const dst: [*]u8 = @ptrFromInt(vmm.physToVirt(fphys));
        // SMAP: salli tilapäisesti (loader-precedentti user-sivuille).
        user_access.stac();
        // Kopioi koko sivu.
        @memcpy(dst[0..4096], src[0..4096]);
        // Palauta SMAP-suojaus.
        user_access.clac();
        // Suojaa originaali: W=0 (kirjoitus faultaa → 31.5.4-merkitys myöhemmin).
        if (!paging.setPteWritable(pml4, hhdm, snap.pages[k].virt, false)) {
            // PTE katosi kesken — siivoa osittainen (k sivu mukana).
            rollbackPartial(cpid, pml4, hhdm, k + 1);
            return CkptError.NoGuard;
        }
    }
    // Päivitä TLB koko taulun osalta (W-poistot).
    paging.setCr3(paging.getCr3());
    // Palauta cpid.
    return cpid;
}

// Poista yksi checkpoint: palauta W-bitit + vapauta kehykset.
pub fn deleteCheckpoint(cpid: u32) bool {
    // Hae paikka + lue kentät ennen vapautusta.
    const slot = ckpt.slotByCpid(cpid) orelse return false;
    // Kopioi tarvittavat arvot pinomuuttujiin (slot vapautetaan alla).
    const pid = slot.plugin_pid;
    const stored_pml4 = slot.pml4_phys;
    const n = slot.page_count;
    // Nykyinen PML4 (stale-tarkistus swap-varalle — 31.5.3 omistaa migraation).
    const live_pml4 = process.getPageTable(pid);
    // HHDM-offset PTE-kirjoituksiin.
    const hhdm = vmm.hhdm();
    // Käy kopioidut sivut (indeksoi accessoreilla — slot vapautetaan lopuksi).
    var j: usize = 0;
    while (j < n) : (j += 1) {
        // Lue metatieto ennen vapautusta.
        const w = ckpt.pageWasWritable(cpid, j) orelse false;
        const v = ckpt.pageVirt(cpid, j) orelse continue;
        const f = ckpt.pageFrame(cpid, j) orelse continue;
        // Palauta kirjoitettavuus vain jos PML4 on sama kuin suojatessa.
        // Stale-taulun (swapattu/vapautettu) PTE:hen ei kosketa — kehykset
        // vapautetaan silti (kopiodata on itsenäistä).
        if (w) {
            // Vertaa elävää taulua tallennettuun.
            if (live_pml4) |lp| {
                // Sama taulu → palauta W-bitti.
                if (lp == stored_pml4 and lp != 0) {
                    // Best-effort (sivu saatettu purkaa alta).
                    _ = paging.setPteWritable(lp, hhdm, v, true);
                }
            }
        }
        // Vapauta kopiokehys takaisin PMM:ään.
        if (pmm.physToFrame(f)) |frame| {
            // Palauta kehys.
            pmm.freeFrame(frame);
        }
    }
    // Vapauta paikka.
    _ = ckpt.releaseSlot(cpid);
    // Päivitä TLB (W-palautukset).
    paging.setCr3(paging.getCr3());
    // Onnistui.
    return true;
}

// Poista pidin kaikki checkpointit (unload-reclaim) — palauttaa määrän.
pub fn deleteCheckpointsForPid(pid: u64) u32 {
    // Poistettujen laskuri.
    var n: u32 = 0;
    // Etsi toistuvasti (delete muuttaa taulukkoa — hae aina uudelleen).
    while (findCheckpointForPid(pid)) |cpid| {
        // Poista löydetty.
        if (deleteCheckpoint(cpid)) n += 1 else break;
    }
    // Palauta poistettujen määrä.
    return n;
}

