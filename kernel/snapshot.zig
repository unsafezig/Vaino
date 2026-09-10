//! Plugin-snapshotin kävely — user-sivujen enumerointi PML4:stä (31.5.1).
//!
//! **Vastuu**: Listaa prosessin user-liputet lehdet (virt→phys) kiinteään
//!   taulukkoon. Ei kopioi sivuja, ei suojaa, ei palauta — pelkkä inventaario
//!   tuleville checkpoint/restore-syscalleille (31.5.2+).
//! **Riippuvuudet**: `snapshot_core.zig` (puhdas matematiikka),
//!   `mm/vmm.zig` (physToVirt), boot-testissä `syscall/dispatch.zig` +
//!   `plugin/loader.zig` + `plugin/scope.zig` + `zinuxabi` + log
//! **Käytetään**: `kernel/boot_tests.zig` (VSL-fs-testin jälkeen)
//!
//! ## Arkkitehtuurihuomiot
//! - U/S-raja, ei puoliskoraja: user-half-indeksit (0..255) + higher-half
//!   USER-lehdet (plugin-koodi 0xFFFFFFFF900xxxxx) kuuluvat; supervisor
//!   lasketaan ohitetuiksi (todistaa kernel-puoliskon poissulkemisen).
//! - Kiinteä 64 merkintää: plugin-ELF ≤8 segmenttiä + pino mahtuu, ylivuoto
//!   katkaisee (truncated-lippu) eikä kaada boot-testiä — raja dokumentoitu.

// Tuo puhdas kävelymatematiikka — indeksit + lehtidekoodaus.
const core = @import("snapshot_core.zig");
// Tuo VMM — physToVirt HHDM-ikkunaan.
const vmm = @import("mm/vmm.zig");
// Tuo dispatch — sys_plugin_load/unload invoke (täysi valvontapolku).
const dispatch = @import("syscall/dispatch.zig");
// Tuo loader — VSL_EMBEDDED_ID + isPlugin/run-tarkistukset.
const loader = @import("plugin/loader.zig");
// Tuo scope-maskit manifesti+scope-vektoriin (sama kuin vsl_syscall).
const scope = @import("plugin/scope.zig");
// Tuo jaettu ABI — sys_plugin_load/unload-numerot.
const abi = @import("zinuxabi");
// Tuo prosessitaulukko — page_table (PML4 phys) pid:llä.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("lib/log.zig");

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

// Boot-testi — lataa VSL, kävele sen PML4, todenna inventaario, pura.
pub fn runBootTest() void {
    // Lataa VSL täydellä valvontapolulla (sama vektori kuin vsl_syscall).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.VSL_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("Snapshot load failed");
        // Lopeta testi.
        return;
    }
    // VSL-pid u64:na.
    const pid: u64 = @intCast(pid_raw);
    // Hae per-process PML4 (Vaihe 25 eristys).
    const pml4 = process.getPageTable(pid) orelse {
        // Ei sivutaulua — pura ja lopeta.
        log.err("Snapshot no page table");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    };
    // Eristysinvariantti I2: oma taulu, ei kernelin jakama nolla.
    if (pml4 == 0) {
        // Jaettu/nolla-taulu — pura ja lopeta.
        log.err("Snapshot shared page table");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Inventaario pinossa (64×24B ≈ 1.5 KiB — early-pinossa tilaa).
    var snap = Snapshot.init(pid, pml4);
    // Kävele user-sivut.
    const st = walkUserPages(pml4, &snap);
    // Vähintään teksti+data+pino (VSL-ELF + pinokartoitus).
    if (st.user_pages < 3) {
        // Liian vähän sivuja — lataaja ei kartoittanut odotetusti.
        log.err("Snapshot too few pages");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // VSL-koodin perussivu inventaarissa (ankkuri userland/vsl/user.ld).
    if (!snap.contains(VSL_BASE)) {
        // Ankkurisivu puuttuu — kävely ei nähnyt plugin-koodia.
        log.err("Snapshot missing VSL base");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Kernel-puolisko todella ohitettu (supervisor-lehtiä olemassa).
    if (st.supervisor_skipped == 0) {
        // Ei ohituksia — joko kävely rikki tai kernel puuttuu (ei pitäisi).
        log.err("Snapshot no supervisor skip");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Inventaario ehjä — pura LIFO-puhtaasti.
    const unloaded = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
    // Varmista purku.
    if (unloaded != 0) {
        // Purku epäonnistui — taulu likainen.
        log.err("Snapshot unload failed");
        return;
    }
    // Kävely + ankkuri + rajaus OK (31.5.1 perusta checkpointille).
    log.info("Snapshot walk OK");
}
