//! Eeden-mittarit — porttikriteerit 30 päivän raportille (Vaihe 37.2, puhdas ydin).
//!
//! **Vastuu**: Arvioi simulaation `Report` kiinteitä kynnyksiä vasten ja nimeä
//!   jokainen pettänyt tarkistus bitmaskissa. Ei I/O:ta, ei allokaatiota —
//!   työkalu (`tools/eeden_gate.zig`) muotoilee ja päättää poistumiskoodin.
//! **Riippuvuudet**: ei (tarkistukset lukevat vain raportin kenttiä; simu
//!   tuodaan työkalussa/host-testeissä, ei tässä — ei kiertoa).
//! **Käytetään**: `tools/eeden_gate.zig`, host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Portti on mitta, ei mielipide: jokainen kynnys on kokonaisluku, jokainen
//!   tulos toistettava (`sim.run()` kahdesti → sama maski, testattu).
//! - Kynnysten kiristäminen ei vaadi simun muutosta (arvioi minkä tahansa
//!   raportin — myös käsin rakennetun huonon, testattu).

// Tarkistusbitit (bit i = CHECK_NAMES[i] petti).
pub const CHECK_BOOT: u32 = 1 << 0;
pub const CHECK_TASK: u32 = 1 << 1;
pub const CHECK_COMPOSITIONS: u32 = 1 << 2;
pub const CHECK_HEALED: u32 = 1 << 3;
pub const CHECK_MIGRATIONS: u32 = 1 << 4;
pub const CHECK_FAILOVERS: u32 = 1 << 5;
pub const CHECK_TUNNEL: u32 = 1 << 6;
pub const CHECK_UPTIME: u32 = 1 << 7;
pub const CHECK_DEADLINE: u32 = 1 << 8;
pub const CHECK_CORE_ONLY: u32 = 1 << 9;

// Tarkistusten nimet (työkalun raportointiin, kiinteät merkkijonot).
pub const CHECK_NAMES: [10][]const u8 = .{
    "boot_ok",
    "task_ok",
    "compositions_done>=1",
    "heals>=fault_days",
    "migrations>=1",
    "failovers==1",
    "tunnel_grants_ok>=1",
    "uptime_days>=30",
    "deadline_ok",
    "core_only",
};

// Portin tulos: läpi jos maski nolla.
pub const Verdict = struct {
    // Petettyjen tarkistusten bittimaski (0 = PASSED).
    failed_mask: u32,
    // Läpäisty (mukavuus).
    pub fn passed(self: Verdict) bool {
        return self.failed_mask == 0;
    }
};

// Kevyt raporttinäkymä (ankka-tyyppi simun Reportille — ei import-kiertoa).
// Kentät luetaan nimellä; simu ja käsin rakennetut raportit kelpaavat.
pub fn evaluate(rep: anytype) Verdict {
    var mask: u32 = 0;
    // Boot onnistui päivänä 0.
    if (!rep.boot_ok) mask |= CHECK_BOOT;
    // Tehtävä laskettiin + ratkaistiin.
    if (!rep.task_ok) mask |= CHECK_TASK;
    // Ainakin yksi kokoonpano vietiin purkuun asti.
    if (rep.compositions_done < 1) mask |= CHECK_COMPOSITIONS;
    // Jokainen vikapäivä päättyi parannukseen (parannustakuu — ei orpoja päiviä).
    // Nimittäjä on päivät, ei injektiot: yksi reset sulkee päivän kaikki viat.
    if (rep.heals < rep.fault_days) mask |= CHECK_HEALED;
    // Ainakin yksi migraatio valmistui.
    if (rep.migrations < 1) mask |= CHECK_MIGRATIONS;
    // Täsmälleen yksi failover (yksi häviö simussa — ei enempää, ei vähempää).
    if (rep.failovers != 1) mask |= CHECK_FAILOVERS;
    // Ainakin yksi todennettu tunnelityöntö.
    if (rep.tunnel_grants_ok < 1) mask |= CHECK_TUNNEL;
    // Täysi 30 päivää eletty.
    if (rep.uptime_days < 30) mask |= CHECK_UPTIME;
    // Deadline-predikaatti johdotettu.
    if (!rep.deadline_ok) mask |= CHECK_DEADLINE;
    // Lopussa ydin yksin.
    if (!rep.core_only) mask |= CHECK_CORE_ONLY;
    return .{ .failed_mask = mask };
}
