//! Checkpoint-säilön puhdas taulukko — allokaatio/etsintä/vapautus (31.5.2).
//!
//! **Vastuu**: Kiinteän checkpoint-taulukon hallinta ilman laitteistoa.
//! Kehys- (PMM) ja PTE-operaatiot elävät `snapshot.zig`:ssä; tämä on pyyntö-
//! ja kirjanpitotaso joka on host-testattava ilman PML4:ää tai kehyksiä.
//! **Riippuvuudet**: ei (puhdas logiikka — sama kaava kuin `scope.zig`,
//!   nolla `@import`:ia kiertojen välttämiseksi)
//! **Käytetään**: `kernel/snapshot.zig` (varsinainen checkpoint/delete),
//!   host-testit.

// Montako checkpointia säilössä (yksi per plugin riittää; katto rajattu).
pub const MAX_CHECKPOINTS: usize = 4;
// Montako sivua yhteen checkpointiin (inventaarion katto — sama kuin walk).
pub const MAX_CKPT_PAGES: usize = 64;

// Yksi kopioitu sivu checkpointissa.
pub const CkptPage = struct {
    // Originaalin virtuaaliosoite pluginin avaruudessa.
    virt: u64,
    // Kopion kehys (fyysinen osoite — PMM omistaa kunnes delete).
    frame_phys: u64,
    // Oli kirjoitettava ennen suojausta (palautetaan deletessä).
    was_writable: bool,
};

// Yksi plugin-checkpoint kiinteässä taulukossa.
pub const Checkpoint = struct {
    // Onko paikka käytössä.
    used: bool,
    // Kohdepluginin pid.
    plugin_pid: u64,
    // PML4 kävely- ja suojaushetkellä (stale-tarkistus deletessä).
    pml4_phys: u64,
    // Montako sivua kopioitu.
    page_count: usize,
    // Kopiotaulukko.
    pages: [MAX_CKPT_PAGES]CkptPage,
};

// Kiinteä checkpoint-taulukko — ei allokaatiota.
var ckpts: [MAX_CHECKPOINTS]Checkpoint = undefined;
// Onko taulukko nollattu.
var ckpts_init: bool = false;

// Nollaa taulukko tarvittaessa — kutsutaan julkisista funktioista.
fn ensureInit() void {
    // Jo alustettu — ei työtä.
    if (ckpts_init) return;
    // Tyhjennä jokainen paikka.
    for (&ckpts) |*c| {
        // Merkitse vapaa.
        c.used = false;
        // Nollaa pid.
        c.plugin_pid = 0;
        // Nollaa PML4.
        c.pml4_phys = 0;
        // Ei sivuja.
        c.page_count = 0;
    }
    // Merkitse alustetuksi.
    ckpts_init = true;
}

// Etsi checkpointin taulukkoindeksi cpid:llä (cpid = indeksi+1).
fn findIdx(cpid: u32) ?usize {
    // Varmista nollattu taulukko.
    ensureInit();
    // cpid 0 varattu (virheellinen).
    if (cpid == 0) return null;
    // Indeksi cpid:stä.
    const idx: usize = @intCast(cpid - 1);
    // Rajojen ulkopuolella.
    if (idx >= MAX_CHECKPOINTS) return null;
    // Vapaa paikka.
    if (!ckpts[idx].used) return null;
    // Palauta indeksi.
    return idx;
}

// Hae paikka jaettuna viitteenä cpid:llä — null jos tuntematon.
pub fn slotByCpid(cpid: u32) ?*Checkpoint {
    // Hae indeksi.
    const idx = findIdx(cpid) orelse return null;
    // Palauta osoitin paikkaan.
    return &ckpts[idx];
}

// Etsi pluginin checkpoint — null jos ei ole (replace-päätös).
pub fn findForPid(pid: u64) ?u32 {
    // Varmista nollattu taulukko.
    ensureInit();
    // Käy paikat.
    var i: usize = 0;
    while (i < MAX_CHECKPOINTS) : (i += 1) {
        // Käytössä + pid täsmää.
        if (ckpts[i].used and ckpts[i].plugin_pid == pid) return @intCast(i + 1);
    }
    // Ei checkpointia.
    return null;
}

// Montako checkpointia säilössä (hygieniatarkistus).
pub fn count() usize {
    // Varmista nollattu taulukko.
    ensureInit();
    // Laskuri.
    var n: usize = 0;
    // Käy paikat.
    for (ckpts) |c| {
        // Käytössä → laske.
        if (c.used) n += 1;
    }
    // Palauta määrä.
    return n;
}

// Varaa vapaa paikka pidille + PML4:lle — null jos täynnä.
// Palauttaa cpid:n (indeksi+1, nolla varattu).
pub fn allocSlot(pid: u64, pml4_phys: u64) ?u32 {
    // Varmista nollattu taulukko.
    ensureInit();
    // Etsi vapaa paikka.
    var i: usize = 0;
    while (i < MAX_CHECKPOINTS) : (i += 1) {
        // Vapaa paikka löytyi.
        if (!ckpts[i].used) {
            // Merkitse varatuksi ennen täyttöä (reentranssi-turva).
            ckpts[i].used = true;
            // Sido pidiin.
            ckpts[i].plugin_pid = pid;
            // Tallenna PML4 stale-tarkistusta varten.
            ckpts[i].pml4_phys = pml4_phys;
            // Ei sivuja vielä.
            ckpts[i].page_count = 0;
            // Palauta cpid.
            return @intCast(i + 1);
        }
    }
    // Säilö täynnä.
    return null;
}

// Vapauta paikka (kehysten/PTE:n siivous on kutsujan vastuulla).
// Palauttaa false jos tuntematon cpid.
pub fn releaseSlot(cpid: u32) bool {
    // Hae paikka.
    const slot = slotByCpid(cpid) orelse return false;
    // Merkitse vapaaksi.
    slot.used = false;
    // Tyhjennä laskuri.
    slot.page_count = 0;
    // Onnistui.
    return true;
}

// Kopioidun sivun virtuaaliosoite — null jos rajat ulkona.
pub fn pageVirt(cpid: u32, idx: usize) ?u64 {
    // Hae paikka.
    const slot = slotByCpid(cpid) orelse return null;
    // Indeksi sivujen ulkopuolella.
    if (idx >= slot.page_count) return null;
    // Palauta originaalin virt-osoite.
    return slot.pages[idx].virt;
}

// Kopioidun sivun kehysosoite — null jos rajat ulkona.
pub fn pageFrame(cpid: u32, idx: usize) ?u64 {
    // Hae paikka.
    const slot = slotByCpid(cpid) orelse return null;
    // Indeksi sivujen ulkopuolella.
    if (idx >= slot.page_count) return null;
    // Palauta kopion kehysosoite.
    return slot.pages[idx].frame_phys;
}

// Kopioidun sivun was_writable-lippu — null jos rajat ulkona.
pub fn pageWasWritable(cpid: u32, idx: usize) ?bool {
    // Hae paikka.
    const slot = slotByCpid(cpid) orelse return null;
    // Indeksi sivujen ulkopuolella.
    if (idx >= slot.page_count) return null;
    // Palauta lippu.
    return slot.pages[idx].was_writable;
}

// Kopioitujen sivujen määrä — null jos tuntematon cpid.
pub fn pageCount(cpid: u32) ?usize {
    // Hae paikka.
    const slot = slotByCpid(cpid) orelse return null;
    // Palauta määrä.
    return slot.page_count;
}
