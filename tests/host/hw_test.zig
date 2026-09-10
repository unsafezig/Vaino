//! Host-testit laitegeneroinnille: plan-validointi + laajennus + sensori + ajo (Vaihe 36).
//!
//! **Vastuu**: Hyväksy demo-plan, hylkää jokainen virheluokka nimetyllä syyllä,
//!   todista laajennuksen deterministisyys (absoluuttiset osoitteet) sekä
//!   feikkisensorin merkityksellinen käyttäytyminen (armi, kiellot, katkot).
//!   Elinkaari-orkestraatio on boot-testissä (`hw_lifecycle.zig`).

// Tuo standardikirjasto testiasserteja varten.
const std = @import("std");
// Tuo puhdas generointiydin (plan + sensori + ajo).
const hw = @import("hw_gen");

// Demon ikkuna (sama kuin elinkaarissa — feikki-MMIO).
const DEMO_BASE: u64 = 0x100000;
const DEMO_LEN: u32 = 128;

// Rakenna demon laiteilmoitus (lämpö + kosteus).
fn demoDesc() hw.HwDescriptor {
    var d = hw.HwDescriptor{
        .mmio_base = DEMO_BASE,
        .mmio_len = DEMO_LEN,
        .caps = undefined,
        .caps_len = 2,
    };
    d.caps[0] = hw.makeCap("temperature", hw.REG_TEMP, hw.ACC_READ);
    d.caps[1] = hw.makeCap("humidity", hw.REG_HUM, hw.ACC_READ);
    return d;
}

// Rakenna demon suunnitelma (viritä + lue molemmat + odota 23.4C).
fn demoPlan() hw.DriverPlan {
    var p = hw.DriverPlan{
        .name_buf = undefined,
        .name_len = 0,
        .version = hw.PLAN_VERSION,
        .ranges = undefined,
        .ranges_len = 1,
        .forbidden = undefined,
        .forbidden_len = 0,
        .steps = undefined,
        .steps_len = 1,
        .read_caps = undefined,
        .reads_len = 2,
        .expect_cap = 0,
        .expect_value = hw.TEMP_TENTHS,
    };
    const nm = "sense-temp";
    var i: usize = 0;
    while (i < nm.len) : (i += 1) p.name_buf[i] = nm[i];
    p.name_len = nm.len;
    p.ranges[0] = .{ .base = DEMO_BASE, .len = DEMO_LEN };
    p.steps[0] = .{ .range_idx = 0, .reg = hw.REG_CTRL, .value = hw.CTRL_MAGIC };
    p.read_caps[0] = 0;
    p.read_caps[1] = 1;
    return p;
}

test "plan validate accepts demo and expansion resolves addresses" {
    // Demo kelpaa portista.
    const d = demoDesc();
    const p = demoPlan();
    try hw.validate(p, d);
    // Laajennus laskee absoluuttiset osoitteet deterministisesti.
    const b = try hw.generate(p, d);
    try std.testing.expectEqual(@as(u64, DEMO_BASE + @as(u64, hw.REG_CTRL) * 2), b.step_addrs[0]);
    try std.testing.expectEqual(hw.CTRL_MAGIC, b.step_values[0]);
    try std.testing.expectEqual(@as(usize, 1), b.steps_len);
    try std.testing.expectEqual(@as(u64, DEMO_BASE + @as(u64, hw.REG_TEMP) * 2), b.read_addrs[0]);
    try std.testing.expectEqual(@as(u64, DEMO_BASE + @as(u64, hw.REG_HUM) * 2), b.read_addrs[1]);
    try std.testing.expectEqual(@as(usize, 2), b.reads_len);
    try std.testing.expectEqual(@as(u64, DEMO_BASE + @as(u64, hw.REG_TEMP) * 2), b.expect_addr);
    try std.testing.expectEqual(hw.TEMP_TENTHS, b.expect_value);
    // Sama plan → sama laajennus (ei satunnaisuutta, ei tilaa).
    const b2 = try hw.generate(p, d);
    try std.testing.expectEqual(b.step_addrs[0], b2.step_addrs[0]);
    try std.testing.expectEqual(b.expect_addr, b2.expect_addr);
}

