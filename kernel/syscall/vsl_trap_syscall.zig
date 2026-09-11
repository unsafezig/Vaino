//! VSL trap boot-testi — Linux-persoonallisuus + hello-ELF ring-3:ssa (VSL-4B).
//!
//! **Vastuu**: Todista trap-and-emulate päästä päähän: ghost/EPERM/EINVAL-
//!   negatiivit → Linux-hello-ELF (id 5, ei shimmiä) trap-tilassa →
//!   serial-merkit (`hello linux`, `vsl-uname: VSL 0.1`, `vsl-enosys OK`) →
//!   trap-regs-kuva Linux-numeroin (exit-kehys) → describe-polun regs-täyttö →
//!   disable + LIFO-purku. Itse-contained: ei residenttejä.
//! **Riippuvuudet**: `dispatch.zig` (invoke/trap), `linux_trap_core.zig`
//!   (REG-indeksit), `vsl_state_syscall.zig` (describe-uudelleenkäyttö),
//!   `vsl_state` (formaatti), `../snapshot.zig` (checkpoint),
//!   `../plugin/loader.zig`, `process_core`, `zinuxabi`, log
//! **Käytetään**: `kernel/boot_tests.zig` (vsl_file-testin jälkeen)
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Demo on muokkaamaton Linux-ABI-binääri (generaattori-työkalu, ei
//!   Zinux-shimmiä): todiste on sarjassa, ei linkityksessä. Kernel ei
//!   opettele Linuxia — trap kääntää vain RAX:n, argumentit kulkevat.
//! - Tuntematon Linux-numero palaa -ENOSYS:nä user-tilaan (demo valitsee
//!   rivin cmov:lla) — ei haltia, ei hiljaista läpimenoa.
//! - Persoonallisuus tyhjenee freePid:ssä (stale-trap esto, host-testattu);
//!   unload-reitti kattaa sen — boot todistaa disable-polun erikseen.

// Tuo jaettu ABI — trap-syscall + plugin-load + virheet.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3:a.
const dispatch = @import("dispatch.zig");
// Tuo trap-ydin — REG-indeksit kehysväitteisiin (sama hakemisto).
const trap_core = @import("linux_trap_core.zig");
// Tuo tilakuvaus-täyttö (jaettu apu state-testistä — yksi lähde).
const statedesc = @import("vsl_state_syscall.zig");
// Tuo tilaformaatti (build-moduuli).
const vstate = @import("vsl_state");
// Tuo snapshot — checkpoint regs-describen alle.
const snapshot = @import("../snapshot.zig");
// Tuo plugin-loader — embed-id:t + load/run/unload.
const loader = @import("../plugin/loader.zig");
// Tuo capability-ydin — kuvauksen port-cap (BOOT-omisteinen).
const cap = @import("../ipc/capability_core.zig");
// Tuo portit — createPort kuvauksen capille.
const port = @import("../ipc/port.zig");
// Tuo scope-maskit latausvektoriin (port-manifesti, ei grantia).
const scope = @import("../plugin/scope.zig");
// Tuo prosessitaulukko — trap-lippu/kuva + BOOT-konteksti.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Linux-hello-linkkiosoite (generaattori-työkalu) — koodisivun ankkuri.
const LINUX_BASE: u64 = 0x400000;
// Suorituksen alku (base + generaattorin CODE_OFF=120 — headeria ei ajeta).
const LINUX_ENTRY: u64 = 0x400078;

// Siivoa plugin BOOT-kontekstissa (unload-reclaim hoitaa checkpointin).
fn cleanupPlugin(pid: u64) void {
    // Nykyinen pid bootiksi.
    _ = process.setCurrentPid(process.BOOT_PID);
    // Pura plugin.
    _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
}

// Boot-testi — trap-negatiivit → hello-ajo → regs → describe → disable → purku.
pub fn runBootTest() void {
    // --- Negatiivi 1: haamu-pid → ESRCH (ei mitään asetettavaa). ---
    if (dispatch.invoke(abi.SYS_plugin_trap, 9999, 1, 0, 0, 0, 0) != abi.ESRCH) {
        // Haamu meni läpi.
        log.err("VSL trap ghost not ESRCH");
        return;
    }
    // --- Lataa Linux-hello (port-manifesti, demo ei käytä cappeja). ---
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.LINUX_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("VSL trap load failed");
        return;
    }
    // Demo-pid u64:na.
    const pid: u64 = @intCast(pid_raw);
    // Entry ankkuroitu generaattorin osoitteeseen (oikea kuva ladattu).
    const linfo = process.getLoadedInfo(pid) orelse {
        // Lataustieto puuttuu.
        log.err("VSL trap no loaded info");
        cleanupPlugin(pid);
        return;
    };
    if (linfo.entry != LINUX_ENTRY) {
        // Väärä entry (odota 0x400078 — generaattorin koodin alku).
        log.err("VSL trap entry wrong");
        cleanupPlugin(pid);
        return;
    }
    // --- Negatiivi 2: arvo!=0/1 → EINVAL (ei hiljaista totuusarvoa). ---
    if (dispatch.invoke(abi.SYS_plugin_trap, pid, 2, 0, 0, 0, 0) != abi.EINVAL) {
        // Laiton arvo meni läpi.
        log.err("VSL trap value not EINVAL");
        cleanupPlugin(pid);
        return;
    }
    // Oletus Zinux-tila (lataus ei trapaa).
    if (process.isLinuxTrapped(pid)) {
        // Lippu päällä ilman enablea.
        log.err("VSL trap premature");
        cleanupPlugin(pid);
        return;
    }
    // --- Negatiivi 3: vieras kutsuja → EPERM. ---
    // Lataa apuplugin vieraaksi (häntä, puretaan heti testin jälkeen).
    const stranger_raw = dispatch.invoke(abi.SYS_plugin_load, loader.PLUGIN_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_READ, 4);
    // Varmista positiivinen pid.
    if (stranger_raw <= 1) {
        // Apulataus epäonnistui.
        log.err("VSL trap stranger load failed");
        cleanupPlugin(pid);
        return;
    }
    // Vieras-pid u64:na.
    const stranger: u64 = @intCast(stranger_raw);
    // Vaihda vieraaksi ja yritä vaihtaa toisen persoonallisuutta.
    if (!process.setCurrentPid(stranger)) {
        // Vaihto epäonnistui.
        log.err("VSL trap switch failed");
        cleanupPlugin(stranger);
        cleanupPlugin(pid);
        return;
    }
    const eperm = dispatch.invoke(abi.SYS_plugin_trap, pid, 1, 0, 0, 0, 0);
    // Takaisin bootiksi joka tapauksessa.
    _ = process.setCurrentPid(process.BOOT_PID);
    if (eperm != abi.EPERM) {
        // Vieras pääsi vaihtamaan.
        log.err("VSL trap stranger not EPERM");
        cleanupPlugin(stranger);
        cleanupPlugin(pid);
        return;
    }
    // Lippu yhä pois (hylkäys ei vaikuttanut).
    if (process.isLinuxTrapped(pid)) {
        // Hylätty kutsu muutti tilaa.
        log.err("VSL trap rejected mutated");
        cleanupPlugin(stranger);
        cleanupPlugin(pid);
        return;
    }
    // Pura vieras (häntä → ei taulukkoaukkoa).
    if (dispatch.invoke(abi.SYS_plugin_unload, stranger, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("VSL trap stranger unload failed");
        cleanupPlugin(pid);
        return;
    }
    // --- Positiivi: enable trap (idempotentti tupla-enable OK). ---
    if (dispatch.invoke(abi.SYS_plugin_trap, pid, 1, 0, 0, 0, 0) != 0) {
        // Enable epäonnistui.
        log.err("VSL trap enable failed");
        cleanupPlugin(pid);
        return;
    }
    if (dispatch.invoke(abi.SYS_plugin_trap, pid, 1, 0, 0, 0, 0) != 0) {
        // Tupla-enable epäonnistui.
        log.err("VSL trap re-enable failed");
        cleanupPlugin(pid);
        return;
    }
    if (!process.isLinuxTrapped(pid)) {
        // Lippu ei syttynyt.
        log.err("VSL trap not set");
        cleanupPlugin(pid);
        return;
    }
    // --- Aja hello ring 3:ssa: uname → hello → uname-kaiku → enosys → exit. ---
    if (!loader.runPlugin(pid)) {
        // Ajo epäonnistui.
        log.err("VSL trap run failed");
        cleanupPlugin(pid);
        return;
    }
    // Nykyinen pid takaisin bootiksi (exit jättää zombie-kontekstin).
    _ = process.setCurrentPid(process.BOOT_PID);
    // Exit rekisteröityi zombieksi (koodi 0 — cmov valitsi OK-haaran).
    if (!process.isZombie(pid)) {
        // Ei zombiena ajon jälkeen.
        log.err("VSL trap not zombie");
        cleanupPlugin(pid);
        return;
    }
    // Trap-kuva validi ja Linux-numeroin: viimeinen kehys = exit(60, 0).
    if (!process.trapRegsValid(pid)) {
        // Kuvaa ei kaapattu.
        log.err("VSL trap regs missing");
        cleanupPlugin(pid);
        return;
    }
    var regs: [16]u64 = undefined;
    if (!process.trapRegs(pid, &regs)) {
        // Kopiointi epäonnistui validina.
        log.err("VSL trap regs copy failed");
        cleanupPlugin(pid);
        return;
    }
    if (regs[trap_core.REG_RAX] != 60) {
        // Viimeinen numero ei Linux-exit (odota 60, ei Zinux-2).
        log.err("VSL trap regs not linux");
        cleanupPlugin(pid);
        return;
    }
    if (regs[trap_core.REG_RDI] != 0) {
        // Exit-koodi väärä (cmov/valinta petti).
        log.err("VSL trap exit code wrong");
        cleanupPlugin(pid);
        return;
    }
    // Trap-kaappaus + käännös OK (serial-merkit varmistavat ajon sisällön).
    log.info("VSL trap capture OK");
    // --- Describe: checkpoint + regs-täyttö todellisen polun läpi. ---
    // Asenna port-cap kuvauksen cap-osalle (sys_plugin_load validoi muttei
    // asenna — 41.1-kaava; round-trip: slotti+tyyppi+maski palaavat).
    const desc_port = port.createPort() orelse {
        // Portti ei auennut.
        log.err("VSL trap port failed");
        cleanupPlugin(pid);
        return;
    };
    const desc_obj = cap.createObject(.port, process.BOOT_PID, desc_port) orelse {
        // Objekti ei syntynyt.
        log.err("VSL trap object failed");
        cleanupPlugin(pid);
        return;
    };
    const desc_slot = cap.installSlotForPid(pid, desc_obj, .{ .send = true }) orelse {
        // Slotti ei asentunut.
        log.err("VSL trap slot failed");
        cleanupPlugin(pid);
        return;
    };
    // Checkpoint zombie-pidistä (PML4 yhä voimassa — ei vapautettu).
    const cpid_raw = dispatch.invoke(abi.SYS_plugin_checkpoint, pid, 0, 0, 0, 0, 0);
    // Varmista positiivinen cpid.
    if (cpid_raw <= 0) {
        // Checkpoint epäonnistui.
        log.err("VSL trap checkpoint failed");
        cleanupPlugin(pid);
        return;
    }
    // Checkpoint-id u32:na.
    const cpid: u32 = @intCast(cpid_raw);
    // Täytä kuvaus (sivut + capit + trap-regs).
    var st = vstate.VslState.init();
    if (!statedesc.describeCheckpoint(pid, cpid, &st)) {
        // Täyttö epäonnistui.
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Regs kantavat exit-kehyksen (VSL_SPEC §11: ensimmäinen täyttö).
    if (st.regs[trap_core.REG_RAX] != 60) {
        // Kuvaus ei kanna trap-numeroa.
        log.err("VSL trap state regs wrong");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Entry-sivu ankkuroitu matalaan Linux-osoitteeseen (ei higher-half).
    if (!st.containsPage(LINUX_BASE)) {
        // Linux-koodisivu puuttuu kuvauksesta.
        log.err("VSL trap state page missing");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Yksi asennettu cap (portti/SEND round-trip).
    if (st.caps_len != 1) {
        // Väärä cap-määrä (odota 1).
        log.err("VSL trap state cap wrong");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    if (st.caps[0].slot != desc_slot or st.caps[0].abi_type != vstate.ABI_TYPE_PORT) {
        // Slotti/tyyppi ei täsmää asennettuun.
        log.err("VSL trap state cap mismatch");
        _ = snapshot.deleteCheckpoint(cpid);
        cleanupPlugin(pid);
        return;
    }
    // Poista checkpoint (stale-esto ennen unloadia).
    if (!snapshot.deleteCheckpoint(cpid)) {
        // Poisto epäonnistui.
        log.err("VSL trap delete failed");
        cleanupPlugin(pid);
        return;
    }
    // Tilakuvaus trap-regseillä OK.
    log.info("VSL trap state OK");
    // --- Disable: lippu pois + kuva mitätöityy. ---
    if (dispatch.invoke(abi.SYS_plugin_trap, pid, 0, 0, 0, 0, 0) != 0) {
        // Disable epäonnistui.
        log.err("VSL trap disable failed");
        cleanupPlugin(pid);
        return;
    }
    if (process.isLinuxTrapped(pid)) {
        // Lippu jäi päälle.
        log.err("VSL trap still set");
        cleanupPlugin(pid);
        return;
    }
    if (process.trapRegsValid(pid)) {
        // Kuva jäi voimaan.
        log.err("VSL trap regs stale");
        cleanupPlugin(pid);
        return;
    }
    // Pura demo (LIFO-puhdas — freePid tyhjentää persoonallisuuden).
    if (dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("VSL trap unload failed");
        return;
    }
    // Vapauta kuvauksen portti-objekti (BOOT-slotti siivotaan boundaryssa).
    _ = cap.revokeObject(desc_obj);
    // Trap-and-emulate päästä päähän OK.
    log.info("VSL trap OK");
}
