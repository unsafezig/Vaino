//! Eeden-simulaatio — 30 päivän elinkaari pikakelattuna (Vaihe 37.2, puhdas ydin).
//!
//! **Vastuu**: Aja deterministinen 30 päivän autonomia-simulaatio OIKEILLA
//!   ytimillä (TDL-parse, resolve, diag, tunneli, migraatio, klusteri,
//!   decomposer) virtuaalikellolla ja kerää `Report`-mittarit. Ei satunnaisuutta,
//!   ei I/O:ta, ei allokaatiota — sama tulos joka ajolla (tutkittava koe).
//! **Riippuvuudet**: build-moduulit `composer_task`, `composer_resolve`,
//!   `plugin_diag_core`, `fed_tunnel`, `fed_migrate`, `fed_failover`,
//!   `decomposer_core` (sama jaetun instanssin kaava kuin aiemmissa vaiheissa).
//! **Käytetään**: `tools/eeden_gate.zig` (porttityökalu), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Simulaatio EI väitä olevansa 30 oikeaa päivää: se ajaa samat puhtaat
//!   päätösfunktiot kuin kerneli (sama koodi, virtuaalikello) ja mittaa että
//!   elinkaari sulkeutuu (core-only). Rehellisyys dokumentoitu EEDEN_DEMO:ssa.
//! - Vuorovaikutukset kernel-tilan kanssa (loader, sivutaulut) eivät ole
//!   simuloitavissa hostissa — ne todistaa QEMU-puoli (`kernel/eeden.zig`).
//!   Simu todistaa päätöslogiikan + mittarit; QEMU mekanismin. Kumpikaan ei
//!   yksin riitä portiksi (gate vaatii molemmat CI:ssä).

// Tuo TDL-ydin (tehtävän laskenta).
const task = @import("composer_task");
// Tuo ratkaisuheuristiikka (tarve → plugin).
const resolve = @import("composer_resolve");
// Tuo diagnostiikka (vika → havainto → parannus).
const diag = @import("plugin_diag_core");
// Tuo tunneli (todennettu työntö migraatiossa).
const tunnel = @import("fed_tunnel");
// Tuo migraatiotila (staged/pushed/restored/done).
const migrate = @import("fed_migrate");
// Tuo klusteri + replika (syke/pyyhkäisy/ylennys).
const failover = @import("fed_failover");
// Tuo purkupolitiikka (deadline-predikaatti).
const decomposer = @import("decomposer_core");

// Simulaation aikaskaala: 1 päivä = 1000 tickiä (30 pv = 30000, u64-turvallinen).
pub const DAY_TICKS: u64 = 1000;
pub const SIM_DAYS: u32 = 30;
// Vikasuunnitelma: vikapäivät (jokaiseen 1 vika + saman päivän parannus).
pub const FAULT_DAYS: [5]u32 = .{ 3, 7, 12, 19, 26 };
// Kaksoisvikapäivä: kaksi injektiota → kova kaatuminen → parannus samana päivänä.
pub const DOUBLE_FAULT_DAY: u32 = 12;
// Migraatiopäivä (uptime A→B) ja solmuhäviö (A vaikenee).
pub const MIGRATE_DAY: u32 = 14;
pub const LOSS_DAY: u32 = 21;
// Tehtävän valmistumispäivä (purku).
pub const DONE_DAY: u32 = 29;
// Simuloidun pluginin pid (ei loaderia hostissa — diag ei tarvitse sitä).
pub const SIM_PID: u64 = 100;
pub const SIM_SPARE_PID: u64 = 101;
// Solmut (A=koti, B=vara).
pub const NODE_A: u32 = 1;
pub const NODE_B: u32 = 2;
// Sykkeen vanheneminen (1.5 päivää — päivittäinen syke pitää elossa).
pub const HEARTBEAT_TIMEOUT: u64 = 1500;
// Demon TDL (sama muoto kuin kernel-puolen eeden-tehtävä).
pub const DEMO_TASK = "task \"serve\" { need port:send+recv; need port:recv; timeout 30000; plugins 2; }";

