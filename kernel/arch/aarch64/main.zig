//! Zinux ARM64 guest — minimaalinen kmain (Phase 1).
//!
//! **Vastuu**: PL011-sarjakonsoli + deterministinen boot-marker + siisti exit.
//! **Riippuvuudet**: uart, semihost
//! **Käytetään**: boot.S kutsuu tätä (`aarch64_kmain`, EL1, MMU pois)
//!
//! Laajuusrajaus (Phase 1): sarjakonsoli + RAM + boot-marker. Ajastin,
//! GIC, block-laite, datagram-laite ja kello ovat seuraavia askelia —
//! niitä EI teeskennellä tässä.

// Sarjakonsoli (PL011 UART0 @ 0x0900_0000).
const uart = @import("uart.zig");
const semihost = @import("semihost.zig");
const syscall = @import("syscall.zig");

// Deterministinen boot-marker — CI greppaa tämän sarjasta.
// EI saa muuttaa ilman ARM64_GUEST.md-päivitystä ja CI-sääntömuutosta.
pub const BOOT_MARKER: []const u8 = "Zinux ARM64 boot OK";
// Kehotevaraus tulevalle init/shell-vaiheelle (Phase 2).
pub const PROMPT: []const u8 = "zinux>";

// Kernelin pääfunktio — boot.S hyppää tähän EL1:ssä.
// Siirtyy aidosti EL0-initiin; initin SYS_EXIT päättää QEMU-smoken.
export fn aarch64_kmain() callconv(.c) noreturn {
    // Alusta sarjakonsoli ennen ensimmäistä tulostusta.
    uart.init();
    // Boot-viesti sarjaan (vrt. x86 "Zinux kernel starting...").
    uart.line("Zinux kernel starting (aarch64)");
    // Kohdealusta debug-lokitusta varten.
    uart.line("Target: aarch64 freestanding");
    // Boot valmis — CI smoke-testi etsii tämän merkkijonon sarjasta.
    uart.line(BOOT_MARKER);
    // Kehote ennen userland-siirtymää säilyy Phase 1 -markerina.
    uart.line(PROMPT);
    // Semihosting-savutesti: osoitinvälitys toimii (SEMI-WRITE0-OK stdoutiin).
    semihost.write0("SEMI-WRITE0-OK\n");
    syscall.initProcessRecords();
    // Siirry EL0-initiin. Init päättää tämän guestin SYS_EXITillä.
    syscall.aarch64_enter_init();
}

const testing = @import("std").testing;

// Markerit ovat CI-sopimus — lukitse tekstit testeillä.
test "boot marker contract" {
    try testing.expectEqualStrings("Zinux ARM64 boot OK", BOOT_MARKER);
    try testing.expectEqualStrings("zinux>", PROMPT);
}
