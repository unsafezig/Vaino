//! Hardware-driver generation — plan validation + template expansion (Vaihe 36.2, puhdas ydin).
//!
//! **Vastuu**: Määrittele koneluettava `DriverPlan` (pyyntö), validoi se
//!   laitetta (`HwDescriptor`) ja kernel-politiikkaa vasten, laajenna se
//!   sidotuksi ajuriksi (`BoundDriver`: valmiiksi lasketut osoitteet) ja
//!   aja se feikkisensoria vasten (`FakeSensor` + `execSequence`).
//!   Ei allokaatiota, ei importteja — freestanding + host-testattava.
//! **Riippuvuudet**: ei.
//! **Käytetään**: `kernel/hw_lifecycle.zig` (elinkaari + boot-testi), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - "Generointi" EI tarkoita Zig-kääntäjää kernelissä (mahdoton ja väärä
//!   lupaus). Runko (rekisteröinti, elinkaari, IPC, virhekehykset) on
//!   determinististä Zinux-infrastruktuuria; generoitu osa on VAIN
//!   laitekohtainen kartta: mitkä rekisterit, millä init-sekvenssillä,
//!   millä odotusarvolla. AI ehdottaa karttaa, kernel päättää.
//! - Plan on pyyntö, ei lupa: jokainen alue leikataan laitteen ikkunaan JA
//!   kiellettyihin alueisiin (mm. kernel-konsolin UART 0x3F8 — vaiheen 1
//!   perintö). Leikkaus on hiljaisuuden sijaan hylkäys (fail-closed).
//! - Feikkilaite ennen oikeaa laitetta: `FakeSensor` mallintaa merkityksellistä
//!   käyttäytymistä (arm-magia, not-ready-tila, read-only/write-only, katkot),
//!   ei triviaalia mockia joka hyväksyy kaiken.
//! - Odotusarvo (`expect`) on vaiheen vastalause-mekanismi: ajo vertaa luettua
//!   luvattua vasten; ero on mitattava hylkäys, ei hiljainen ajautuminen.

// Ajurisuunnitelman versio — kernel hylkää muut (yhteensopivuusportti).
pub const PLAN_VERSION: u32 = 1;
// Suunnitelman nimen maksimipituus (manifest-pariteetti).
pub const MAX_PLAN_NAME: usize = 32;
// Pyydettyjen MMIO-alueiden enimmäismäärä per plan.
pub const MAX_RANGES: usize = 4;
// Init-kirjoitusten enimmäismäärä (rajattu sekvenssi, ei ohjelma).
pub const MAX_STEPS: usize = 16;
// Lukujen enimmäismäärä per ajo.
pub const MAX_READS: usize = 8;
// Laitteen nimeämien capabilityjen enimmäismäärä.
pub const MAX_CAPS: usize = 8;
// Kiellettyjen alueiden enimmäismäärä per plan.
pub const MAX_FORBIDDEN: usize = 4;
// Yhden alueen maksimipituus (4 KiB — pieni, mitattava raja).
pub const MAX_RANGE_LEN: u32 = 0x1000;
// Feikkisensorin rekisterimäärä (16-bittisiä).
pub const SENSOR_REGS: usize = 64;
// Kernel-konsolin UART (vaihe 1) — aina kielletty planeissa.
pub const UART_BASE: u64 = 0x3F8;
pub const UART_LEN: u64 = 8;

// Feikkisensorin rekisterikartta (merkityksellinen malli, ei triviaali mock).
pub const REG_ID: u8 = 0x00; // Luku: laitetunniste 0x5E55 ("sensor").
pub const REG_STATUS: u8 = 0x01; // Luku: bit0 = ready (vain armin jälkeen).
pub const REG_CTRL: u8 = 0x02; // Kirjoitus: 0xA5 virittää, muu ei.
pub const REG_TEMP: u8 = 0x10; // Luku: lämpötila kymmenyksinä (234 = 23.4C).
pub const REG_HUM: u8 = 0x11; // Luku: kosteus kymmenyksinä (551 = 55.1%).
pub const CTRL_MAGIC: u16 = 0xA5; // Viritysmagia CTRL-rekisteriin.
pub const SENSOR_ID: u16 = 0x5E55; // ID-rekisterin odotusarvo.
pub const TEMP_TENTHS: u16 = 234; // Demon lämpötilalukema (23.4C).
pub const HUM_TENTHS: u16 = 551; // Demon kosteuslukema (55.1%).
// Scratch-alue: 0x03..0x0F ja 0x12..0x3F vapaasti R/W (konfiguraatio).
pub const SCRATCH_LO: u8 = 0x03;
pub const SCRATCH_HI: u8 = 0x3F;