// Elinkaaren mittarit — pelkkiä lukuja (työkalu muotoilee).
pub const Report = struct {
    // Boot onnistui (päivä 0).
    boot_ok: bool,
    // Tehtävä laskettiin + ratkaistiin (päivä 0).
    task_ok: bool,
    // Aloitetut koostumukset.
    compositions_started: u64,
    // Valmiiksi puretut koostumukset.
    compositions_done: u64,
    // Injektoidut viat.
    faults: u64,
    // Vikapäivät (joka päättyy parannukseen — takuun nimittäjä).
    fault_days: u64,
    // Havainnot jossa tila oli crashed (kovat kaatumiset).
    crashes: u64,
    // Parannukset (vika → terve saman päivän aikana).
    heals: u64,
    // Valmiit migraatiot.
    migrations: u64,
    // Onnistuneet failover-ylennykset.
    failovers: u64,
    // Todetut tunnelityönnöt.
    tunnel_grants_ok: u64,
    // Eletyt päivät (täysi 30).
    uptime_days: u64,
    // Deadline-predikaatti johdotettu (erääntyy rajalla).
    deadline_ok: bool,
    // Lopussa ydin yksin (ei plugineja/vertialla/reittejä).
    core_only: bool,
};

// Nollattu raportti.
fn emptyReport() Report {
    return .{
        .boot_ok = false,
        .task_ok = false,
        .compositions_started = 0,
        .compositions_done = 0,
        .faults = 0,
        .fault_days = 0,
        .crashes = 0,
        .heals = 0,
        .migrations = 0,
        .failovers = 0,
        .tunnel_grants_ok = 0,
        .uptime_days = 0,
        .core_only = false,
        .deadline_ok = false,
    };
}

// Onko päivä vikasuunnitelmassa.
fn isFaultDay(day: u32) bool {
    var i: usize = 0;
    while (i < FAULT_DAYS.len) : (i += 1) {
        if (FAULT_DAYS[i] == day) return true;
    }
    return false;
}

