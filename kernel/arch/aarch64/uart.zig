//! PL011 UART -ajuri ARM64 `virt`-koneelle (QEMU).
//!
//! **Vastuu**: Sarjakonsoli guestille — boot-marker ja `zinux>`-kehote.
//! **Riippuvuudet**: ei (vain volatile MMIO)
//! **Käytetään**: `main.zig` (aarch64 kmain), host-testit (vakiot)
//!
//! QEMU `virt` UART0 on osoitteessa 0x0900_0000. MMU on pois päältä,
//! joten fyysinen osoite käy sellaisenaan. Baud-rekistereihin ei
//! kosketa — QEMU:n oletus toimii; init varmistaa vain TX-päällekytkennän.

// UART0-kantaosoite (virt machine PL011).
pub const BASE: usize = 0x0900_0000;

// Rekisteri-offsetit kantaan nähden.
pub const REG_DR: usize = 0x000; // Data Register
pub const REG_FR: usize = 0x018; // Flag Register
pub const REG_IMSC: usize = 0x038; // Interrupt Mask
pub const REG_CR: usize = 0x030; // Control Register

// Flag Register: bitti 5 = TX FIFO täynnä (odota ennen kirjoitusta).
pub const FR_TXFF: u32 = 1 << 5;
// Control Register: bitti 8 = TX enable, bitti 0 = UART enable.
pub const CR_TXE: u32 = 1 << 8;
pub const CR_UARTEN: u32 = 1 << 0;

// Lue 32-bittinen MMIO-rekisteri.
inline fn readReg(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(BASE + offset);
    return ptr.*;
}

// Kirjoita 32-bittinen MMIO-rekisteri.
inline fn writeReg(offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(BASE + offset);
    ptr.* = value;
}

// Alusta UART TX-lähetys: sammuta keskeytykset, kytke TX + UART päälle.
// Baud-jakajiin (IBRD/FBRD) ei kosketa — QEMU-oletus kelpaa.
pub fn init() void {
    // Sammuta UART muutosten ajaksi.
    writeReg(REG_CR, 0);
    // Maskaa kaikki UART-keskeytykset (ei IRQ-käsittelyä vielä).
    writeReg(REG_IMSC, 0);
    // Kytke lähetys + UART päälle.
    writeReg(REG_CR, CR_TXE | CR_UARTEN);
}

// Lähetä yksi tavu — odottaa kunnes TX FIFO:ssa on tilaa.
pub fn putc(byte: u8) void {
    // Odota kunnes TXFF-bitti nollautuu (tilaa FIFOSsa).
    while ((readReg(REG_FR) & FR_TXFF) != 0) {}
    // Kirjoita tavu datarekisteriin — lähtee sarjaportista.
    const ptr: *volatile u32 = @ptrFromInt(BASE + REG_DR);
    ptr.* = byte;
}

// Lähetä merkkijono tavu kerrallaan.
pub fn write(msg: []const u8) void {
    for (msg) |b| putc(b);
}

// Tulosta rivi (viesti + '\n').
pub fn line(msg: []const u8) void {
    write(msg);
    putc('\n');
}

const testing = @import("std").testing;

// Rekisterikartta vastaa PL011-speksiä (hostilla testattava osa).
test "pl011 register map matches spec" {
    try testing.expectEqual(@as(usize, 0x0900_0000), BASE);
    try testing.expectEqual(@as(usize, 0x000), REG_DR);
    try testing.expectEqual(@as(usize, 0x018), REG_FR);
    try testing.expectEqual(@as(usize, 0x030), REG_CR);
    try testing.expectEqual(@as(u32, 1 << 5), FR_TXFF);
    try testing.expectEqual(@as(u32, (1 << 8) | 1), CR_TXE | CR_UARTEN);
}