// Pääsyoikeusbitit alueille/capeille (bit0 luku, bit1 kirjoitus).
pub const ACC_READ: u8 = 1 << 0;
pub const ACC_WRITE: u8 = 1 << 1;

// Generointivirheet vakaassa järjestyksessä (vastalause nimeää yhden vian).
pub const GenError = error{
    // Tyhjä, liian pitkä tai ei-tulostettava nimi (myös `/`, `\`).
    BadName,
    // Väärä suunnitelmaversio.
    BadVersion,
    // Ei alueita (tyhjä pyyntö ei sitoudu).
    BadRange,
    // Liikaa alueita.
    TooManyRanges,
    // Liikaa init-askeleita.
    TooManySteps,
    // Ei lukuja tai liikaa (tehtävän tarkoitus puuttuu / katto).
    BadReads,
    // Pyyntö osuu kiellettyyn alueeseen (ml. kernel-UART).
    ForbiddenOverlap,
    // Askel viittaa olemattomaan alueeseen tai sen ulos.
    StepOutOfRange,
    // Luku viittaa olemattomaan/ei-luettavaan capiin.
    BadCapAccess,
};

// Sensorivirheet (ajonaikaiset vastalauseet — tarkka syy, ei "rejected").
pub const SensorError = error{
    // Rekisterinumero yli kartan (mikä offset, mikä maksimi — kutsuja kertoo).
    OutOfRange,
    // Kirjoitus vain-luku-rekisteriin.
    ReadOnly,
    // Luku vain-kirjoitus-rekisteristä.
    WriteOnly,
    // Mittaus ennen viritystä (laite ei valmis).
    NotReady,
};

// Yksi pyydetty MMIO-alue (alijoukko laitteen ikkunasta).
pub const RangeReq = struct {
    // Fyysinen kantaosoite.
    base: u64,
    // Pituus tavuina (>0, ≤ MAX_RANGE_LEN, ei kierrosta).
    len: u32,
};

// Yksi kielletty alue (kernel-varattu tai laiteen kieltämä).
pub const Forbidden = struct {
    // Kantaosoite.
    base: u64,
    // Pituus tavuina.
    len: u64,
};

// Yksi init-kirjoitus (sidotaan alueeseen — ei irrallisia osoitteita).
pub const InitStep = struct {
    // Kohdealueen indeksi plan.ranges:ssa.
    range_idx: u8,
    // Kohderekisteri sensorikartassa.
    reg: u8,
    // Kirjoitettava arvo.
    value: u16,
};

// Laitteen nimeämä capability (rekisteri + suunta).
pub const HwCap = struct {
    // Nimen tavut.
    name_buf: [16]u8,
    // Nimen pituus.
    name_len: usize,
    // Rekisterinumero kartassa.
    reg: u8,
    // Pääsy (ACC_READ / ACC_WRITE).
    access: u8,
};

// Laitteen ilmoitus: ikkuna + nimetyt capabilityt (protokolla 36.1).
pub const HwDescriptor = struct {
    // MMIO-ikkunan kanta.
    mmio_base: u64,
    // MMIO-ikkunan pituus.
    mmio_len: u32,
    // Nimetyt capabilityt.
    caps: [MAX_CAPS]HwCap,
    // Montako capia käytössä.
    caps_len: usize,
};

// Ajurisuunnitelma: tehtävä + resurssit + operaatiot + odotusarvo (pyyntö).
pub const DriverPlan = struct {
    // Nimen tavut.
    name_buf: [MAX_PLAN_NAME]u8,
    // Nimen pituus.
    name_len: usize,
    // Suunnitelmaversio (aina PLAN_VERSION).
    version: u32,
    // Pyydetyt alueet (laitteen ikkunan alijoukko).
    ranges: [MAX_RANGES]RangeReq,
    // Montako aluetta käytössä (≥1).
    ranges_len: usize,
    // Kielletyt alueet (kernel-varatun lisäksi).
    forbidden: [MAX_FORBIDDEN]Forbidden,
    // Montako kieltoa käytössä.
    forbidden_len: usize,
    // Init-sekvenssi (rajattu, ei silmukoita/hyppyjä).
    steps: [MAX_STEPS]InitStep,
    // Montako askelta käytössä.
    steps_len: usize,
    // Lukucapien indeksit descriptorissa (tehtävän mittaukset).
    read_caps: [MAX_READS]u8,
    // Montako lukua (≥1 — tehtävän tarkoitus).
    reads_len: usize,
    // Odotusarvo-capin indeksi + arvo (ajonaikainen vastalause).
    expect_cap: u8,
    expect_value: u16,
};

