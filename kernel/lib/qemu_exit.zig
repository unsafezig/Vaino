//! QEMU-lopetus — isa-debug-exit -laite boot-testeissä.
//!
//! **Vastuu**: Pysäytä QEMU siististi kun boot-testit valmiit (ei odota timeoutia).
//! **Riippuvuudet**: ei
//! **Käytetään**: `main.zig`, `boot_tests.zig`

// QEMU isa-debug-exit I/O-portti (build.zig: -device isa-debug-exit,iobase=0xf4).
const DEBUG_EXIT_PORT: u16 = 0xf4;
// Onnistuneen boot-testin exit-koodi (QEMU isa-debug-exit: 0 → shell exit 1).
const EXIT_SUCCESS: u32 = 0;
// Epäonnistuneen boot-testin exit-koodi (1 → shell exit 3 — build.zig
// hyväksyy vain 0/1, joten K2-portti kaataa CI-stepin punaiseksi).
const EXIT_FAILURE: u32 = 1;

// Pysäytä QEMU — ei palaa.
pub fn exitSuccess() noreturn {
    // Kirjoita exit-koodi debug-exit-porttiin — QEMU terminoituu.
    asm volatile ("outl %%eax, %%dx"
        :
        : [code] "{eax}" (EXIT_SUCCESS),
          [port] "{dx}" (DEBUG_EXIT_PORT),
        : .{ .memory = true });
    // Jos laite puuttuu, odota ikuisesti.
    while (true) {
        // CLI + HLT — ei kuluta CPU:ta.
        asm volatile ("cli; hlt" ::: .{ .memory = true });
    }
}

// Pysäytä QEMU epäonnistuneena (K2) — ei palaa.
pub fn exitFailure() noreturn {
    // Kirjoita failure-koodi debug-exit-porttiin — QEMU terminoituu exit 3:lla.
    // Portti on 16-bittinen dx (kuten success-polussa), data 32-bittinen eax.
    asm volatile ("outl %%eax, %%dx"
        :
        : [code] "{eax}" (EXIT_FAILURE),
          [port] "{dx}" (DEBUG_EXIT_PORT),
        : .{ .memory = true });
    // Jos laite puuttuu, odota ikuisesti (sama kuin success-polussa).
    while (true) {
        // CLI + HLT — ei kuluta CPU:ta.
        asm volatile ("cli; hlt" ::: .{ .memory = true });
    }
}
