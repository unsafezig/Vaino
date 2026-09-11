//! Linux-trap-ydin — Linux-numerot → Zinux-numerot (VSL-4B, puhdas).
//!
//! **Vastuu**: Puhdas käännöstaulu trap-polulle: Linux-syscall-numero →
//!   Zinux-numero, sisäinen uname-käsittely tai unsupported-tunniste.
//!   Päätös, ei mekanismia — `dispatch.zig` (from-frame) suorittaa.
//! **Riippuvuudet**: ei (numerot kovakoodattu molemmista ABI:ista;
//!   vastaavuus `userland/vsl/linux_abi.zig`:iin pinnattu host-testillä).
//! **Käytetään**: `kernel/syscall/dispatch.zig` (trap-haara), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Käännös on pyyntö-tasoa: argumentit (RDI..R9) kulkevat sellaisenaan —
//!   x86_64 Linux-syscall-konventio on identtinen Zinuxin kanssa (R10
//!   neljäntenä). Vain RAX käännetään; kernel ei opettele Linuxia.
//! - Tuntematon numero → unsupported → trap palauttaa -ENOSYS user-tilaan
//!   (ei haltia, ei hiljaista läpimenoa). Signaalit/fork rajautuvat tähän
//!   ensimmäisessä kokeessa (VSL_SPEC §11).
//! - read(0) kääntyy konsoli-readiin (11); tiedosto-fd:t (≥3) vaativat
//!   trap-fd-taulun (4B.x-jatko, dokumentoitu raja — ei arvailua tässä).

// Linux x86_64 syscall-numerot (minimiosajoukko, VSL_SPEC.md §3).
pub const LINUX_READ: u64 = 0;
pub const LINUX_WRITE: u64 = 1;
pub const LINUX_CLOSE: u64 = 3;
pub const LINUX_MMAP: u64 = 9;
pub const LINUX_BRK: u64 = 12;
pub const LINUX_GETPID: u64 = 39;
pub const LINUX_EXIT: u64 = 60;
pub const LINUX_UNAME: u64 = 63;
pub const LINUX_OPENAT: u64 = 257;

// Zinux-vastineet (peili `libs/zinuxabi.zig`:stä — ei importia).
pub const ZINUX_WRITE: u64 = 1;
pub const ZINUX_EXIT: u64 = 2;
pub const ZINUX_GETPID: u64 = 3;
pub const ZINUX_READ: u64 = 11;
pub const ZINUX_MEM_MAP: u64 = 23;
pub const ZINUX_VFS_OPEN: u64 = 29;
pub const ZINUX_VFS_CLOSE: u64 = 31;

// Emuloidun unamen tavusisältö ("VSL 0.1" — yksi lähde trapille).
pub const UNAME_BYTES: []const u8 = "VSL 0.1";

// Trap-kehyksen rekisterijärjestys `trap_regs`:ssä (SyscallFrame-kentät).
pub const REG_RAX: usize = 0;
pub const REG_RDI: usize = 1;
pub const REG_RSI: usize = 2;
pub const REG_RDX: usize = 3;
pub const REG_R10: usize = 4;
pub const REG_R8: usize = 5;
pub const REG_R9: usize = 6;
pub const REG_RCX: usize = 7;
pub const REG_RIP: usize = 8;
pub const REG_RFLAGS: usize = 9;

// Käännöksen tulos — yksi syy kerrallaan (vastalause nimeää vian).
pub const TrapAction = union(enum) {
    // Suora Zinux-numero dispatchiin (argumentit sellaisenaan).
    zinux: u64,
    // Sisäinen uname-emulaatio (kirjoita UNAME_BYTES user-puskuriin).
    internal_uname,
    // Ei vastinetta → -ENOSYS user-tilaan (signaalit/fork/tuntemattomat).
    unsupported,
};

// Käännä Linux-numero trap-toiminnoksi — puhdas switch, ei silmukkaa.
pub fn translate(linux_nr: u64) TrapAction {
    return switch (linux_nr) {
        // read → konsoli-read (tiedosto-fd:t vaativat 4B.x-taulun).
        LINUX_READ => .{ .zinux = ZINUX_READ },
        // write → sys_write.
        LINUX_WRITE => .{ .zinux = ZINUX_WRITE },
        // close → sys_vfs_close.
        LINUX_CLOSE => .{ .zinux = ZINUX_VFS_CLOSE },
        // mmap/brk → sys_mem_map.
        LINUX_MMAP => .{ .zinux = ZINUX_MEM_MAP },
        LINUX_BRK => .{ .zinux = ZINUX_MEM_MAP },
        // getpid → sys_getpid.
        LINUX_GETPID => .{ .zinux = ZINUX_GETPID },
        // exit → sys_exit.
        LINUX_EXIT => .{ .zinux = ZINUX_EXIT },
        // uname → sisäinen emulaatio (ei kernel-kyselyä).
        LINUX_UNAME => .internal_uname,
        // openat → sys_vfs_open.
        LINUX_OPENAT => .{ .zinux = ZINUX_VFS_OPEN },
        // Kaikki muu (signaalit/fork/tuntemattomat) → ENOSYS-portti.
        else => .unsupported,
    };
}
