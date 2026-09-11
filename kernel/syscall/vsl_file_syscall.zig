//! VSL file-I/O boot-testi — VFS-syscallit invoke-polulla + ring-3-demo (VSL-4A).
//!
//! **Vastuu**: Todista `SYS_vfs_open/read/close` (29/30/31) kernel-kutsuilla
//!   (positiivi + ENOENT/EINVAL/EBADF-negatiivit) sekä ring-3-shimmin päästä
//!   päähän (`vsl_file_test`-ELF lukee /tmp/welcome ja tulostaa tavut).
//!   Itse-contained: alustaa VFS+tmpfs itse, ei residenttejä.
//! **Riippuvuudet**: `dispatch.zig` (invoke), `../fs/vfs.zig`,
//!   `../fs/tmpfs.zig`, `../plugin/loader.zig`, `../plugin/scope.zig`,
//!   `zinuxabi`, `process_core`, log
//! **Käytetään**: `kernel/boot_tests.zig` (vsl_state-testin jälkeen)
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Ring-3-todiste on sarjamerkki `vsl-file: TMPFS`: demo tulostaa LUETUT
//!   tavut (ei vakiota), joten merkki todistaa aidon tiedostoluvun user-tilasta.
//! - Negatiivit ensin (ENOENT/EINVAL/EBADF) — hylkäyspolut yhtä tärkeitä.
//! - Kahvat globaalissa taulukossa (ei per-pid-fd:tä): yhden pluginin koe,
//!   eristys dokumentoitu VSL_SPEC §11:een (VSL-4B/RBAC-jatko).

// Tuo jaettu ABI — VFS-syscallit + virheet + plugin-load.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3:a.
const dispatch = @import("dispatch.zig");
// Tuo VFS — open/read/close (kernel-puolen vertailu, ei syscall).
const vfs = @import("../fs/vfs.zig");
// Tuo tmpfs — init/mount + /welcome-seed.
const tmpfs = @import("../fs/tmpfs.zig");
// Tuo plugin-loader — FILE_EMBEDDED_ID + load/run/unload.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit latausvektoriin (port-manifesti, ei grantia).
const scope = @import("../plugin/scope.zig");
// Tuo prosessitaulukko — BOOT-konteksti + BOOT_PID.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Odotettu /tmp/welcome-sisältö (tmpfs.init-seed, ks. vsl_fs_syscall).
const EXPECTED = "TMPFS";

// Vertaa kahta tavuviipaletta — true jos sama pituus+sisältö.
fn eql(a: []const u8, b: []const u8) bool {
    // Pituus eri → eri.
    if (a.len != b.len) return false;
    // Käy tavut.
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        // Ero → eri.
        if (a[i] != b[i]) return false;
    }
    // Sama.
    return true;
}

