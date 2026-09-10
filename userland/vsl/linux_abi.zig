//! VSL mini-Linux-ABI — Linux-numerot → Zinux-syscallit (VSL-1).
//!
//! **Vastuu**: Puhdas käännöstaulu ilman sivuvaikutuksia. Ei allokaatiota,
//!   ei `@import`:ia — freestanding-kelpoinen + host-testattava (sama kaava
//!   kuin `scope.zig` / `composer/task.zig`).
//! **Riippuvuudet**: ei (numerot kovakoodattu molemmista ABI:ista; vastaavuus
//!   pinnattu host-testillä `vsl_abi_test.zig`).
//! **Käytetään**: `userland/vsl/vsl_libc.zig` (shim), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Käännös elää käyttäjätilassa, ei kernelissä: kernel ei opettele Linuxia,
//!   VSL opettelee Zinuxia. Core pysyy puhtaana.
//! - Taulu on pyyntö, ei lupa: kernelin scope-valvonta (`manifest ∩ scope`)
//!   päättää silti jokaisen capin ja syscallin erikseen.
//! - Tuntematon numero → ENOSYS, ei hiljaista läpimenoa (informative failures).

// Linux x86_64 syscall-numerot (minimiosajoukko, VSL_SPEC.md §3).
// read — tiedostokuvaajan luku.
pub const LINUX_READ: u64 = 0;
// write — tiedostokuvaajan kirjoitus.
pub const LINUX_WRITE: u64 = 1;
// mmap — muistin kartoitus (vain anonyymi 1-sivu VSL-1:ssä).
pub const LINUX_MMAP: u64 = 9;
// brk — heap-rajan siirto (1 sivu/kutsu VSL-1:ssä).
pub const LINUX_BRK: u64 = 12;
// getpid — prosessitunniste.
pub const LINUX_GETPID: u64 = 39;
// exit — prosessin lopetus.
pub const LINUX_EXIT: u64 = 60;
// uname — järjestelmän nimi (VSL vastaa itse, ei kernel-kyselyä).
pub const LINUX_UNAME: u64 = 63;
// openat — tiedoston avaus (VSL-2, nyt ENOSYS-portti).
pub const LINUX_OPENAT: u64 = 257;

// Zinux-syscall-numerot (peili `libs/zinuxabi.zig`:stä — ei importia).
// sys_write(fd, buf, len).
pub const ZINUX_WRITE: u64 = 1;
// sys_exit(status).
pub const ZINUX_EXIT: u64 = 2;
// sys_getpid().
pub const ZINUX_GETPID: u64 = 3;
// sys_read(fd, buf, len).
pub const ZINUX_READ: u64 = 11;
// sys_mem_map(slot, addr, flags) — brk/mmap-tausta.
pub const ZINUX_MEM_MAP: u64 = 23;

// Virhekoodit (peili `libs/zinuxabi.zig`:stä).
// ENOSYS — tuntematon Linux-syscall VSL:ssä.
pub const ENOSYS: i64 = -38;
// EINVAL — virheellinen argumentti.
pub const EINVAL: i64 = -22;

// Käännä Linux-syscall-numero Zinux-numeroksi — null jos ei tuettu.
// Uname käsitellään VSL:n sisällä (palauttaa "VSL"), joten sillä ei ole
// Zinux-vastinetta: palauttaa null ja kutsuja vastaa itse.
pub fn linuxToZinux(linux_nr: u64) ?u64 {
    // Taulukko haku: pieni switch, ei silmukkaa.
    return switch (linux_nr) {
        // read → sys_read.
        LINUX_READ => ZINUX_READ,
        // write → sys_write.
        LINUX_WRITE => ZINUX_WRITE,
        // mmap → sys_mem_map (anonyymi 1-sivu).
        LINUX_MMAP => ZINUX_MEM_MAP,
        // brk → sys_mem_map (1 sivu/kutsu).
        LINUX_BRK => ZINUX_MEM_MAP,
        // getpid → sys_getpid.
        LINUX_GETPID => ZINUX_GETPID,
        // exit → sys_exit.
        LINUX_EXIT => ZINUX_EXIT,
        // uname/openat/tuntemattomat: ei suoraa vastinetta.
        else => null,
    };
}

// Onko Linux-syscall VSL:n sisäisesti käsittelemä (ei kernel-kutsua)?
// VSL-1:ssä vain uname ("VSL"-vastaus ilman kernel-kyselyä).
pub fn isHandledInternally(linux_nr: u64) bool {
    // Uname vastataan VSL:n sisällä.
    return linux_nr == LINUX_UNAME;
}

// Tarvitseeko Linux-syscall memory-capabilityn (MAP-oikeus)?
// brk/mmap varaavat sivuja — ilman memory-cappia kutsu on EPERM scopessa.
pub fn needsMemoryCap(linux_nr: u64) bool {
    // brk ja mmap kartoittavat muistia.
    return linux_nr == LINUX_BRK or linux_nr == LINUX_MMAP;
}