// Aja 30 päivää päästä päähän — palauttaa mittarit (deterministinen).
pub fn run() Report {
    var rep = emptyReport();
    // Puhdas diagnoositaulukko (ei edellisen ajon tilaa — sama ajo toistuu).
    diag.initCore();

    // --- Päivä 0: boot + tehtävä + klusteri + replika + tunneli ---
    rep.boot_ok = true;
    // Tehtävä tekstistä binääriksi + ratkaisu (todellinen ydin, ei stub).
    const spec = task.parse(DEMO_TASK) catch return rep;
    var reqs: [8]resolve.PluginReq = undefined;
    const n = resolve.resolve(spec, &reqs) catch return rep;
    if (n != 2) return rep;
    rep.task_ok = true;
    rep.compositions_started = 1;
    // Klusteri: A + B liittyvät.
    var cluster = failover.Cluster.init();
    if (!cluster.join(NODE_A, 0)) return rep;
    if (!cluster.join(NODE_B, 0)) return rep;
    // Replika: koti A, vara B.
    var replica = failover.ReplicaPlan.init(NODE_A, NODE_B);
    if (!replica.valid()) return rep;
    // Tunneli testiavaimella (deterministinen 1..32 — simun sisäinen).
    var key: [tunnel.KEY_LEN]u8 = undefined;
    var ki: usize = 0;
    while (ki < key.len) : (ki += 1) key[ki] = @intCast(ki + 1);
    var tun = tunnel.Tunnel.init(key);
    tun.addPeer(NODE_A) catch return rep;
    tun.addPeer(NODE_B) catch return rep;
    // Diagnoosi simuloidulle pluginille.
    if (!diag.registerDiagnostic(SIM_PID)) return rep;
    // Migraatiosuunnitelma odottamaan päivää 14.
    var plan = migrate.MigrationPlan.init();

    // --- Päivät 1..29: syke, viat, migraatio, häviö, valmistuminen ---
    var promoted = false;
    var day: u32 = 1;
    while (day < SIM_DAYS) : (day += 1) {
        const now = @as(u64, day) * DAY_TICKS;
        // B sykkii aina (vara elää loppuun asti).
        _ = cluster.heartbeat(NODE_B, now);
        // A sykkii kunnes häviää (LOSS_DAY:stä vaikenee).
        if (day < LOSS_DAY) _ = cluster.heartbeat(NODE_A, now);
        // Vikapäivät: injektoi → havaitse → paranna samana päivänä.
        // Kaksoisvikapäivänä kaksi injektiota (kova kaatuminen testiin).
        if (isFaultDay(day)) {
            rep.fault_days += 1;
            const n_faults: u32 = if (day == DOUBLE_FAULT_DAY) 2 else 1;
            var fi: u32 = 0;
            while (fi < n_faults) : (fi += 1) {
                diag.recordFault(SIM_PID, -50 - @as(i32, @intCast(day)));
                rep.faults += 1;
            }
            // Kova kaatuminen lasketaan (virheraja täynnä).
            if (diag.getHealth(SIM_PID) == .crashed) rep.crashes += 1;
            // Parannus: nollaa → terve (self-healing-takuu).
            diag.resetDiagnostic(SIM_PID);
            if (diag.getHealth(SIM_PID) == .healthy) rep.heals += 1;
        }
        // Migraatiopäivä: todennettu työntö + tilakone päästä päähän.
        if (day == MIGRATE_DAY) {
            const sealed = tun.sealNext(NODE_A, SIM_PID, 3, NODE_B, 0x0c);
            var wire = sealed;
            const opened = tun.open(&wire) catch return rep;
            if (opened.src_node != NODE_A or opened.dest_node != NODE_B) return rep;
            rep.tunnel_grants_ok += 1;
            plan.stage(SIM_PID, NODE_A, NODE_B) catch return rep;
            plan.notePushed(1, 1) catch return rep;
            plan.noteRestored() catch return rep;
            plan.finish() catch return rep;
            rep.migrations += 1;
            // Vara palvelee nyt.
            replica.noteServing(SIM_SPARE_PID);
        }
        // Pyyhkäisy päivittäin: ensimmäinen todettu A-häviö → ylennys.
        _ = cluster.sweep(now, HEARTBEAT_TIMEOUT);
        if (!promoted and !cluster.isAlive(NODE_A)) {
            if (replica.promoteOnLoss(NODE_A, false, cluster.isAlive(NODE_B)) == .replicated) {
                rep.failovers += 1;
            }
            promoted = true;
        }
        // Valmistumispäivä: tehtävä valmis → pura kaikki (LIFO-järjestys
        // on loaderin asia QEMU-puolella; simu todistaa päätöksen + mittarit).
        if (day == DONE_DAY) {
            rep.compositions_done += 1;
            _ = cluster.leave(NODE_A);
            _ = cluster.leave(NODE_B);
            _ = tun.removePeer(NODE_A);
            _ = tun.removePeer(NODE_B);
            _ = diag.deregisterDiagnostic(SIM_PID);
        }
    }
    // Eletty täysi 30 päivää (päivät 0..29).
    rep.uptime_days = SIM_DAYS;
    // Deadline-predikaatti johdotettu demon timeoutiin (30000):
    // rajalla erääntynyt, sitä ennen ei.
    const deadline: u64 = 30000;
    if (!decomposer.isExpired(deadline - 1, deadline)) {
        if (decomposer.isExpired(deadline, deadline)) rep.deadline_ok = true;
    }
    // Core-only: kokoonpano purettu, klusteri tyhjä, tunneli kiinni,
    // diagnoosi tyhjä, replika ylennetty (palvelu elää varalla — ydin itse
    // ei kanna plugin-tilaa).
    if (rep.compositions_done == rep.compositions_started and
        cluster.aliveCount() == 0 and
        tun.peerCount() == 0 and
        diag.countActive() == 0 and
        replica.state == .replicated)
    {
        rep.core_only = true;
    }
    return rep;
}