// Boot-testi — VFS-syscallit + ring-3 file-demo.
pub fn runBootTest() void {
    // Alusta VFS puhtaaksi (oma taulu, ei sotke aiempia testejä).
    vfs.init();
    // Alusta tmpfs + /welcome-tiedosto.
    tmpfs.init();
    // Mount /tmp.
    tmpfs.registerMount() catch {
        // Mount epäonnistui.
        log.err("VSL file mount failed");
        return;
    };
    // --- Negatiivi 1: tuntematon polku → ENOENT (ei hiljaista läpimenoa). ---
    const missing = "/tmp/missing";
    if (dispatch.invoke(abi.SYS_vfs_open, @intFromPtr(missing.ptr), missing.len, 0, 0, 0, 0) != abi.ENOENT) {
        // Väärä vastaus puuttuvalle polulle.
        log.err("VSL file missing not ENOENT");
        return;
    }
    // --- Negatiivi 2: liput!=0 → EINVAL (vain read-only 4A:ssa). ---
    const welcome = "/tmp/welcome";
    if (dispatch.invoke(abi.SYS_vfs_open, @intFromPtr(welcome.ptr), welcome.len, 1, 0, 0, 0) != abi.EINVAL) {
        // Liput menivät läpi.
        log.err("VSL file flags not EINVAL");
        return;
    }
    // --- Negatiivi 3: tyhjä polku → EINVAL. ---
    if (dispatch.invoke(abi.SYS_vfs_open, @intFromPtr(welcome.ptr), 0, 0, 0, 0, 0) != abi.EINVAL) {
        // Tyhjä polku meni läpi.
        log.err("VSL file empty not EINVAL");
        return;
    }
    // --- Negatiivi 4: huono kahva → EBADF (read + close). ---
    var badbuf: [8]u8 = undefined;
    if (dispatch.invoke(abi.SYS_vfs_read, 0xFFFF_FFFF, @intFromPtr(&badbuf), badbuf.len, 0, 0, 0) != abi.EBADF) {
        // Huono kahva luki.
        log.err("VSL file bad read not EBADF");
        return;
    }
    if (dispatch.invoke(abi.SYS_vfs_close, 0xFFFF_FFFF, 0, 0, 0, 0, 0) != abi.EBADF) {
        // Huono kahva sulkeutui.
        log.err("VSL file bad close not EBADF");
        return;
    }
    // --- Positiivi: open → read → close invoke-polulla. ---
    const h = dispatch.invoke(abi.SYS_vfs_open, @intFromPtr(welcome.ptr), welcome.len, 0, 0, 0, 0);
    // Kahva ei-negatiivinen (virheet negatiivisia).
    if (h < 0) {
        // Avaus epäonnistui.
        log.err("VSL file open failed");
        return;
    }
    // Lukupuskuri kernelissä (invoke-osoite kernel-muistissa — sallittu).
    var kbuf: [32]u8 = undefined;
    const n = dispatch.invoke(abi.SYS_vfs_read, @intCast(h), @intFromPtr(&kbuf), kbuf.len, 0, 0, 0);
    // Odotettu 5 tavua.
    if (n != EXPECTED.len) {
        // Väärä pituus — sulje ja lopeta.
        _ = dispatch.invoke(abi.SYS_vfs_close, @intCast(h), 0, 0, 0, 0, 0);
        log.err("VSL file read len wrong");
        return;
    }
    // Varmista sisältö.
    if (!eql(kbuf[0..EXPECTED.len], EXPECTED)) {
        // Väärä sisältö — sulje ja lopeta.
        _ = dispatch.invoke(abi.SYS_vfs_close, @intCast(h), 0, 0, 0, 0, 0);
        log.err("VSL file content mismatch");
        return;
    }
    // Offset-luku ohi datan → 0 tavua (EOF-semantiikka).
    const eof = dispatch.invoke(abi.SYS_vfs_read, @intCast(h), @intFromPtr(&kbuf), kbuf.len, 99, 0, 0);
    if (eof != 0) {
        // EOF ei nollaa.
        _ = dispatch.invoke(abi.SYS_vfs_close, @intCast(h), 0, 0, 0, 0, 0);
        log.err("VSL file eof not zero");
        return;
    }
    // Sulje kahva (0 odotettu).
    if (dispatch.invoke(abi.SYS_vfs_close, @intCast(h), 0, 0, 0, 0, 0) != 0) {
        // Sulku epäonnistui.
        log.err("VSL file close failed");
        return;
    }
    // Tuplasulku → EBADF.
    if (dispatch.invoke(abi.SYS_vfs_close, @intCast(h), 0, 0, 0, 0, 0) != abi.EBADF) {
        // Tuplasulku meni läpi.
        log.err("VSL file double close not EBADF");
        return;
    }
    // Syscall-polku OK.
    log.info("VSL file syscall OK");
    // --- Ring-3: lataa file-demo, aja shimmin läpi, pura. ---
    // Port-manifesti (demo ei tarvitse cappeja — manifesti on latausportti).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.FILE_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("VSL file load failed");
        return;
    }
    // Demo-pid u64:na.
    const pid: u64 = @intCast(pid_raw);
    // Aja ring 3:ssa: open/read/close + `vsl-file: TMPFS` + tuplasulku-EBADF.
    if (!loader.runPlugin(pid)) {
        // Ajo epäonnistui.
        log.err("VSL file run failed");
        // Siivoa lataus.
        _ = process.setCurrentPid(process.BOOT_PID);
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        return;
    }
    // Nykyinen pid takaisin bootiksi.
    _ = process.setCurrentPid(process.BOOT_PID);
    // Pura demo (LIFO-puhdas, ei residenttejä).
    if (dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0) != 0) {
        // Purku epäonnistui.
        log.err("VSL file unload failed");
        return;
    }
    // Ring-3 file-I/O + purku OK.
    log.info("VSL file IO OK");
}