// Sidottu ajuri: laajennettu, absoluuttisilla osoitteilla (deterministinen).
pub const BoundDriver = struct {
    // Tehtävän nimi (jäljitys).
    name_buf: [MAX_PLAN_NAME]u8,
    name_len: usize,
    // Init-osoitteet (base + reg*2) + arvot.
    step_addrs: [MAX_STEPS]u64,
    step_values: [MAX_STEPS]u16,
    steps_len: usize,
    // Lukuosoitteet.
    read_addrs: [MAX_READS]u64,
    reads_len: usize,
    // Odotusarvo-osoite + arvo.
    expect_addr: u64,
    expect_value: u16,
};

// Leikkaavatko [a_base, a_base+a_len) ja [b_base, b_base+b_len) (puoliavoin).
fn overlaps(a_base: u64, a_len: u64, b_base: u64, b_len: u64) bool {
    // Tyhjä väli ei leikkaa mitään.
    if (a_len == 0 or b_len == 0) return false;
    // Saturating-loppu kiertymää vastaan (kiertyvä pyyntö on jo hylätty,
    // mutta leikkaus ei saa kietoutua hiljaa).
    const a_end = a_base +% a_len;
    const b_end = b_base +% b_len;
    // Kiertymä → käsittele leikkaavana (fail-closed).
    if (a_end < a_base or b_end < b_base) return true;
    return a_base < b_end and b_base < a_end;
}

// Onko cap luettava (hakemisto + suunta).
fn capReadable(desc: HwDescriptor, idx: u8) bool {
    if (idx >= desc.caps_len) return false;
    return (desc.caps[idx].access & ACC_READ) != 0;
}

// Rakenna cap-nimi (kopio katkaistuna, pituus talteen).
pub fn makeCap(name: []const u8, reg: u8, access: u8) HwCap {
    var c = HwCap{ .name_buf = undefined, .name_len = 0, .reg = reg, .access = access };
    var i: usize = 0;
    while (i < name.len and i < 16) : (i += 1) c.name_buf[i] = name[i];
    c.name_len = i;
    while (i < 16) : (i += 1) c.name_buf[i] = 0;
    return c;
}

// Validoi suunnitelma laitetta + kernel-politiikkaa vasten (pyyntö → päätös).
pub fn validate(plan: DriverPlan, desc: HwDescriptor) GenError!void {
    // Nimi ei tyhjä eikä yli rajan.
    if (plan.name_len == 0 or plan.name_len > MAX_PLAN_NAME) return error.BadName;
    // Tulostettava ASCII, ei polkuerottimia (manifest-kaava).
    var i: usize = 0;
    while (i < plan.name_len) : (i += 1) {
        const c = plan.name_buf[i];
        if (c < 0x20 or c > 0x7E) return error.BadName;
        if (c == '/' or c == '\\') return error.BadName;
    }
    // Versio lukittu.
    if (plan.version != PLAN_VERSION) return error.BadVersion;
    // Alueita 1..MAX_RANGES (tyhjä pyyntö ei sitoudu mihinkään).
    if (plan.ranges_len == 0) return error.BadRange;
    if (plan.ranges_len > MAX_RANGES) return error.TooManyRanges;
    // Laitteen ikkuna ei tyhjä (rikkinäinen ilmoitus — ei planin vika vaan
    // laitteen; hylätään silti BadRange:na, kutsuja erottaa).
    if (desc.mmio_len == 0) return error.BadRange;
    const win_end = desc.mmio_base +% desc.mmio_len;
    if (win_end < desc.mmio_base) return error.BadRange;
    // Käy alueet: muoto + ikkuna + kiellot.
    var r: usize = 0;
    while (r < plan.ranges_len) : (r += 1) {
        const q = plan.ranges[r];
        // Pituus (0 tai yli katon).
        if (q.len == 0 or q.len > MAX_RANGE_LEN) return error.BadRange;
        // Kiertymä kanta+pituus.
        const q_end = q.base +% q.len;
        if (q_end < q.base) return error.BadRange;
        // Alijoukko laitteen ikkunasta (ei yli reunan).
        if (q.base < desc.mmio_base or q_end > win_end) return error.BadRange;
        // Kernel-konsolin UART aina kielletty (vaiheen 1 perintö — konsolia
        // ei generoida uusiksi, piste).
        if (overlaps(q.base, q.len, UART_BASE, UART_LEN)) return error.ForbiddenOverlap;
        // Planin omat kiellot.
        var f: usize = 0;
        while (f < plan.forbidden_len) : (f += 1) {
            if (overlaps(q.base, q.len, plan.forbidden[f].base, plan.forbidden[f].len)) {
                return error.ForbiddenOverlap;
            }
        }
    }
    // Askeleet mahtuvat kattoon.
    if (plan.steps_len > MAX_STEPS) return error.TooManySteps;
    // Käy askeleet: alue + rekisteri + tavupeitto.
    var s: usize = 0;
    while (s < plan.steps_len) : (s += 1) {
        const st = plan.steps[s];
        // Alueindeksi olemassa.
        if (st.range_idx >= plan.ranges_len) return error.StepOutOfRange;
        // Rekisteri kartassa.
        if (st.reg >= SENSOR_REGS) return error.StepOutOfRange;
        // Tavupeitto [reg*2, reg*2+2) alueen sisällä (16-bittinen liittymä).
        const need_off: u64 = @as(u64, st.reg) * 2;
        const q = plan.ranges[st.range_idx];
        if (need_off + 2 > q.len) return error.StepOutOfRange;
    }
    // Lukuja 1..MAX_READS (tehtävän tarkoitus — ei lukuja, ei ajuria).
    if (plan.reads_len == 0 or plan.reads_len > MAX_READS) return error.BadReads;
    // Käy luvut: cap olemassa + luettava.
    var rd: usize = 0;
    while (rd < plan.reads_len) : (rd += 1) {
        if (!capReadable(desc, plan.read_caps[rd])) return error.BadCapAccess;
    }
    // Odotusarvo-cap luettava.
    if (!capReadable(desc, plan.expect_cap)) return error.BadCapAccess;
}

