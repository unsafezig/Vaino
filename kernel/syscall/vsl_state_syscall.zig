//! VSL-3 boot-testi — tilakuvaus + swap-jatkuvuus + vsl-shell-kooste (Vaihe 41).
//!
//! **Vastuu**: Todista että 31.5-mekanismeilla on konkreettinen kohde:
//!   41.1 `VslState`-kuvaus täytetään checkpoint-inventaariosta (sivut +
//!   dirty-liput + cap-viitteet), 41.2 jaettu portti selviää VSL-sw apista,
//!   41.3 TDL-tehtävä "vsl-shell" sävelletään/ajetaan/puretaan composerilla.
//! **Riippuvuudet**: `dispatch.zig` (load/unload/checkpoint),
//!   `../snapshot.zig` (inventaario + dirty-luku), `vsl_state` (formaatti),
//!   `../plugin/loader.zig` + `../plugin/scope.zig`,
//!   `../ipc/capability_core.zig` + `../ipc/port.zig`,
//!   `../plugin_swap.zig`, `../composer.zig`, `composer_task`/`composer_resolve`,
//!   `process_core`, log
//! **Käytetään**: `kernel/boot_tests.zig` (watchdog-testin jälkeen, puhdas taulu)
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Kuvaus ei ole restore-lupaus: capability-slotteja/rekistereitä ei
//!   kaapata 31.5.2:ssa, joten niitä ei täytetä eikä palauteta (regs nollia,
//!   caps vain viitteitä). Sivu-rollback on copy-back (31.5.3), omistetut
//!   capit kuolevat swapissa (33-kaava) — rajat dokumentoitu, ei vaiettu.
//! - Dirty-liput todistetaan molemmin puolin: VSL-kuvaus täysin puhdas,
//!   dirty_test-kuvauksessa tasan yksi likainen sivu pinon huipulla (aito
//!   ring-3-#PF, ei arvailu).
//! - Swap lataa saman binäärin tuoreena (yleistetty `elfForId`-kaava):
//!   entry täsmää ennen/jälkeen — vaihto ei vaihda ohjelmaa.
//! - vsl-shell kulkee koko composer-portin läpi (manifesti+scope per plugin);
//!   binääriohjaus vaihtaa vain ELF-kuvan, ei tarpeita (ei laajennusta).

// Tuo jaettu ABI — plugin/checkpoint-syscallit + virheet.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3:a.
const dispatch = @import("dispatch.zig");
// Tuo snapshot — checkpoint + inventaarioluku + dirty-liput.
const snapshot = @import("../snapshot.zig");
// Tuo tilakuvausformaatti (build-moduuli — sama kaava kuin plugin_manifest).
const vstate = @import("vsl_state");
// Tuo plugin-loader — embed-id:t + load/run/unload + rekisteri.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit manifesti+scope-vektoreihin.
const scope = @import("../plugin/scope.zig");
// Tuo capability-ydin — jaetun portin objekti + slotit + maskit.
const cap = @import("../ipc/capability_core.zig");
// Tuo portit — createPort + MAX_MSG_SIZE.
const port = @import("../ipc/port.zig");
// Tuo swap-orkestraattori — VSL-paikallaanvaihto (41.2).
const swap = @import("../plugin_swap.zig");
// Tuo composer — vsl-shell-kooste (41.3).
const composer = @import("../composer.zig");
// Tuo TDL-ydin + heuristiikka (build-moduulit — offline-tarkistukset).
const task = @import("composer_task");
const resolve = @import("composer_resolve");
// Tuo purkupolitiikan MAX-katto req-puskuriin.
const decomposer = @import("../decomposer.zig");
// Tuo prosessitaulukko — entry/pino-ankkurit + BOOT_PID.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// VSL-pluginin linkkiosoite (userland/vsl/user.ld) — entry-ankkuri.
const VSL_BASE: u64 = 0xFFFFFFFF90094000;

// Lataa VSL täydellä valvontapolulla — palauttaa pid tai 0 (virhe jo lokitettu).
fn loadVsl() u64 {
    // Port/send-manifesti, VSL-scope (portti+muisti, ei grant).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.VSL_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("VSL state load failed");
        // Nolla = ei pid:iä.
        return 0;
    }
    // Palauta pid.
    return @intCast(pid_raw);
}

