//! VSL libc-shim — mini-Linux-ABI ring-3-kutsut (VSL-1).
//!
//! **Vastuu**: Tarjoa `vsl_write/exit/getpid/uname`-funktiot VSL-pluginin
//!   sisäiseen käyttöön. Kääntää Linux-semantiikan Zinux-syscalleiksi
//!   `linux_abi`-taulun kautta; uname vastataan paikallisesti.
//! **Riippuvuudet**: `linux_abi.zig` (puhdas taulu — sama instanssi kuin
//!   host-testeissä, ks. build.zig).
//! **Käytetään**: VSL-plugin ELF (tuleva vsl_test-ajo), host-testit.
//!
//! ## Arkkitehtuurihuomiot
//! - Shim on VSL:n omaa koodia, ei kernel-ABI:n laajennus: kernel näkee vain
//!   tavallisia Zinux-syscalleja (1/2/3/11). Linux-numerot eivät vuoda kerneliin.
//! - SYSCALL-inline-asm on freestanding-kelpoista; host-testeissä kutsutaan
//!   vain puhtaita luokittelijoita (`classifyReturn`), ei itse `syscall`:ia.

 // Tuo puhdas ABI-taulu — käännös + sisäinen-käsittely-liput.
const abi = @import("linux_abi");

// Uname-vastauksen merkkijono — VSL esittäytyy itse, ei kernel-kyselyä.
pub const UNAME_SYSNAME: []const u8 = "VSL";
// Uname-vastauksen toinen kenttä (release-paikkamerkki VSL-1:ssä).
pub const UNAME_RELEASE: []const u8 = "0.1";

// Shim-virheet (Zinux-tyyliin negatiivisina paluuarvoina).
// ENOSYS — Linux-syscall ei tuettu VSL:ssä.
pub const ENOSYS: i64 = -38;

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
pub fn vslWrite(fd: u64, buf: []const u8) i64 {
    // Välitä suoraan Zinux-writeen (sama fd-semantiikka VSL-1:ssä).
    return zinuxSyscall(abi.ZINUX_WRITE, fd, @intFromPtr(buf.ptr), buf.len);
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
