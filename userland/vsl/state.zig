//! VSL-tilakuvaus — snapshot-valmis `VslState`-formaatti (VSL-3, 41.1).
//!
//! **Vastuu**: Puhdas, kiinteäkokoinen kuvaus pluginin tilasta: rekisterit,
//!   capability-viitteet (slot + ABI-tyyppi + oikeusmaski) ja sivut (virt +
//!   dirty-lippu). Ei syscalleja, ei allokaatiota — täyttö on kernelin
//!   (`vsl_state_syscall.zig` lukee checkpoint-inventaarion), tulkinta
//!   host-testattavaa (sama kaava kuin `plugin_manifest.zig`).
//! **Riippuvuudet**: ei
//! **Käytetään**: kernelin VSL-boot-testi (41.1 describe), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Kuvaus on pyyntö/tietue, ei lupa: restore-päätös pysyy kernelillä
//!   (`snapshot.zig` kieltäytyy staleness-portilla kuvauksesta riippumatta).
//! - ABI-numerot (1=port, 5=memory; bit0 read … bit5 grant) — sama layout
//!   kuin scope/manifest/TDL, jotta kernel-vertailu on bittitarkka.
//!   Kernelin sisäinen `CapType.memory=2` käännetään ABI-bittiin 5
//!   täyttöpuolella (Phase-29-kaava), ei tässä.
//! - Sivukapasiteetti 64 == `snapshot.MAX_SNAP_PAGES`: täysi inventaario
//!   mahtuu aina — kuvaus ei katkaise eikä valehtele osittaisella.
//! - Dirty-lippu tulee 31.5.4-mekanismista (#PF-merkintä), ei arvauksesta:
//!   boot-testi todistaa sekä puhtaan (VSL) että likaisen (dirty_test)
//!   tapauksen.
//! - Rekisteritiedostoa (regs[16]) ei täytetä 41.1:ssä: 31.5.2 ei kaappaa
//!   rekistereitä, joten kuvaus jättää ne nolliksi rehellisesti (VSL_SPEC §6).
//!   Täyttö on varattu VSL-4:lle (trap-and-emulate).

// Formaatin versio — lukija hylkää muut (yhteensopivuusportti).
pub const VSL_STATE_VERSION: u32 = 1;
// Rekisteripaikkoja (x86_64 yleisrekisterit; nollia 41.1:ssä, ks. yllä).
pub const MAX_STATE_REGS: usize = 16;
// Capability-viitteitä (manifest MAX_CAPS -pariteetti).
pub const MAX_STATE_CAPS: usize = 8;
// Sivuviitteitä (snapshot MAX_SNAP_PAGES -pariteetti, ei katkaisua).
pub const MAX_STATE_PAGES: usize = 64;
// Sallitut ABI-tyypit (scope/manifest/TDL-layout).
pub const ABI_TYPE_PORT: u32 = 1;
pub const ABI_TYPE_MEMORY: u32 = 5;
// Sallitut oikeusbitit (bit0..bit5, scope-layout).
pub const MASK_ALL: u32 = 0x3F;

// Kuvausvirheet vakaassa järjestyksessä (vastalause nimeää aina yhden vian).
pub const StateError = error{
    // Tuntematon ABI-tyyppi cap-viitteessä (vain 1/5).
    BadCapType,
    // Varattu bitti tai tyhjä maski oikeuksissa.
    BadRights,
    // Cap-viitteitä yli MAX_STATE_CAPS.
    TooManyCaps,
    // Nolla-osoite sivuviitteessä (ei plugin-sivu).
    BadPage,
    // Sivuviitteitä yli MAX_STATE_PAGES.
    TooManyPages,
};

// Yksi capability-viite — slot + ABI-tyyppi + oikeusmaski (VSL_SPEC §6).
pub const CapRef = struct {
    // Capability-slotti pluginin taulukossa.
    slot: u32,
    // ABI-tyyppi (1=port, 5=memory).
    abi_type: u32,
    // Oikeusmaski (bit0 read … bit5 grant).
    rights_mask: u32,
};

// Yksi sivuviite — virtuaaliosoite + dirty-lippu (VSL_SPEC §6).
pub const PageRef = struct {
    // Sivun perusosoite (4K-aligned).
    virt: u64,
    // Likainen (#PF-merkitty 31.5.4-polulla) vai puhdas.
    dirty: bool,
};