test "plan rejects names versions ranges" {
    const d = demoDesc();
    // Tyhjä nimi ja kauttaviiva hylätään.
    var noname = demoPlan();
    noname.name_len = 0;
    try std.testing.expectError(error.BadName, hw.validate(noname, d));
    var slash = demoPlan();
    slash.name_buf[0] = '/';
    try std.testing.expectError(error.BadName, hw.validate(slash, d));
    // Väärä versio hylätään.
    var ver = demoPlan();
    ver.version = 2;
    try std.testing.expectError(error.BadVersion, hw.validate(ver, d));
    // Ei alueita → BadRange (tyhjä pyyntö ei sitoudu).
    var norange = demoPlan();
    norange.ranges_len = 0;
    try std.testing.expectError(error.BadRange, hw.validate(norange, d));
    // Liikaa alueita → TooManyRanges.
    var many = demoPlan();
    many.ranges_len = 5;
    try std.testing.expectError(error.TooManyRanges, hw.validate(many, d));
    // Nollapituus, ylisuuri ja ikkunan ylittävä hylätään.
    var zero = demoPlan();
    zero.ranges[0].len = 0;
    try std.testing.expectError(error.BadRange, hw.validate(zero, d));
    var huge = demoPlan();
    huge.ranges[0].len = 0x2000;
    try std.testing.expectError(error.BadRange, hw.validate(huge, d));
    var outside = demoPlan();
    outside.ranges[0] = .{ .base = DEMO_BASE + 64, .len = 128 };
    try std.testing.expectError(error.BadRange, hw.validate(outside, d));
    // Kiertyvä kanta+pituus hylätään.
    var wrap = demoPlan();
    wrap.ranges[0] = .{ .base = 0xFFFF_FFFF_FFFF_FFF0, .len = 32 };
    try std.testing.expectError(error.BadRange, hw.validate(wrap, d));
}

test "plan rejects forbidden uart and bad steps" {
    // UART-peitto leveällä ikkunalla → ForbiddenOverlap (konsoli suojattu).
    var wide = demoDesc();
    wide.mmio_base = 0x0;
    wide.mmio_len = 0x200000;
    var uart = demoPlan();
    uart.ranges[0] = .{ .base = hw.UART_BASE, .len = 8 };
    try std.testing.expectError(error.ForbiddenOverlap, hw.validate(uart, wide));
    // Planin oma kielto leikkaa pyynnön → ForbiddenOverlap.
    var own = demoPlan();
    own.forbidden[0] = .{ .base = DEMO_BASE, .len = 16 };
    own.forbidden_len = 1;
    try std.testing.expectError(error.ForbiddenOverlap, hw.validate(own, demoDesc()));
    // Kielto vieressä ei osu (raja tarkka — puoliavoin leikkaus).
    var beside = demoPlan();
    beside.forbidden[0] = .{ .base = DEMO_BASE + DEMO_LEN, .len = 16 };
    beside.forbidden_len = 1;
    try hw.validate(beside, demoDesc());
    // 17 askelta → TooManySteps.
    var many = demoPlan();
    many.steps_len = 17;
    try std.testing.expectError(error.TooManySteps, hw.validate(many, demoDesc()));
    // Olematon alueindeksi → StepOutOfRange.
    var badi = demoPlan();
    badi.steps[0].range_idx = 3;
    try std.testing.expectError(error.StepOutOfRange, hw.validate(badi, demoDesc()));
    // Kartan ulkopuolinen rekisteri → StepOutOfRange.
    var badreg = demoPlan();
    badreg.steps[0].reg = 64;
    try std.testing.expectError(error.StepOutOfRange, hw.validate(badreg, demoDesc()));
    // Askel yli aluerajan (pieni alue, iso offset) → StepOutOfRange.
    var narrow = demoPlan();
    narrow.ranges[0] = .{ .base = DEMO_BASE, .len = 4 };
    narrow.steps[0].reg = hw.REG_TEMP;
    try std.testing.expectError(error.StepOutOfRange, hw.validate(narrow, demoDesc()));
}

test "plan rejects bad reads and cap access" {
    const d = demoDesc();
    // Ei lukuja → BadReads (tehtävän tarkoitus puuttuu).
    var noread = demoPlan();
    noread.reads_len = 0;
    try std.testing.expectError(error.BadReads, hw.validate(noread, d));
    // Liikaa lukuja → BadReads (katto).
    var many = demoPlan();
    many.reads_len = 9;
    try std.testing.expectError(error.BadReads, hw.validate(many, d));
    // Olematon cap-indeksi → BadCapAccess.
    var badidx = demoPlan();
    badidx.read_caps[0] = 7;
    try std.testing.expectError(error.BadCapAccess, hw.validate(badidx, d));
    // Vain-kirjoitus-cap ei kelpaa luvuksi → BadCapAccess.
    var wdesc = demoDesc();
    wdesc.caps[0] = hw.makeCap("heater", 0x05, hw.ACC_WRITE);
    const wread = demoPlan();
    try std.testing.expectError(error.BadCapAccess, hw.validate(wread, wdesc));
    // Odotusarvo olemattomaan capiin → BadCapAccess.
    var badexp = demoPlan();
    badexp.expect_cap = 6;
    try std.testing.expectError(error.BadCapAccess, hw.validate(badexp, d));
}

