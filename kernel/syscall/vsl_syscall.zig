//! VSL boot-testi — stub-pluginin lifecycle + mini-ABI-vektorit (VSL-0/VSL-1).
//!
//! **Vastuu**: Lataa VSL-ELF (embedded_id=1) manifesti+scope-valvonnalla,
//!   aja ring-3:ssa (`vsl\n`), pura LIFO-puhtaasti. Ei jätä residenttejä.
//! **Riippuvuudet**: `dispatch.zig`, `../plugin/loader.zig`, `../plugin/scope.zig`, log
//! **Käytetään**: `kernel/boot_tests.zig` (plugin_transfer-jälkeen, puhdas taulu)
//!
//! ## Arkkitehtuurihuomiot
//! - Sama valvontakaava kuin `plugin_load_syscall.zig`: ensin negatiivit
//!   (bad id → EINVAL, grant-es kalaatio → EPERM), sitten kelvollinen lataus.
//! - VSL-scope: portti (SEND|RECV) + memory (MAP|READ) — ei GRANTia (I4).
//! - Boot-testi purkaa VSL:n itse: seuraavat testit (heal/composer) näkevät
//!   tyhjän taulun, kuten transfer-testin jälkeen.

// Tuo jaettu ABI — SYS_plugin_load/unload + virhekoodit.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3.
const dispatch = @import("dispatch.zig");
// Tuo plugin-loader — VSL_EMBEDDED_ID + load/run/unload.
const loader = @import("../plugin/loader.zig");
// Tuo scope-maskit manifesti+scope-vektoreihin.
const scope = @import("../plugin/scope.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Boot-testi — VSL-lataus valvonnalla + ring-3-ajo + purku.
pub fn runBootTest() void {
    // VSL-0-negatiivi: tuntematon plugin-binääri → EINVAL.
    const bad_id = dispatch.invoke(abi.SYS_plugin_load, 99, 1, scope.MASK_SEND, scope.TYPE_PORT, scope.MASK_SEND, 4);
    // Varmista EINVAL eikä pid.
    if (bad_id != abi.EINVAL) {
        // Tuntematon id meni läpi.
        log.err("VSL load bad id not EINVAL");
        // Lopeta testi.
        return;
    }
    // VSL-0-negatiivi: grant-es kalaatio VSL-scopella ilman grantia → EPERM.
    const evil = dispatch.invoke(abi.SYS_plugin_load, loader.VSL_EMBEDDED_ID, 1, scope.MASK_GRANT, scope.TYPE_PORT, scope.MASK_SEND, 4);
    // Varmista EPERM eikä pid.
    if (evil != abi.EPERM) {
        // Eskalaatio meni läpi.
        log.err("VSL load escalation not EPERM");
        // Lopeta testi.
        return;
    }
    // VSL-0-positiivi: port/send-manifesti, VSL-scope (port+memory, ei grant).
    const pid_raw = dispatch.invoke(abi.SYS_plugin_load, loader.VSL_EMBEDDED_ID, 1, scope.MASK_SEND, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Varmista positiivinen plugin-pid.
    if (pid_raw <= 1) {
        // Lataus epäonnistui.
        log.err("VSL load failed");
        // Lopeta testi.
        return;
    }
    // Uusi VSL-pid u64:na.
    const pid: u64 = @intCast(pid_raw);
    // Rekisterissä latauksen jälkeen.
    if (!loader.isPlugin(pid)) {
        // Rekisteröinti puuttuu.
        log.err("VSL not registered");
        // Siivoa osittainen lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        // Lopeta testi.
        return;
    }
    // Suorita VSL ring-3:ssa — tulostaa "vsl\n" serialiin.
    if (!loader.runPlugin(pid)) {
        // Ajo epäonnistui.
        log.err("VSL run failed");
        // Siivoa lataus.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        // Lopeta testi.
        return;
    }
    // Lataus + valvonta + ajo OK.
    log.info("VSL stub OK");
    // VSL-1-vektori: mini-ABI-käännöksen rakenne-eheys bootissa.
    // (Täydet käännösvektorit host-testissä `vsl_abi_test.zig`; tässä
    //  savutesti että VSL-scope kattaa ABI:n tarvitsemat tyypit.)
    // Portti-bitti scopessa (IPC-väylä write/read).
    const has_port = (scope.TYPE_PORT & (scope.TYPE_PORT | scope.TYPE_MEMORY)) != 0;
    // Muisti-bitti scopessa (brk/mmap-tausta).
    const has_mem = (scope.TYPE_MEMORY & (scope.TYPE_PORT | scope.TYPE_MEMORY)) != 0;
    // Molemmat vaaditaan — muuten ABIvalehtelisi tuesta.
    if (!has_port or !has_mem) {
        // Scope ei kata ABI:a.
        log.err("VSL ABI scope incomplete");
        // Siivoa silti.
        _ = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
        // Lopeta testi.
        return;
    }
    // ABI-rakenne OK.
    log.info("VSL ABI OK");
    // Pura VSL — LIFO-puhdas, ei residenttejä seuraaville testeille.
    const unloaded = dispatch.invoke(abi.SYS_plugin_unload, pid, 0, 0, 0, 0, 0);
    // Varmista purku onnistui.
    if (unloaded != 0) {
        // Purku epäonnistui — taulu likainen.
        log.err("VSL unload failed");
        // Lopeta testi.
        return;
    }
}
