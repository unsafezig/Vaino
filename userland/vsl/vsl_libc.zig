//! VSL libc-shim — mini-Linux-ABI ring-3-kutsut (VSL-1 + VSL-4A fd-I/O).
//!
//! **Vastuu**: Tarjoa `vsl_write/exit/getpid/uname`-funktiot sekä VSL-4A:ssa
//!   `vsl_open/read/close`-tiedostopolun VSL-pluginin sisäiseen käyttöön.
//!   Kääntää Linux-semantiikan Zinux-syscalleiksi `linux_abi`-taulun kautta;
//!   uname vastataan paikallisesti, tiedostot reititetään fd-kindin mukaan.
//! **Riippuvuudet**: `linux_abi.zig` (puhdas taulu), `fd.zig` (fd-reititys)
//!   — sama instanssijako kuin host-testeissä, ks. build.zig.
//! **Käytetään**: VSL-plugin ELF, `vsl_file_test`-demo, host-testit.
//!
//! ## Arkkitehtuurihuomiot
//! - Shim on VSL:n omaa koodia, ei kernel-ABI:n laajennus: kernel näkee vain
//!   tavallisia Zinux-syscalleja (1/2/3/11/29/30/31). Linux-numerot eivät vuoda kerneliin.
//! - SYSCALL-inline-asm on freestanding-kelpoista; host-testeissä kutsutaan
//!   vain puhtaita luokittelijoita (`classifyReturn`, fd-virhemäppäys) ja
//!   syscallittomia polkuja (konsoli-noop, sitomaton file), ei itse `syscall`:ia.
//! - Neljäs argumentti (offset) kulkee R10:ssä — Linux-syscall-konventio ja
//!   kernelin `sys_plugin_transfer`-kaava (CPU ylikirjoittaa RCX:n).

// Tuo puhdas ABI-taulu — käännös + sisäinen-käsittely-liput.
const abi = @import("linux_abi");
// Tuo fd-taulu — kind-reititys + offset-kirjanpito (VSL-4A).
const fd = @import("vsl_fd");

// Uname-vastauksen merkkijono — VSL esittäytyy itse, ei kernel-kyselyä.
pub const UNAME_SYSNAME: []const u8 = "VSL";
// Uname-vastauksen toinen kenttä (release-paikkamerkki VSL-1:ssä).
pub const UNAME_RELEASE: []const u8 = "0.1";

// Shim-virheet (Zinux-tyyliin negatiivisina paluuarvoina).
// ENOSYS — Linux-syscall ei tuettu VSL:ssä.
pub const ENOSYS: i64 = -38;
// EBADF — huono fd/kahva (fd-taulu tai kernel).
pub const EBADF: i64 = -9;
// EINVAL — virheellinen polku/argumentti (fd-taulu).
pub const EINVAL: i64 = -22;
// ENOMEM — fd-taulu täynnä.
pub const ENOMEM: i64 = -12;

// Luokittele raaka Zinux-syscall-paluu VSL-virheeksi — null = onnistui.
// Puhdas funktio: host-testattava ilman laitteistoa.
pub fn classifyReturn(ret: i64) ?i64 {
    // Nolla tai positiivinen = onnistuminen, ei virhettä.
    if (ret >= 0) return null;
    // Negatiivinen kulkee läpi sellaisenaan (kernelin virhe).
    return ret;
}

// Onko Linux-numero tuettu VSL-shimmin kautta (suora käännös tai sisäinen)?
// Puhdas predikaatti: yhdistää `linuxToZinux` + `isHandledInternally`.
pub fn isSupported(linux_nr: u64) bool {
    // Suora Zinux-vastine olemassa → tuettu.
    if (abi.linuxToZinux(linux_nr) != null) return true;
    // Sisäisesti käsitelty (uname) → tuettu ilman kernel-kutsua.
    return abi.isHandledInternally(linux_nr);
}

// Kopioi uname-vastaus kutsujan puskuriin — palauttaa kirjoitetut tavut.
// Puhdas kopio ilman syscalleja: VSL vastaa itse (VSL_SPEC.md §3).
pub fn unameCopy(out: []u8) usize {
    // Lähteenä "VSL 0.1" — yhdistetty kahdesta vakiosta välilyönnillä.
    const sys = UNAME_SYSNAME;
    // Toinen kenttä.
    const rel = UNAME_RELEASE;
    // Yhteispituus + välilyönti.
    const total = sys.len + 1 + rel.len;
    // Liian pieni puskuri → katkaistaan (ei virhettä VSL-1:ssä).
    var n: usize = total;
    // Rajaa puskurin kokoon.
    if (n > out.len) n = out.len;
    // Kopioi tavu kerrallaan ilman std:tä (freestanding).
    var i: usize = 0;
    // Käy kohdepuskuri.
    while (i < n) : (i += 1) {
        // Ensimmäinen osa: sysname.
        if (i < sys.len) {
            // Kopioi sysname-tavu.
            out[i] = sys[i];
        } else if (i == sys.len) {
            // Erotin välilyönti.
            out[i] = ' ';
        } else {
            // Loppuosa: release.
            out[i] = rel[i - sys.len - 1];
        }
        // Katkaistu kopio saattaa päättyä keskelle — katkaise silmukka
        // kun kohde täyttyy (yläraja jo n:ssä).
        if (i + 1 >= n) break;
    }
    // Palauta kirjoitettu määrä.
    return n;
}

