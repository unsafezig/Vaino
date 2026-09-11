//! VSL file-I/O userland-demo — open/read/close ring 3:ssa shimmin kautta.
//!
//! **Vastuu**: Avaa /tmp/welcome `vslOpenFile`:lla, lue sisältö
//!   `vslReadFile`:lla, tulosta luetut tavut serialiin (sarjamerkki
//!   `vsl-file: TMPFS` todistaa että ring-3 luki oikean tiedoston),
//!   EOF + tuplasulku-negatiivit, siisti sulku + paluu kerneliin.
//! **Riippuvuudet**: `vsl_libc` (shim), `vsl_fd` (taulukko), `syscall.zig`
//!   (test_return — kehitysputki, ei Linux-ABI:a)
//! **Käytetään**: start.S → vslFileMain

// Tuo VSL libc-shim — open/read/close + write-tulostus.
const libc = @import("vsl_libc");
// Tuo fd-taulu — kertalustustus ennen avauksia.
const fd = @import("vsl_fd");
// Tuo test_return-paluu.
const sc = @import("syscall.zig");

// Odotettu /tmp/welcome-sisältö (tmpfs.init-seed, ks. vsl_fs_syscall).
const EXPECTED = "TMPFS";

// Tulosta viesti stdout:iin (fd 1 = UART) shimmin write-polulla.
fn print(msg: []const u8) void {
    // Paluu ohitetaan (boot-demo; virhe näkyisi puuttuvana sarjana).
    _ = libc.vslWrite(1, msg);
}

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

// File-I/O-demon sisäänkäynti — start.S kutsuu tätä.
export fn vslFileMain() void {
    // Alusta fd-taulukko kerran (konsolit 0..2 varattu).
    fd.initTable();
    // Avaa /tmp/welcome tiedostokuvaajaksi (fd ≥ 3) shimmin kautta.
    const opened = libc.vslOpenFile("/tmp/welcome");
    // Avaus epäonnistui.
    if (opened < 0) {
        // Virhe serialiin + paluu.
        print("vsl open failed\n");
        sc.sysTestReturn();
    }
    // fd-numero u32:na (ei-negatiivinen haara).
    const f: u32 = @intCast(opened);
    // Lukupuskuri pinossa.
    var buf: [32]u8 = undefined;
    // Lue alusta (offset-kirjanpito shimissä).
    const got = libc.vslReadFile(f, &buf);
    // Luku epäonnistui tai väärä määrä (odota 5).
    if (got != EXPECTED.len) {
        // Virhe serialiin + paluu.
        print("vsl read len wrong\n");
        sc.sysTestReturn();
    }
    // Varmista sisältö tavu kerrallaan.
    if (!eql(buf[0..EXPECTED.len], EXPECTED)) {
        // Sisältövirhe.
        print("vsl read content mismatch\n");
        sc.sysTestReturn();
    }
    // Tulosta LUETUT tavut (ei vakiota — sarjamerkki todistaa ring-3-luvun).
    print("vsl-file: ");
    print(buf[0..EXPECTED.len]);
    print("\n");
    // EOF: toinen luku samalla offsetilla → 0 tavua.
    const eof = libc.vslReadFile(f, &buf);
    // Ei nollaa → offset-etenemä rikki.
    if (eof != 0) {
        // Virhe serialiin + paluu.
        print("vsl eof not zero\n");
        sc.sysTestReturn();
    }
    // Sulje kuvaaja (0 odotettu).
    const closed = libc.vslCloseFile(f);
    // Sulku epäonnistui.
    if (closed != 0) {
        // Virhe serialiin + paluu.
        print("vsl close failed\n");
        sc.sysTestReturn();
    }
    // Tuplasulku → EBADF (-9) samalla fd:llä.
    const twice = libc.vslCloseFile(f);
    // Ei EBADF → sulkusemantiikka rikki.
    if (twice != -9) {
        // Virhe serialiin + paluu.
        print("vsl double close not EBADF\n");
        sc.sysTestReturn();
    }
    // Vahvistus serialiin ennen paluuta.
    print("userland vsl file OK\n");
    // Palaa kerneliin — kernel lokittaa "VSL file IO OK".
    sc.sysTestReturn();
}

// Pakota linkittäjän säilyttämään vslFileMain.
pub export fn vslFileAnchor() void {}
