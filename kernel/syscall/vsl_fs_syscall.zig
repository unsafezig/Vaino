//! VSL fs boot-testi — tallennuspolku `ls/cat/write` kernel-puolella (VSL-2).
//!
//! **Vastuu**: Todista VFS+tmpfs-polku jota VSL-shell käyttää: listaa /tmp,
//!   lue /tmp/welcome (`vsl-cat`), kirjoita+lue takaisin (`VSL fs OK`).
//!   Itse-contained: alustaa VFS+tmpfs itse, ei sotke muiden testien tauluja.
//! **Riippuvuudet**: `../fs/vfs.zig`, `../fs/tmpfs.zig`, log
//! **Käytetään**: `kernel/boot_tests.zig` (VSL-stub-testin jälkeen)
//!
//! ## Arkkitehtuurihuomiot
//! - Ring-3:sta ei vielä ole fd-syscalleja (fd.zig `isIoReady(file)==false`
//!   sanoo sen rehellisesti), joten suoritus elää tässä boot-polussa —
//!   pyyntö (shell-parse) ja lupa/suoritus (VFS) pysyvät erillään.
//! - Negatiivi ensin: tuntematon polku → NotFound, jotta testi todistaa
//!   hylkäyspolunkin eikä vain onnellista päivää.

// Tuo VFS — open/read/write/close kahvoilla.
const vfs = @import("../fs/vfs.zig");
// Tuo tmpfs — init/mount + lista-API shellille.
const tmpfs = @import("../fs/tmpfs.zig");
// Tuo lokitus boot-viesteihin (sarja on VSL-2:n mitta).
const log = @import("../lib/log.zig");

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

// Boot-testi — ls + cat + write/readback VFS-polulla.
pub fn runBootTest() void {
    // Alusta VFS puhtaaksi (oma taulu, ei sotke aiempia testejä).
    vfs.init();
    // Alusta tmpfs + /welcome-tiedosto.
    tmpfs.init();
    // Mount /tmp.
    tmpfs.registerMount() catch {
        // Mount epäonnistui.
        log.err("VSL fs mount failed");
        // Lopeta testi.
        return;
    };
    // --- Negatiivi: tuntematon polku → NotFound (vastalause toimii). ---
    if (vfs.open("/tmp/missing")) |h| {
        // Avaus onnistui vaikka ei pitänyt — sulje ja hylkää testi.
        vfs.close(h);
        log.err("VSL fs missing not NotFound");
        return;
    } else |_| {
        // Odotettu hylkäys — jatkuu.
    }
    // --- ls: listaa /tmp ja varmista /welcome löytyy. ---
    var found_welcome = false;
    // Käy tmpfs-taulukko (MAX_FILES=8 slotia).
    var i: usize = 0;
    while (i < tmpfs.MAX_FILES) : (i += 1) {
        // Nimi tai null (vapaa slotti).
        if (tmpfs.fileNameAt(i)) |name| {
            // Täsmääkö /welcome?
            if (eql(name, "/welcome")) found_welcome = true;
        }
    }
    if (!found_welcome) {
        // /welcome puuttuu listauksesta.
        log.err("VSL ls missing welcome");
        return;
    }
    // Listaus OK — shellin `ls /tmp` näkee tiedoston.
    log.info("vsl-ls: welcome");
    // --- cat: lue /tmp/welcome, odota "TMPFS". ---
    const h = vfs.open("/tmp/welcome") catch {
        // Avaus epäonnistui.
        log.err("VSL cat open failed");
        return;
    };
    // Puskuri luettavalle datalle.
    var buf: [32]u8 = undefined;
    // Lue alusta.
    const n = vfs.read(h, &buf, 0) catch {
        // Luku epäonnistui.
        log.err("VSL cat read failed");
        // Sulje kahva ennen poistumista.
        vfs.close(h);
        return;
    };
    // Sulje kahva.
    vfs.close(h);
    // Varmista sisältö "TMPFS".
    if (!eql(buf[0..n], "TMPFS")) {
        // Väärä sisältö.
        log.err("VSL cat content mismatch");
        return;
    }
    // Cat OK — shellin `cat /tmp/welcome` tulostaa TMPFS.
    log.info("vsl-cat: TMPFS");
    // --- write: luo /vsl-note, kirjoita, lue takaisin. ---
    tmpfs.addFile("/vsl-note", "hello") catch {
        // Luonti epäonnistui.
        log.err("VSL write create failed");
        return;
    };
    // Avaa kirjoitukseen.
    const wh = vfs.open("/tmp/vsl-note") catch {
        // Avaus epäonnistui.
        log.err("VSL write open failed");
        return;
    };
    // Jatka loppua offsetista 5.
    const wn = vfs.write(wh, "-vsl", 5) catch {
        // Kirjoitus epäonnistui.
        log.err("VSL write failed");
        // Sulje kahva ennen poistumista.
        vfs.close(wh);
        return;
    };
    // Sulje kirjoituskahva.
    vfs.close(wh);
    // Odotettu 4 tavua.
    if (wn != 4) {
        // Väärä kirjoitusmäärä.
        log.err("VSL write length mismatch");
        return;
    }
    // Avaa lukua varten uudelleen.
    const rh = vfs.open("/tmp/vsl-note") catch {
        // Avaus epäonnistui.
        log.err("VSL write reopen failed");
        return;
    };
    // Puskuri takaisinluettavalle.
    var rbuf: [32]u8 = undefined;
    // Lue kaikki.
    const rn = vfs.read(rh, &rbuf, 0) catch {
        // Luku epäonnistui.
        log.err("VSL write readback failed");
        // Sulje kahva ennen poistumista.
        vfs.close(rh);
        return;
    };
    // Sulje lukukahva.
    vfs.close(rh);
    // Varmista "hello-vsl" (9 tavua).
    if (!eql(rbuf[0..rn], "hello-vsl")) {
        // Takaisinluku ei täsmää.
        log.err("VSL write readback mismatch");
        return;
    }
    // Kirjoitus + takaisinluku OK.
    log.info("VSL fs OK");
}