// Suorita Zinux-syscall raakana (freestanding ring-3, x86_64 SYSCALL).
// RDI/RSI/RDX-argumentit, paluu RAX:ssa (negatiivinen = virhe).
fn zinuxSyscall(nr: u64, a1: u64, a2: u64, a3: u64) i64 {
    // SYSCALL tuhoaa RCX/R11 — clobber-rakenne Zig 0.16 -tyylillä.
    return asm volatile ("syscall"
        // Tulos RAX:ssa (i64-tulkinta).
        : [ret] "={rax}" (-> i64),
          // Syötteet: numero + 3 argumenttia.
        : [nr] "{rax}" (nr),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          // CPU ylikirjoittaa RCX (paluu-RIP) + R11 (RFLAGS) + muistin.
        : .{ .rcx = true, .r11 = true, .memory = true });
}

// vsl_write(fd, buf) — Linux write(1) → Zinux SYS_write(1).
// Palauttaa kirjoitetut tavut tai negatiivisen virheen.
pub fn vslWrite(fdnum: u64, buf: []const u8) i64 {
    // Välitä suoraan Zinux-writeen (sama fd-semantiikka VSL-1:ssä).
    return zinuxSyscall(abi.ZINUX_WRITE, fdnum, @intFromPtr(buf.ptr), buf.len);
}

// vsl_exit(status) — Linux exit(60) → Zinux SYS_exit(2). Ei palaa.
pub fn vslExit(status: u64) noreturn {
    // Lopeta prosessi kernelissä.
    _ = zinuxSyscall(abi.ZINUX_EXIT, status, 0, 0);
    // Ei paluuta — loukku jos kernel palaa.
    unreachable;
}

// vsl_getpid() — Linux getpid(39) → Zinux SYS_getpid(3).
pub fn vslGetpid() i64 {
    // Ei argumentteja.
    return zinuxSyscall(abi.ZINUX_GETPID, 0, 0, 0);
}

// Suorita Zinux-syscall neljällä argumentilla (4. R10:ssä).
// VSL-4A:n `sys_vfs_read(handle, buf, len, offset)` tarvitsee offsetin —
// R10 on Linux-konvention 4. argumenttirekisteri (RCX on varattu paluulle).
fn zinuxSyscall4(nr: u64, a1: u64, a2: u64, a3: u64, a4: u64) i64 {
    // SYSCALL tuhoaa RCX/R11 — clobber-rakenne Zig 0.16 -tyylillä.
    return asm volatile ("syscall"
        // Tulos RAX:ssa (i64-tulkinta).
        : [ret] "={rax}" (-> i64),
          // Syötteet: numero + 4 argumenttia (R10 neljäntenä).
        : [nr] "{rax}" (nr),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          // CPU ylikirjoittaa RCX (paluu-RIP) + R11 (RFLAGS) + muistin.
        : .{ .rcx = true, .r11 = true, .memory = true });
}

// vsl_open(path) — Linux openat(257) → Zinux SYS_vfs_open(29).
// Palauttaa kernel-kahvan (≥0) tai negatiivisen virheen.
pub fn vslOpen(path: []const u8) i64 {
    // Read-only-liput (0) — kirjoitus avataan VSL-4B:ssä.
    return zinuxSyscall(abi.ZINUX_VFS_OPEN, @intFromPtr(path.ptr), path.len, 0);
}

// vsl_read_at(handle, buf, offset) — Zinux SYS_vfs_read(30).
// Palauttaa tavut tai negatiivisen virheen.
pub fn vslReadAt(handle: u32, buf: []u8, offset: u64) i64 {
    // Neljäs argumentti (offset) R10:ssä.
    return zinuxSyscall4(abi.ZINUX_VFS_READ, handle, @intFromPtr(buf.ptr), buf.len, offset);
}

// vsl_close(handle) — Linux close(3) → Zinux SYS_vfs_close(31).
// Palauttaa 0 tai negatiivisen virheen.
pub fn vslClose(handle: u32) i64 {
    // Ei lisäargumentteja.
    return zinuxSyscall(abi.ZINUX_VFS_CLOSE, handle, 0, 0);
}