// Laajenna validoitu suunnitelma sidotuksi ajuriksi (absoluuttiset osoitteet).
pub fn generate(plan: DriverPlan, desc: HwDescriptor) GenError!BoundDriver {
    // Portti ensin (pyyntö → päätös; laajennus vasta hyväksytystä).
    try validate(plan, desc);
    var b = BoundDriver{
        .name_buf = undefined,
        .name_len = 0,
        .step_addrs = undefined,
        .step_values = undefined,
        .steps_len = 0,
        .read_addrs = undefined,
        .reads_len = 0,
        .expect_addr = 0,
        .expect_value = plan.expect_value,
    };
    // Kopioi nimi.
    var i: usize = 0;
    while (i < plan.name_len) : (i += 1) b.name_buf[i] = plan.name_buf[i];
    b.name_len = plan.name_len;
    while (i < MAX_PLAN_NAME) : (i += 1) b.name_buf[i] = 0;
    // Askeleet: alueen kanta + rekisterin tavusiirtymä (deterministinen).
    var s: usize = 0;
    while (s < plan.steps_len) : (s += 1) {
        const st = plan.steps[s];
        b.step_addrs[s] = plan.ranges[st.range_idx].base + @as(u64, st.reg) * 2;
        b.step_values[s] = st.value;
    }
    b.steps_len = plan.steps_len;
    // Lukucapit: laitteen ikkuna + capin rekisteri (kartta laitteelta).
    var rd: usize = 0;
    while (rd < plan.reads_len) : (rd += 1) {
        const reg = desc.caps[plan.read_caps[rd]].reg;
        b.read_addrs[rd] = desc.mmio_base + @as(u64, reg) * 2;
    }
    b.reads_len = plan.reads_len;
    // Odotusarvo-osoite samalla kaavalla.
    b.expect_addr = desc.mmio_base + @as(u64, desc.caps[plan.expect_cap].reg) * 2;
    return b;
}

// Feikkisensori — merkityksellinen laitemalli (tila + säännöt, ei triviaali mock).
pub const FakeSensor = struct {
    // 64×16-bittinen rekisterikartta.
    regs: [SENSOR_REGS]u16,
    // Viritetty (CTRL-magia kirjoitettu).
    armed: bool,
    // Hylättyjen liittymien laskuri (mittaus: montako vastalausetta).
    faults: u32,

    // Nollaa laite (sammutettu tila — ID kovakoodattu, muu nolla).
    pub fn init() FakeSensor {
        var f = FakeSensor{ .regs = undefined, .armed = false, .faults = 0 };
        var i: usize = 0;
        while (i < SENSOR_REGS) : (i += 1) f.regs[i] = 0;
        f.regs[REG_ID] = SENSOR_ID;
        return f;
    }

    // Onko rekisteri vain-luku (ID/STATUS/mittaukset).
    fn isReadOnly(reg: u8) bool {
        return reg == REG_ID or reg == REG_STATUS or reg == REG_TEMP or reg == REG_HUM;
    }
};

