//! Semihosting-exit ARM64-guestille (QEMU `virt` testilopetus).
//!
//! **Vastuu**: Pysäytä QEMU siististi kun boot-testi on valmis.
//! Vastaa x86_64:n isa-debug-exit -laitetta (lib/qemu_exit.zig).
//! **Riippuvuudet**: ei
//! **Käytetään**: `main.zig` (smoke-boot)
//!
//! Vaatii QEMU-liput: `-semihosting-config enable=on,target=native`.
//! Ilman niitä HLT 0xF000 aiheuttaa poikkeuksen — kutsu vain kun
//! semihosting on päällä (aarch64-run-askel huolehtii).

// Semihosting SYS_EXIT -numero (A64: HLT 0xF000, x0 = 0x18).
pub const SYS_EXIT: u64 = 0x18;
// ADP_Stopped_ApplicationExit: puhdas sovellustason lopetus (exit-koodi
// lohkon toisessa sanassa — kaikki muu on exit(1)).
pub const ADP_EXIT: u64 = 0x20026;

// PSCI SYSTEM_OFF -funktiotunniste (SMC32, ARM DEN 0022).
// `virt`-kone sammuttaa QEMU:n (exit 0) ilman semihosting-riippuvuutta.
pub const PSCI_SYSTEM_OFF: u64 = 0x8400_0008;

// Semihosting SYS_WRITE0 -numero: tulosta NUL-päätteinen merkkijono
// QEMU:n stdoutiin (x1 = osoite guest-muistissa). Diagnostiikka-apu:
// tällä testataan osoitinvälitys ilman lopetussivuvaikutusta.
pub const SYS_WRITE0: u64 = 0x04;

// Semihosting SYS_TIME: hostin unix-aika sekunteina (x0:ssa paluu).
// Vain desktop-shim: Androidilla wall-aika tulee HOST_TIME_SYNC-opilla
// (HOST_PROTOCOL.md), ei semihostingilla.
pub const SYS_TIME: u64 = 0x11;

/// Hostin seinäkello (sekuntia epochista). Toimii EL1:ssä kuten exit().
pub fn wallTime() u64 {
    const secs: u64 = asm volatile ("hlt 0xF000"
        : [secs] "={x0}" (-> u64),
        : [nr] "{x0}" (SYS_TIME),
        : .{ .memory = true });
    return secs;
}

// Pysäytä QEMU annetulla koodilla — ei palaa.
// QEMU poistuu samalla koodilla (0 = smoke OK).
//
// A64-ABI (QEMU semihosting/arm-compat-semi.c, v2.0-speksi): SYS_EXIT
// ottaa PARAMETRILOHKON — x1 on osoite kahteen u64-sanaan guest-muistissa:
//   [0] = syy (ADP_EXIT), [1] = exit-koodi.
// MMU on pois, joten staattisen lohkon linkkiosoite käy sellaisenaan.
//
// TOTEUTUSVAATIMUS (debugattu): lohko on staattinen ja status kirjoitetaan
// YHDELLÄ skalaaritallennuksella. Pinotaulukon `.{ ADP_EXIT, code }`
// -alustaja sai LLVM:n kopioimaan 16 tavua Q0:lla (`ldr q0`/`str q0`),
// mikä loukkuuntuu Undefined Instructioniin koska FP/NEON on pois päältä
// (CPACR_EL1.FPEN=0 — sama linja kuin x86_64:n ei-SSE-käytäntö).
// Staattinen parametriohko. Molemmat sanat kirjoitetaan ajonaikana
// (boot.S nollaa vain .bss:n — .data:n latauskuvaa ei kopioida).
var exit_block: [2]u64 = .{ 0, 0 };

pub fn exit(code: u64) noreturn {
    // Kaksi VOLATILE-skalaaritallennusta — volatile estää LLVM:ää
    // yhdistämästä niitä yhdeksi Q0-tallennukseksi (ei SIMD:iä,
    // ei FP-riippuvuutta, ei riippuvuutta .data-alustuksesta).
    const blk: *volatile [2]u64 = &exit_block;
    blk[0] = ADP_EXIT;
    blk[1] = code;
    // x0 = SYS_EXIT, x1 = lohkon osoite; HLT 0xF000.
    asm volatile ("hlt 0xF000"
        :
        : [nr] "{x0}" (SYS_EXIT),
          [block] "{x1}" (&exit_block),
        : .{ .memory = true });
    // Jos semihosting puuttuu ja HLT palautuu/poikkeuttaa, jäädytä.
    while (true) {
        asm volatile ("wfi" ::: .{ .memory = true });
    }
}

// Tulosta merkkijono semihosting-konsoliin. Kutsujan merkkijonon on
// oltava NUL-päätteinen (QEMU lukee tavuja kunnes NUL).
pub fn write0(msg: [*:0]const u8) void {
    // x0 = SYS_WRITE0, x1 = merkkijonon osoite; HLT 0xF000.
    asm volatile ("hlt 0xF000"
        :
        : [nr] "{x0}" (SYS_WRITE0),
          [str] "{x1}" (msg),
        : .{ .memory = true });
}

// Sammuta guest PSCI:llä — QEMU poistuu koodilla 0.
// HUOM: ei toimi EL1:stä ilman EL3:a (SMC loukkuuntuu) — säilytetty
// tulevaa EL3/EL2-shimmiä varten; smoke-lopetus käyttää exit():iä.
pub fn poweroff() noreturn {
    // x0 = PSCI_SYSTEM_OFF; SMC #0 raakakoodina (.inst 0xd4000000) —
    // LLVM:n kääntäjä estää `smc`-mnemonikin EL3-vaatimuksella, joten
    // koodi ladotaan suoraan.
    asm volatile (".inst 0xd4000000"
        :
        : [psci_fn] "{x0}" (PSCI_SYSTEM_OFF),
        : .{ .memory = true });
    // Jos SMC palautuu/poikkeuttaa, jäädytä.
    while (true) {
        asm volatile ("wfi" ::: .{ .memory = true });
    }
}

const testing = @import("std").testing;

// Semihosting-vakiot vastaavat ARM-semihosting-speksiä.
test "semihosting call numbers match spec" {
    try testing.expectEqual(@as(u64, 0x18), SYS_EXIT);
    try testing.expectEqual(@as(u64, 0x20026), ADP_EXIT);
    try testing.expectEqual(@as(u64, 0x04), SYS_WRITE0);
    try testing.expectEqual(@as(u64, 0x11), SYS_TIME);
}