// Checkpoint pluginista — palauttaa cpid tai 0 (virhe jo lokitettu).
fn checkpointPid(pid: u64) u32 {
    // Täysi kopio + W=0-suojaus syscall-polulla.
    const cpid_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, pid, 0, 0, 0, 0, 0);
    // Varmista positiivinen cpid.
    if (cpid_raw <= 0) {
        // Checkpoint epäonnistui.
        log.err("VSL state checkpoint failed");
        // Nolla = ei cpid:tä.
        return 0;
    }
    // Palauta cpid.
    return @intCast(cpid_raw);
}

// Siivoa plugin + checkpoint (unload-reclaim hoitaa checkpointin).
fn cleanupPlugin(pid: u64) void {
    // Nykyinen pid bootiksi (ajo jättää plugin-kontekstin).
    _ = process.setCurrentPid(process.BOOT_PID);
    // Pura plugin (checkpoint-reclaim mukana).
    _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
}

// Täytä VslState checkpoint-inventaariosta + cap-sloteista + trap-regseistä.
// Jaettu apu trap-testille (yksi lähde kuvaukselle) — boot-testi kutsuu.
pub fn describeCheckpoint(pid: u64, cpid: u32, out: *vstate.VslState) bool {
    // Sivumäärä inventaariosta.
    const n = snapshot.checkpointPageCount(cpid) orelse {
        // Tuntematon cpid.
        log.err("VSL state page count missing");
        return false;
    };
    // Tyhjä inventaario ei kelpaa (pluginilla on aina koodi+pino).
    if (n == 0) {
        // Ei sivuja — täyttö tyhjästä valehtelisi.
        log.err("VSL state no pages");
        return false;
    }
    // Kapasiteetti riittää aina (64 == MAX_SNAP_PAGES — ei katkaisua).
    if (n > vstate.MAX_STATE_PAGES) {
        // Inventaario ei mahdu kuvaukseen.
        log.err("VSL state pages overflow");
        return false;
    }
    // Käy inventoidut sivut.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Virtuaaliosoite säilöstä.
        const v = snapshot.checkpointPageVirt(cpid, i) orelse {
            // Aukko inventaariossa.
            log.err("VSL state page virt missing");
            return false;
        };
        // Dirty-lippu 31.5.4-merkinnästä (luku, ei kirjoitus).
        const d = snapshot.checkpointPageDirty(cpid, i) orelse {
            // Lippua ei löydy.
            log.err("VSL state page dirty missing");
            return false;
        };
        // Tallenna viite (virhe vain kapasiteetista — rajattu yllä).
        out.addPage(v, d) catch {
            // Ei pitäisi tapahtua (n rajattu).
            log.err("VSL state page add failed");
            return false;
        };
    }
    // Käy pidin cap-slotit.
    const total = cap.slotCountForPid(pid);
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        // Lue slotti.
        const ref = cap.lookupSlotForPid(pid, slot) orelse continue;
        // Tyhjä — ohita.
        if (ref.object_id == 0) continue;
        // Taustaobjekti — pitää olla olemassa.
        const obj = cap.getObject(ref.object_id) orelse continue;
        // Kernel-tyyppi → ABI-numero (Phase-29-kaava: .memory → bitti 5).
        const abi_type: u32 = switch (obj.typ) {
            .port => vstate.ABI_TYPE_PORT,
            .memory => vstate.ABI_TYPE_MEMORY,
            else => continue,
        };
        // Oikeudet maskiksi.
        const mask = cap.rightsToMask(ref.rights);
        // Tallenna viite.
        out.addCap(slot, abi_type, mask) catch {
            // Kapasiteetti (8) tai rakenne petti.
            log.err("VSL state cap add failed");
            return false;
        };
    }
    // Trap-kehyskuva regseihin jos validi (VSL-4B: ensimmäinen täyttö;
    // ei-trapatulla pidillä nollat säilyvät — rehellinen raja).
    if (process.trapRegsValid(pid)) {
        // Kopioi kuva (pitäisi onnistua validina — muuten virhe).
        if (!process.trapRegs(pid, &out.regs)) {
            // Kuva katosi kesken täytön.
            log.err("VSL state regs missing");
            return false;
        }
    }
    // Täyttö valmis.
    return true;
}

