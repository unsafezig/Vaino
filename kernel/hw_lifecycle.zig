//! Driver-lifecycle — generoi → sido → aja → tuhoa (Vaihe 36.3, freestanding).
//!
//! **Vastuu**: Orkestroi feikkisensorin ajuri päästä päähän: laite havaitaan,
//!   plan validoidaan + laajennetaan (`hw_gen`), ajuri ajetaan sensoria vasten
//!   ja tuhotaan ilman jäänteitä. Ei pysyviä ajuritiedostoja — sidottu ajuri
//!   elää vain tässä tietueessa ajon ajan (NO_DRIVERS-periaate).
//! **Riippuvuudet**: `hw_gen.zig` (suhteellinen, puhdas ydin), log.
//! **Käytetään**: `kernel/boot_tests.zig::runAll()` (boot-testi).
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Elinkaari on kernelin päätösputki: jokainen vaihe (havainto, generointi,
//!   ajo, tuho) tarkistaa edellisen. Väärä plan ei etene sidontaan, epäonnistunut
//!   ajo ei jää aktiiviseksi, tuho nollaa kaiken (ei orpoja sidoksia).
//! - Feikkisensori on boot-testin "laite" (fake ennen oikeaa laitetta):
//!   tuntematon sensori liitetään → ilmoittaa capinsa → ajuri generoidaan →
//!   mittaus → laite irtoaa → ajuri tuhoutuu. Oikea MMIO on vaihetta 36.x.
//! - Kaikki lokit staattisia merkkijonoja (log.info ottaa vain comptime-str);
//!   mitattu 234 kymmenystä todennetaan ennen staattista "23.4C"-riviä.

// Tuo puhdas generointiydin (plan + validointi + laajennus + sensori).
const hw = @import("hw_gen.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("lib/log.zig");

// Demon ikkuna (feikki-MMIO — ei oikeaa laitetta vaiheessa 36).
pub const DEMO_BASE: u64 = 0x100000;
pub const DEMO_LEN: u32 = 128;

// Aktiivinen sidottu ajuri (vain yksi kerrallaan — mitattava raja).
var record: hw.BoundDriver = undefined;
// Onko tietueessa elävä ajuri.
var record_active: bool = false;

// Onko ajuri aktiivinen (testien suojatarkistus).
pub fn isActive() bool {
    return record_active;
}

// Generoi + sido: validoi plan, laajenna, kirjaa tietueeseen.
pub fn generateBind(plan: hw.DriverPlan, desc: hw.HwDescriptor) bool {
    // Vain yksi kerrallaan (toinen kieltäytyy — ei pinoamista).
    if (record_active) return false;
    // Portti + laajennus (hylkäys ei koske tietuetta).
    const b = hw.generate(plan, desc) catch return false;
    record = b;
    record_active = true;
    return true;
}

// Aja aktiivinen ajuri sensoria vasten (odotusarvo porttina).
pub fn execActive(f: *hw.FakeSensor, mmio_base: u64) bool {
    if (!record_active) return false;
    return hw.execSequence(record, f, mmio_base);
}

// Tuohoaa aktiivisen ajurin (tietue nollataan — ei jäänteitä).
pub fn destroy() bool {
    if (!record_active) return false;
    record_active = false;
    record.steps_len = 0;
    record.reads_len = 0;
    return true;
}

// Rakenna demon laiteilmoitus: lämpötila + kosteus (staattinen cap-lista).
fn demoDescriptor() hw.HwDescriptor {
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

// Rakenna demon suunnitelma: viritä + lue molemmat + odota 23.4C.
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
    // Nimi "sense-temp".
    const nm = "sense-temp";
    var i: usize = 0;
    while (i < nm.len) : (i += 1) p.name_buf[i] = nm[i];
    p.name_len = nm.len;
    // Koko ikkuna pyydettynä alueena.
    p.ranges[0] = .{ .base = DEMO_BASE, .len = DEMO_LEN };
    // Init: kirjoita magia CTRL:ään (alue 0, rekisteri REG_CTRL).
    p.steps[0] = .{ .range_idx = 0, .reg = hw.REG_CTRL, .value = hw.CTRL_MAGIC };
    // Luvut: molemmat capit.
    p.read_caps[0] = 0;
    p.read_caps[1] = 1;
    return p;
}

// Boot-testi — tuntematon sensori → ajuri → mittaus → tuho (Vaihe 36).
pub fn runBootTest() void {
    // Laite ilmestyy (feikki — tila nollattu, ID kovakoodattu).
    var sensor = hw.FakeSensor.init();
    // Tunniste luetaan ennen mitään muuta (vieras laite tunnistetaan).
    const id = hw.sensorRead(&sensor, hw.REG_ID) catch {
        log.err("Hw sensor id failed");
        return;
    };
    if (id != hw.SENSOR_ID) {
        log.err("Hw sensor id mismatch");
        return;
    }
    log.info("Unknown device detected");
    // Laite ilmoittaa kykynsä (protokolla 36.1 — nimet + rekisterit).
    const desc = demoDescriptor();
    if (desc.caps_len != 2) {
        log.err("Hw caps missing");
        return;
    }
    log.info("Capabilities: temperature, humidity");

    // Negatiivi 1: kernel-UART:iin kurottava plan hylätään (konsoli suojattu).
    // Ikkuna peittää UART:n, joten hylkäys tulee kiellosta eikä reunasta.
    var uart_desc = demoDescriptor();
    uart_desc.mmio_base = 0x0;
    uart_desc.mmio_len = 0x200000;
    var uart_plan = demoPlan();
    uart_plan.ranges[0] = .{ .base = hw.UART_BASE, .len = 8 };
    if (hw.generate(uart_plan, uart_desc)) |_| {
        log.err("Hw uart overlap accepted");
        return;
    } else |e| {
        if (e != error.ForbiddenOverlap) {
            log.err("Hw uart wrong error");
            return;
        }
    }
    // Negatiivi 2: olemattomaan alueeseen sidottu askel hylätään.
    var bad_step = demoPlan();
    bad_step.steps[0].range_idx = 3;
    if (hw.generate(bad_step, desc)) |_| {
        log.err("Hw bad step accepted");
        return;
    } else |e| {
        if (e != error.StepOutOfRange) {
            log.err("Hw step wrong error");
            return;
        }
    }
    // Negatiivi 3: mittaus ennen viritystä hylätään (laite ei arvaa).
    if (hw.sensorRead(&sensor, hw.REG_TEMP)) |_| {
        log.err("Hw unready read accepted");
        return;
    } else |e| {
        if (e != error.NotReady) {
            log.err("Hw notready wrong error");
            return;
        }
    }
    // Negatiivi 4: väärä magia ei viritä (laite sietää, ei kaadu).
    hw.sensorWrite(&sensor, hw.REG_CTRL, 0x00) catch {
        log.err("Hw magic write failed");
        return;
    };
    if (hw.sensorRead(&sensor, hw.REG_TEMP)) |_| {
        log.err("Hw unarmed read accepted");
        return;
    } else |e| {
        if (e != error.NotReady) {
            log.err("Hw unarmed wrong error");
            return;
        }
    }
    // Negatiivi 5: kartan ulkopuoli + väärät suunnat hylätään syyllä.
    if (hw.sensorWrite(&sensor, 64, 1)) |_| {
        log.err("Hw oob write accepted");
        return;
    } else |e| {
        if (e != error.OutOfRange) {
            log.err("Hw oob wrong error");
            return;
        }
    }
    if (hw.sensorWrite(&sensor, hw.REG_ID, 1)) |_| {
        log.err("Hw readonly write accepted");
        return;
    } else |e| {
        if (e != error.ReadOnly) {
            log.err("Hw readonly wrong error");
            return;
        }
    }
    if (hw.sensorRead(&sensor, hw.REG_CTRL)) |_| {
        log.err("Hw writeonly read accepted");
        return;
    } else |e| {
        if (e != error.WriteOnly) {
            log.err("Hw writeonly wrong error");
            return;
        }
    }

    // Positiivi: generoi + sido (runko + laitekohtainen kartta).
    log.info("Generating driver...");
    if (!generateBind(demoPlan(), desc)) {
        log.err("Hw generate failed");
        return;
    }
    // Aja: init + luvut + odotusarvo (vastalauseen ydin).
    if (!execActive(&sensor, DEMO_BASE)) {
        log.err("Hw exec failed");
        _ = destroy();
        return;
    }
    // Mitattu arvo todennetaan ennen staattista serial-riviä (rehelliset tavut).
    const temp = hw.sensorRead(&sensor, hw.REG_TEMP) catch {
        log.err("Hw temp read failed");
        _ = destroy();
        return;
    };
    if (temp != hw.TEMP_TENTHS) {
        log.err("Hw temp mismatch");
        _ = destroy();
        return;
    }
    log.info("Driver active: temp=23.4C");

    // Negatiivi 6: väärä odotusarvo hylkää ajon (ei hiljaista ajautumista).
    // (Ajo suoraan ytimellä — aktiivinen tietue säilyy ehjänä.)
    var wrong = demoPlan();
    wrong.expect_value = 999;
    const wb = hw.generate(wrong, desc) catch {
        log.err("Hw wrong plan rejected early");
        _ = destroy();
        return;
    };
    var sensor2 = hw.FakeSensor.init();
    if (hw.execSequence(wb, &sensor2, DEMO_BASE)) {
        log.err("Hw wrong expect accepted");
        _ = destroy();
        return;
    }

    // Laite irtoaa: tila nollataan (STATUS putoaa, viritys raukeaa).
    hw.sensorReset(&sensor);
    const st = hw.sensorRead(&sensor, hw.REG_STATUS) catch {
        log.err("Hw status read failed");
        _ = destroy();
        return;
    };
    if (st != 0) {
        log.err("Hw detach dirty");
        _ = destroy();
        return;
    }
    log.info("Device detached");
    // Ajuri tuhoutuu: tietue tyhjenee, ei jäänteitä (NO_DRIVERS).
    if (!destroy()) {
        log.err("Hw destroy failed");
        return;
    }
    if (isActive()) {
        log.err("Hw destroy leaked");
        return;
    }
    log.info("Driver destroyed");
}