test "sensor arm magic readings and rejections" {
    // Tuore laite: ID luettavissa, mittaukset eivät (ei viritystä).
    var f = hw.FakeSensor.init();
    try std.testing.expectEqual(hw.SENSOR_ID, try hw.sensorRead(&f, hw.REG_ID));
    try std.testing.expectError(error.NotReady, hw.sensorRead(&f, hw.REG_TEMP));
    try std.testing.expectError(error.NotReady, hw.sensorRead(&f, hw.REG_HUM));
    // Väärä magia ei viritä (laite sietää).
    try hw.sensorWrite(&f, hw.REG_CTRL, 0x00);
    try std.testing.expectError(error.NotReady, hw.sensorRead(&f, hw.REG_TEMP));
    // Oikea magia virittää: STATUS nousee, mittaukset aukeavat.
    try hw.sensorWrite(&f, hw.REG_CTRL, hw.CTRL_MAGIC);
    try std.testing.expectEqual(@as(u16, 1), try hw.sensorRead(&f, hw.REG_STATUS));
    try std.testing.expectEqual(hw.TEMP_TENTHS, try hw.sensorRead(&f, hw.REG_TEMP));
    try std.testing.expectEqual(hw.HUM_TENTHS, try hw.sensorRead(&f, hw.REG_HUM));
    // Scratch R/W kiertää (konfiguraatio säilyy).
    try hw.sensorWrite(&f, 0x05, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), try hw.sensorRead(&f, 0x05));
    // Kiellot syyllä: kartta, vain-luku, vain-kirjoitus.
    try std.testing.expectError(error.OutOfRange, hw.sensorWrite(&f, 64, 1));
    try std.testing.expectError(error.OutOfRange, hw.sensorRead(&f, 200));
    try std.testing.expectError(error.ReadOnly, hw.sensorWrite(&f, hw.REG_ID, 1));
    try std.testing.expectError(error.ReadOnly, hw.sensorWrite(&f, hw.REG_TEMP, 1));
    try std.testing.expectError(error.WriteOnly, hw.sensorRead(&f, hw.REG_CTRL));
    // Hylkäykset lasketaan (mittaus: 2+1+2+2+1 = 8 vikaa yllä).
    try std.testing.expectEqual(@as(u32, 8), f.faults);
    // Reset tyhjentää virityksen mutta ei ID:tä.
    hw.sensorReset(&f);
    try std.testing.expectEqual(hw.SENSOR_ID, try hw.sensorRead(&f, hw.REG_ID));
    try std.testing.expectEqual(@as(u16, 0), try hw.sensorRead(&f, hw.REG_STATUS));
    try std.testing.expectError(error.NotReady, hw.sensorRead(&f, hw.REG_TEMP));
}

test "execSequence happy wrong-expect and unarmed" {
    // Onnellinen ajo päästä päähän (init virittää, luvut kelpaavat, odotus täsmää).
    const d = demoDesc();
    const b = try hw.generate(demoPlan(), d);
    var f = hw.FakeSensor.init();
    try std.testing.expect(hw.execSequence(b, &f, DEMO_BASE));
    // Väärä ikkuna hylkää osoitteet (sidottu toisaalle).
    try std.testing.expect(!hw.execSequence(b, &f, 0x200000));
    // Väärä odotusarvo hylkää ajon (vastalause toimii).
    var wrong = demoPlan();
    wrong.expect_value = 999;
    const wb = try hw.generate(wrong, d);
    var f2 = hw.FakeSensor.init();
    try std.testing.expect(!hw.execSequence(wb, &f2, DEMO_BASE));
    // Askellukseton plan ei viritä → luku NotReady → ajo false.
    var nostep = demoPlan();
    nostep.steps_len = 0;
    const nb = try hw.generate(nostep, d);
    var f3 = hw.FakeSensor.init();
    try std.testing.expect(!hw.execSequence(nb, &f3, DEMO_BASE));
}