// Etsi slotti pidin taulukosta taustaobjektin perusteella — null jos ei löydy.
fn findSlotByObject(pid: u64, object_id: u32) ?u32 {
    // Käy pidin slotit.
    const total = cap.slotCountForPid(pid);
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        const ref = cap.lookupSlotForPid(pid, slot) orelse continue;
        if (ref.object_id == object_id) return slot;
    }
    return null;
}

// Boot-testi — 41.1 describe (puhdas + likainen) → 41.2 swap → 41.3 compose.
pub fn runBootTest() void {
    // --- 41.1a: VSL-kuvaus, puhdas tapaus ---
    // Lataa VSL.
    const pid = loadVsl();
    // Lataus epäonnistui (virhe jo lokitettu).
    if (pid == 0) return;
    // Checkpoint ennen ajoa (terve tila talteen).
    const cpid = checkpointPid(pid);
    // Checkpoint epäonnistui.
    if (cpid == 0) {
        // Siivoa lataus.
        cleanupPlugin(pid);
        return;
    }
    // Asenna VSL-pidiin port-cap kuvausta varten: sys_plugin_load validoi
    // manifestin mutta ei asenna slotteja, joten tyhjä pid kuvautuisi
    // cap-osalta tyhjäksi. Eksplisiittinen asennus todistaa samalla
    // round-tripin (slotti + ABI-tyyppi + maski palaavat kuvauksesta).
    const desc_port = port.createPort() orelse {
        // Portti ei auennut.
        log.err("VSL state port failed");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    };
    const desc_obj = cap.createObject(.port, process.BOOT_PID, desc_port) orelse {
        // Objekti ei syntynyt.
        log.err("VSL state object failed");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    };
    const desc_slot = cap.installSlotForPid(pid, desc_obj, .{ .send = true }) orelse {
        // Slotti ei asentunut.
        log.err("VSL state slot failed");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    };
    // Täytä kuvaus inventaariosta.
    var st = vstate.VslState.init();
    if (!describeCheckpoint(pid, cpid, &st)) {
        // Täyttö epäonnistui.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Formaatin versio leimattu.
    if (st.version != vstate.VSL_STATE_VERSION) {
        // Versio väärä.
        log.err("VSL state bad version");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Yksi cap-viite (asentamamme port-cap): oikea slotti, portti, SEND.
    if (st.caps_len != 1) {
        // Väärä cap-määrä (odota 1).
        log.err("VSL state cap count wrong");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    if (st.caps[0].slot != desc_slot) {
        // Väärä slottinumero (odota asennettua).
        log.err("VSL state cap slot wrong");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    if (st.caps[0].abi_type != vstate.ABI_TYPE_PORT) {
        // Väärä cap-tyyppi (odota portti).
        log.err("VSL state cap type wrong");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    if (st.caps[0].rights_mask != scope.MASK_SEND) {
        // Oikeudet eivät täsmää manifestiin (SEND).
        log.err("VSL state cap rights wrong");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Sivuja löytyi (koodi + pino).
    if (st.pages_len == 0) {
        // Tyhjä sivuosa.
        log.err("VSL state pages empty");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Entry-sivu ankkuroitu (VSL linkkiosoite inventaarissa).
    const info = process.getLoadedInfo(pid) orelse {
        // Lataustieto katosi.
        log.err("VSL state no loaded info");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    };
    if (!st.containsPage(info.entry & ~@as(u64, 0xFFF))) {
        // Entry puuttuu kuvauksesta.
        log.err("VSL state entry missing");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // VSL ei kirjoittanut (ei ajoa vielä) — täysin puhdas.
    if (st.dirtyCount() != 0) {
        // Likaa puhtaassa checkpointissa.
        log.err("VSL state unexpectedly dirty");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    const sc0 = snapshot.checkpointDirtyCount(cpid) orelse {
        // Laskuri katosi.
        log.err("VSL state dirty count missing");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    };
    if (sc0 != 0) {
        // Snapshot eri mieltä kuvauksen kanssa.
        log.err("VSL state dirty mismatch");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Rekisterit nollia (rehellinen raja: ei kaappausta 31.5.2:ssa).
    if (st.regs[0] != 0 or st.regs[15] != 0) {
        // Rekisteritäyttöä ilman kaappausta — ei sallita.
        log.err("VSL state regs not zero");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Poista checkpoint (swap alle — stale-esto).
    if (!snapshot.deleteCheckpoint(cpid)) {
        // Poisto epäonnistui.
        log.err("VSL state delete failed");
        cleanupPlugin(pid);
        return;
    }

    // --- 41.1b: dirty_test-kuvaus, likainen tapaus (aito ring-3-#PF) ---
    // Lataa dirty-test-ELF (kirjoittaa pinoonsa ajossa).
    const dpid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.DIRTY_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (dpid_raw <= 1) {
        // Dirty-lataus epäonnistui.
        log.err("VSL dirty load failed");
        cleanupPlugin(pid);
        return;
    }
    // Dirty-pid u64:na.
    const dpid: u64 = @intCast(dpid_raw);
    // Checkpoint dirty-pluginista.
    const dcpid = checkpointPid(dpid);
    // Checkpoint epäonnistui.
    if (dcpid == 0) {
        // Siivoa molemmat.
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    // Aja dirty ring 3:ssa: pinokirjoitus → #PF → dirty-merkintä → "dty".
    if (!loader.runPlugin(dpid)) {
        // Ajo epäonnistui.
        log.err("VSL dirty run failed");
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    // Nykyinen pid takaisin bootiksi.
    _ = process.setCurrentPid(process.BOOT_PID);
    // Tasan yksi likainen sivu snapshotissa.
    const dd = snapshot.checkpointDirtyCount(dcpid) orelse {
        // Laskuri katosi.
        log.err("VSL dirty count missing");
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    };
    if (dd != 1) {
        // Väärä likamäärä (odota 1).
        log.err("VSL dirty count not one");
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    // Täytä kuvaus likaisesta checkpointista.
    var dst = vstate.VslState.init();
    if (!describeCheckpoint(dpid, dcpid, &dst)) {
        // Täyttö epäonnistui.
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    // Kuvaus kantaa tasan yhtä likaista sivua (31.5.4-lipun luku).
    if (dst.dirtyCount() != 1) {
        // Kuvaus ei kanna likaa (odota 1).
        log.err("VSL dirty state not one");
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    // Likainen sivu on pinon huippu (RSP-8-kirjoitus samalla sivulla).
    const dinfo = process.getLoadedInfo(dpid) orelse {
        // Lataustieto katosi.
        log.err("VSL dirty no loaded info");
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    };
    const stack_base = (dinfo.stack_top - 8) & ~@as(u64, 0xFFF);
    // Etsi likainen viite.
    var found_dirty = false;
    var di: usize = 0;
    while (di < dst.pages_len) : (di += 1) {
        // Vain likainen kiinnostaa.
        if (!dst.pages[di].dirty) continue;
        // Pitää olla pinon sivu.
        if (dst.pages[di].virt != stack_base) {
            // Lika väärällä sivulla.
            log.err("VSL dirty wrong page");
            _ = snapshot.deleteCheckpoint(dcpid);
            cleanupPlugin(dpid);
            cleanupPlugin(pid);
            return;
        }
        // Toinen likainen — laskenta valehtelisi.
        if (found_dirty) {
            // Kaksi likaista viitettä.
            log.err("VSL dirty duplicated");
            _ = snapshot.deleteCheckpoint(dcpid);
            cleanupPlugin(dpid);
            cleanupPlugin(pid);
            return;
        }
        found_dirty = true;
    }
    if (!found_dirty) {
        // Likaista viitettä ei löytynyt.
        log.err("VSL dirty ref missing");
        _ = snapshot.deleteCheckpoint(dcpid);
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    // Siivoa dirty-instanssi (checkpoint + LIFO-purku, ei vuotoja).
    if (!snapshot.deleteCheckpoint(dcpid)) {
        // Poisto epäonnistui.
        log.err("VSL dirty delete failed");
        cleanupPlugin(dpid);
        cleanupPlugin(pid);
        return;
    }
    if (dispatch.invoke(abi.SYS_plugin_unload, dpid, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("VSL dirty unload failed");
        cleanupPlugin(pid);
        return;
    }
    // Tilakuvaus molemmin puolin OK (puhdas VSL + likainen dirty).
    log.info("VSL state OK");

    // --- 41.2: jaettu portti selviää VSL-swapista ---
    // Entry talteen (saman binäärin todiste: sama entry swapin jälkeen).
    const entry_before = info.entry;
    // Jaettu jatkuvuusportti (omistaja BOOT → selviää teardownista).
    const shared_port = port.createPort() orelse {
        // Portti ei auennut.
        log.err("VSL swap port failed");
        cleanupPlugin(pid);
        return;
    };
    const shared_obj = cap.createObject(.port, process.BOOT_PID, shared_port) orelse {
        // Objekti ei syntynyt.
        log.err("VSL swap object failed");
        cleanupPlugin(pid);
        return;
    };
    // BOOT:in lähetysslotti (read+send).
    const boot_slot = cap.installSlotForPid(process.BOOT_PID, shared_obj, .{ .read = true, .send = true }) orelse {
        // BOOT-slotti ei asentunut.
        log.err("VSL swap boot slot failed");
        cleanupPlugin(pid);
        return;
    };
    // VSL:in vastaanottoslotti (read+recv — VSL-scopen osajoukko).
    if (cap.installSlotForPid(pid, shared_obj, .{ .read = true, .recv = true }) == null) {
        // Plugin-slotti ei asentunut.
        log.err("VSL swap plugin slot failed");
        cleanupPlugin(pid);
        return;
    }
    // Vaihda VSL tuoreeseen instanssiin samassa pidissä.
    if (swap.swapPlugin(pid, loader.VSL_EMBEDDED_ID) != .ok) {
        // Swap epäonnistui.
        log.err("VSL swap failed");
        cleanupPlugin(pid);
        return;
    }
    // Sama binääri (entry ennallaan — vaihto ei vaihda ohjelmaa).
    const info_after = process.getLoadedInfo(pid) orelse {
        // Lataustieto katosi swapissa.
        log.err("VSL swap no loaded info");
        cleanupPlugin(pid);
        return;
    };
    if (info_after.entry != entry_before) {
        // Entry vaihtui — väärä kuva ladattu.
        log.err("VSL swap entry changed");
        cleanupPlugin(pid);
        return;
    }
    // Jaettu slotti sillattu scope-portin läpi (täysi jatkuvuus).
    const healed_slot = findSlotByObject(pid, shared_obj) orelse {
        // Jaettu slotti katosi swapissa.
        log.err("VSL swap shared slot lost");
        cleanupPlugin(pid);
        return;
    };
    // BOOT lähettää, uusi instanssi vastaanottaa.
    const cont_msg = "VS1";
    const sent = dispatch.invoke(abi.SYS_ipc_send, @intCast(boot_slot), @intFromPtr(cont_msg), cont_msg.len, 0, 0, 0);
    if (sent != cont_msg.len) {
        // Lähetys epäonnistui.
        log.err("VSL swap send failed");
        cleanupPlugin(pid);
        return;
    }
    if (!process.setCurrentPid(pid)) {
        // Kontekstinvaihto epäonnistui.
        log.err("VSL swap switch failed");
        cleanupPlugin(pid);
        return;
    }
    var cont_buf: [port.MAX_MSG_SIZE]u8 = undefined;
    const got = dispatch.invoke(abi.SYS_ipc_recv, healed_slot, @intFromPtr(&cont_buf), cont_buf.len, 0, 0, 0);
    _ = process.setCurrentPid(process.BOOT_PID);
    if (got != cont_msg.len) {
        // Vastaanotto epäonnistui.
        log.err("VSL swap recv failed");
        cleanupPlugin(pid);
        return;
    }
    // Tavut täsmäävät.
    var ci: usize = 0;
    while (ci < cont_msg.len) : (ci += 1) {
        if (cont_buf[ci] != cont_msg[ci]) {
            // Hyötykuorma väärin.
            log.err("VSL swap payload mismatch");
            cleanupPlugin(pid);
            return;
        }
    }
    // Uusi instanssi ajaa ring 3:ssa ("vsl" — oikea kuva, oikea pino).
    if (!loader.runPlugin(pid)) {
        // Ajo epäonnistui.
        log.err("VSL swap run failed");
        cleanupPlugin(pid);
        return;
    }
    // Nykyinen pid takaisin bootiksi.
    _ = process.setCurrentPid(process.BOOT_PID);
    // Pura VSL + vapauta kuvauksen ja jaetun portin objektit (BOOT-slotit
    // siivotaan boundaryssa; virhepoluilla sama wipe — tämä suite on
    // viimeinen, joten vuoto ei etenisi seuraaviin).
    if (dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("VSL swap unload failed");
        return;
    }
    _ = cap.revokeObject(desc_obj);
    _ = cap.revokeObject(shared_obj);
    // Swap-jatkuvuus OK.
    log.info("VSL swap continuity OK");

    // --- 41.3: TDL "vsl-shell" → compose → run → decompose ---
    // Demo-tehtävä (kiinteä merkkijono — log.info ottaa vain comptime-str).
    const demo =
        "task \"vsl-shell\" { need port:send+recv; need memory:map+read; timeout 1000; plugins 4; }";
    // Laske demo binäärimuotoon.
    const spec = task.parse(demo) catch {
        // Jäsennys epäonnistui.
        log.err("VSL compose parse failed");
        return;
    };
    // Negatiivi 1: tuntematon binääri ohjauksessa → fail_resolve, nolla ladattu.
    const bad_ids = [_]u64{ loader.VSL_EMBEDDED_ID, 99 };
    if (composer.composeTaskWithIds(spec, &bad_ids) != .fail_resolve) {
        // Tuntematon id meni läpi.
        log.err("VSL compose bad id accepted");
        return;
    }
    if (composer.isComposing() or composer.compositionCount() != 0) {
        // Osittainen koostumus vuoti.
        log.err("VSL compose leaked on reject");
        _ = composer.decomposeTask();
        return;
    }
    // Negatiivi 2: pituus ristiriidassa (1 id, 2 tarvetta) → fail_resolve.
    const short_ids = [_]u64{loader.VSL_EMBEDDED_ID};
    if (composer.composeTaskWithIds(spec, &short_ids) != .fail_resolve) {
        // Lyhyt taulukko meni läpi.
        log.err("VSL compose short ids accepted");
        return;
    }
    if (composer.isComposing() or composer.compositionCount() != 0) {
        // Osittainen koostumus vuoti.
        log.err("VSL compose leaked on short");
        _ = composer.decomposeTask();
        return;
    }
    // Ei laajennusta: heuristiikan vaatimukset kaventavat tarpeita
    // (offline-tarkistus ennen binääriohjausta — ohjaus ei koske näitä).
    var check_buf: [decomposer.MAX_COMPOSITION_PLUGINS]resolve.PluginReq = undefined;
    const rn = resolve.resolve(spec, &check_buf) catch {
        // Ratkaisu epäonnistui kelvollisella specillä.
        log.err("VSL compose resolve failed");
        return;
    };
    var ri: usize = 0;
    while (ri < rn) : (ri += 1) {
        if (!resolve.reqNarrowsNeed(spec.needs[ri], check_buf[ri])) {
            // Heuristiikka levenisi.
            log.err("VSL compose broadened");
            return;
        }
    }
    // Positiivi: sävellä vsl-shell kahdeksi VSL-instanssiksi.
    const vsl_ids = [_]u64{ loader.VSL_EMBEDDED_ID, loader.VSL_EMBEDDED_ID };
    if (composer.composeTaskWithIds(spec, &vsl_ids) != .ok) {
        // Kooste epäonnistui.
        log.err("VSL compose failed");
        return;
    }
    // Kaksi pluginia (1:1-minimaalisuus).
    if (composer.compositionCount() != 2) {
        // Väärä määrä (odota 2).
        log.err("VSL compose count wrong");
        _ = composer.decomposeTask();
        return;
    }
    // Molemmat rekisterissä.
    var vpi: usize = 0;
    var vpids: [2]u64 = undefined;
    const copied = composer.copyPids(&vpids);
    if (copied != 2) {
        // Kopiointi epäonnistui.
        log.err("VSL compose pids wrong");
        _ = composer.decomposeTask();
        return;
    }
    while (vpi < copied) : (vpi += 1) {
        if (!loader.isPlugin(vpids[vpi])) {
            // Rekisteröinti puuttuu.
            log.err("VSL compose not registered");
            _ = composer.decomposeTask();
            return;
        }
    }
    // Kooste valmis.
    log.info("Task compose vsl-shell OK");
    // Aja molemmat ring 3:ssa (tulostaa "vsl" per plugin serialiin).
    if (!composer.runComposition()) {
        // Ajo epäonnistui.
        log.err("VSL compose run failed");
        _ = composer.decomposeTask();
        return;
    }
    // Pura LIFO:ssa (nolla pluginia jää — C5).
    if (!composer.decomposeTask()) {
        // Purku epäonnistui.
        log.err("VSL compose decompose failed");
        return;
    }
    // VSL-shell-kooste + purku OK.
    log.info("VSL compose OK");
}