// Kuvaa fd-taulun virhe negatiiviseksi errnoiksi (shimmin paluukonventio).
// Puhdas mäppäys — host-testattava ilman syscalleja.
pub fn fdErrToNeg(err: fd.FdError) i64 {
    return switch (err) {
        // Huono fd/kind — EBADF.
        fd.FdError.BadFd => EBADF,
        // Huono polku — EINVAL.
        fd.FdError.BadPath => EINVAL,
        // Taulukko täynnä — ENOMEM.
        fd.FdError.TooManyOpen => ENOMEM,
        // Väärä kind kerrokselle — ENOSYS (putki ilman porttisidontaa).
        fd.FdError.NotSupported => ENOSYS,
    };
}

// vsl_open_file(path) — fd-taulu + kernel-avaus yhdessä (VSL-4A polku).
// Palauttaa fd-numeron (≥3) tai negatiivisen virheen. Kutsuja alustaa
// taulukon kerran (`fd.initTable`); tämä ei nollaa sitä.
pub fn vslOpenFile(path: []const u8) i64 {
    // Varaa file-slotti taulukosta (polkuvalidointi mukana).
    const fdnum = fd.openFile(path) catch |err| return fdErrToNeg(err);
    // Avaa kernelissä (kahva sidontaa varten).
    const ret = vslOpen(path);
    // Kernel hylkäsi — vapauta slotti, palauta virhe.
    if (ret < 0) {
        // Slotin vapautus ei voi epäonnistua tässä (juuri varattu).
        fd.closeFd(fdnum) catch {};
        return ret;
    }
    // Sido kahva (file-kind aina — openFile takaa).
    fd.bindHandle(fdnum, @intCast(ret)) catch |err| {
        // Sidonta petti — vapauta slotti, virhe kutsujalle.
        fd.closeFd(fdnum) catch {};
        return fdErrToNeg(err);
    };
    // Palauta fd-numero.
    return fdnum;
}

// vsl_read_file(fd, buf) — lue kuvaajasta offset-kirjanpidolla.
// Konsoli → sys_read(11); file → sys_vfs_read(30) sidotulla kahvalla;
// putki/sitomaton → virhe ilman syscalleja. Palauttaa tavut tai negatiivisen.
pub fn vslReadFile(fdnum: u32, buf: []u8) i64 {
    // Kind ratkaisee reitityksen (BadFd kulkee läpi).
    const k = fd.kindOf(fdnum) catch |err| return fdErrToNeg(err);
    return switch (k) {
        // Konsoli-luku kernelin stdin-polulla.
        .console => zinuxSyscall(abi.ZINUX_READ, fdnum, @intFromPtr(buf.ptr), buf.len),
        // Tiedosto-luku sidotulla kahvalla + offset-etenemä.
        .file => {
            // Kahva taulukosta (INVALID = kernel-avaus tekemättä).
            const h = fd.handleOf(fdnum) catch |err| return fdErrToNeg(err);
            // Sitomaton ei lue (ei valehtelua tuesta).
            if (h == fd.INVALID_HANDLE) return EBADF;
            // Offset kirjanpidosta (sequential read -semantiikka).
            const off = fd.tableOffset(fdnum) catch |err| return fdErrToNeg(err);
            // Lue kernelistä.
            const ret = vslReadAt(h, buf, off);
            // Onnistunut luku siirtää offsettia (0 = EOF, ei siirtoa).
            if (ret > 0) {
                // Etenemä ei voi epäonnistua tässä (fd tarkistettu).
                fd.advanceOffset(fdnum, @intCast(ret)) catch {};
            }
            return ret;
        },
        // Putki ilman sidontaa — ei vielä.
        .pipe => ENOSYS,
    };
}

// vsl_close_file(fd) — sulje kuvaaja + kernel-kahva.
// Konsoli-noop (Linux-pariteetti), file sulkee molemmat kerrokset.
// Palauttaa 0 tai negatiivisen virheen.
pub fn vslCloseFile(fdnum: u32) i64 {
    // Kind ratkaisee (BadFd kulkee läpi).
    const k = fd.kindOf(fdnum) catch |err| return fdErrToNeg(err);
    return switch (k) {
        // Konsoli pysyy auki — no-op onnistuu.
        .console => 0,
        // Tiedosto: kernel-kahva kiinni (jos sidottu) + slotti vapaaksi.
        .file => {
            // Kahva taulukosta.
            const h = fd.handleOf(fdnum) catch |err| return fdErrToNeg(err);
            // Sidottu → syscall-sulku (virhe kulkee, slotti vapautetaan silti).
            if (h != fd.INVALID_HANDLE) {
                // Syscall-paluu talteen.
                const ret = vslClose(h);
                // Vapauta slotti joka tapauksessa (ei vuotoa virhepolullakaan).
                fd.closeFd(fdnum) catch {};
                return ret;
            }
            // Sitomaton → pelkkä slotin vapautus.
            fd.closeFd(fdnum) catch |err| return fdErrToNeg(err);
            return 0;
        },
        // Putki ilman sidontaa — ei vielä.
        .pipe => ENOSYS,
    };
}