// VSL-tilan kanoninen kuvaus — kiinteäkokoinen, ei allokaatiota.
pub const VslState = struct {
    // Formaatin versio (aina VSL_STATE_VERSION).
    version: u32,
    // Rekisteritiedosto (nollia 41.1:ssä — ei kaappausta 31.5.2:ssa).
    regs: [MAX_STATE_REGS]u64,
    // Cap-viitteet.
    caps: [MAX_STATE_CAPS]CapRef,
    // Montako cap-viitettä käytössä.
    caps_len: usize,
    // Sivuviitteet.
    pages: [MAX_STATE_PAGES]PageRef,
    // Montako sivuviitettä käytössä.
    pages_len: usize,

    // Tyhjä kuvaus (versio leimattu, laskurit nollassa).
    pub fn init() VslState {
        return VslState{
            // Leimaa versio heti.
            .version = VSL_STATE_VERSION,
            // Rekisterit nolliksi (ei kaappausta vielä).
            .regs = [_]u64{0} ** MAX_STATE_REGS,
            // Cap-taulu tyhjäksi (nollaviitteet eivät kelpaa).
            .caps = [_]CapRef{.{ .slot = 0, .abi_type = 0, .rights_mask = 0 }} ** MAX_STATE_CAPS,
            // Ei cap-viitteitä vielä.
            .caps_len = 0,
            // Sivuviitteet nolliksi.
            .pages = [_]PageRef{.{ .virt = 0, .dirty = false }} ** MAX_STATE_PAGES,
            // Ei sivuviitteitä vielä.
            .pages_len = 0,
        };
    }

    // Lisää cap-viite — validointi heti (fail-fast, ei myöhäistä yllätystä).
    pub fn addCap(self: *VslState, slot: u32, abi_type: u32, rights_mask: u32) StateError!void {
        // Tyyppi sallittujen joukossa (vain ABI 1/5).
        if (abi_type != ABI_TYPE_PORT and abi_type != ABI_TYPE_MEMORY) return error.BadCapType;
        // Ei varattuja bittejä.
        if ((rights_mask & ~MASK_ALL) != 0) return error.BadRights;
        // Tyhjä maski hyödytön — hylkää.
        if (rights_mask == 0) return error.BadRights;
        // Taulukko täynnä.
        if (self.caps_len >= MAX_STATE_CAPS) return error.TooManyCaps;
        // Tallenna viite.
        self.caps[self.caps_len] = .{ .slot = slot, .abi_type = abi_type, .rights_mask = rights_mask };
        // Kasvata laskuria.
        self.caps_len += 1;
    }

    // Lisää sivuviite — virt nollasta poikkeava (nolla ei ole plugin-sivu).
    pub fn addPage(self: *VslState, virt: u64, dirty: bool) StateError!void {
        // Nolla-osoite ei kelpaa (tyhjän merkki).
        if (virt == 0) return error.BadPage;
        // Taulukko täynnä.
        if (self.pages_len >= MAX_STATE_PAGES) return error.TooManyPages;
        // Tallenna viite.
        self.pages[self.pages_len] = .{ .virt = virt, .dirty = dirty };
        // Kasvata laskuria.
        self.pages_len += 1;
    }

    // Montako sivuviitettä likaisia (inkrementaali kopioisi nämä).
    pub fn dirtyCount(self: *const VslState) usize {
        // Laskuri.
        var n: usize = 0;
        // Käy viitteet.
        var i: usize = 0;
        while (i < self.pages_len) : (i += 1) {
            // Likainen → laske.
            if (self.pages[i].dirty) n += 1;
        }
        // Palauta määrä.
        return n;
    }

    // Löytyykö virtuaaliosoite sivuviitteistä (ankkuritarkistus).
    pub fn containsPage(self: *const VslState, virt: u64) bool {
        // Käy viitteet.
        var i: usize = 0;
        while (i < self.pages_len) : (i += 1) {
            // Täsmäävä perusosoite.
            if (self.pages[i].virt == virt) return true;
        }
        // Ei löytynyt.
        return false;
    }
};