// Nollaa ajonaikainen tila (ID säilyy — laite ei unohda tyyppiään).
pub fn sensorReset(f: *FakeSensor) void {
    var i: usize = 0;
    while (i < SENSOR_REGS) : (i += 1) {
        if (i != REG_ID) f.regs[i] = 0;
    }
    f.armed = false;
}

// Kirjoita rekisteriin laitteen säännöillä (virhe = vastalause syyllä).
pub fn sensorWrite(f: *FakeSensor, reg: u8, value: u16) SensorError!void {
    // Kartan ulkopuoli hylätään (kutsu kertoo offsetin ja maksimin).
    if (reg >= SENSOR_REGS) {
        f.faults += 1;
        return error.OutOfRange;
    }
    // Vain-luku ei ota vastaan.
    if (FakeSensor.isReadOnly(reg)) {
        f.faults += 1;
        return error.ReadOnly;
    }
    // CTRL-magia virittää; väärä arvo ei (eikä kaada — laite sietää).
    if (reg == REG_CTRL) {
        f.regs[REG_CTRL] = value;
        if (value == CTRL_MAGIC) {
            f.armed = true;
            f.regs[REG_STATUS] = 1;
        }
        return;
    }
    // Scratch-alue R/W.
    f.regs[reg] = value;
}

// Lue rekisteri laitteen säännöillä (mittaukset vaativat virityksen).
pub fn sensorRead(f: *FakeSensor, reg: u8) SensorError!u16 {
    // Kartan ulkopuoli hylätään.
    if (reg >= SENSOR_REGS) {
        f.faults += 1;
        return error.OutOfRange;
    }
    // CTRL on vain-kirjoitus (takaisinluku ei paljasta magiaa).
    if (reg == REG_CTRL) {
        f.faults += 1;
        return error.WriteOnly;
    }
    // Mittaukset ennen viritystä eivät kelpaa (laite ei arvaa).
    if ((reg == REG_TEMP or reg == REG_HUM) and !f.armed) {
        f.faults += 1;
        return error.NotReady;
    }
    // Viritetyn mittauksen fysiikka (deterministinen feikki: 23.4C / 55.1%).
    if (f.armed and reg == REG_TEMP) return TEMP_TENTHS;
    if (f.armed and reg == REG_HUM) return HUM_TENTHS;
    // ID/STATUS/scratch suoraan kartasta.
    return f.regs[reg];
}

// Aja sidottu ajuri sensoria vasten: init + luvut + odotusarvo.
// Palauttaa true vain jos KAIKKI onnistui ja odotusarvo täsmäsi.
pub fn execSequence(b: BoundDriver, f: *FakeSensor, mmio_base: u64) bool {
    // Init-askeleet järjestyksessä (osoite → rekisteri ikkunan kautta).
    var s: usize = 0;
    while (s < b.steps_len) : (s += 1) {
        // Osoite ikkunan alla (muuten sivuuta — sidottu osoite ei kuulu tänne).
        if (b.step_addrs[s] < mmio_base) return false;
        const off = b.step_addrs[s] - mmio_base;
        // 16-bittinen tasattu, kartan sisällä.
        if (off % 2 != 0 or off / 2 >= SENSOR_REGS) return false;
        const reg: u8 = @intCast(off / 2);
        sensorWrite(f, reg, b.step_values[s]) catch return false;
    }
    // Lukucapit (tulos hylätään tässä — mittaus itsessään on sivuvaikutukseton;
    // kutsuja lukee arvot erikseen; ajo todistaa vain kelvollisuuden).
    var rd: usize = 0;
    while (rd < b.reads_len) : (rd += 1) {
        if (b.read_addrs[rd] < mmio_base) return false;
        const off = b.read_addrs[rd] - mmio_base;
        if (off % 2 != 0 or off / 2 >= SENSOR_REGS) return false;
        const reg: u8 = @intCast(off / 2);
        _ = sensorRead(f, reg) catch return false;
    }
    // Odotusarvo: lue ja vertaa (vastalauseen ydin — ero hylkää ajon).
    if (b.expect_addr < mmio_base) return false;
    const eoff = b.expect_addr - mmio_base;
    if (eoff % 2 != 0 or eoff / 2 >= SENSOR_REGS) return false;
    const ereg: u8 = @intCast(eoff / 2);
    const got = sensorRead(f, ereg) catch return false;
    return got == b.expect_value;
}
