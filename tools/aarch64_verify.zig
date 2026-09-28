//! ARM64-guest-ELFin varmennin — QEMU:sta riippumaton portti (host-työkalu).
//!
//! **Vastuu**: Lue `zig-out/bin/zinux-aarch64` ja varmenna ilman QEMU:a:
//!   ELF64-LE, ET_EXEC, EM_AARCH64, entry = latauskanta, boot-marker mukana.
//! **Riippuvuudet**: std (host-työkalu; puhdas tarkastaja host-testattava).
//! **Käytetään**: `build.zig` (`aarch64-verify`-askel), host-testit.
//!
//! QEMU-ajo (`aarch64-run`) on ensisijainen portti; tämä nappaa
//! rikkoutuneet linkkaukset myös koneilla joissa ei ole QEMU:a.

// Tuo Zig std — host-työkalu (tiedostoluku, tulostus).
const std = @import("std");

// Odotettu ELF-polku (build-askel ajaa projektin juuresta).
pub const ELF_PATH: []const u8 = "zig-out/bin/zinux-aarch64";
// Latauskanta (kernel/arch/aarch64/linker.ld BASE — pidä synkassa).
pub const EXPECT_ENTRY: u64 = 0x40080000;
// EM_AARCH64 ELF-konetunniste.
pub const EM_AARCH64: u16 = 183;
// Boot-marker jonka QEMU-ajo greppaa sarjasta (rodata-tarkastus).
pub const MARKER: []const u8 = "Zinux ARM64 boot OK";
// Kehotevaraus (mukana kuvassa Phase 2:ta varten).
pub const PROMPT: []const u8 = "zinux>";

// Tarkastusvirheet (jokainen on CI:ssä oma punainen rivi).
pub const VerifyError = error{
    // Tiedosto liian pieni ollakseen ELF64.
    TooSmall,
    // Ei ELF-magiaa.
    BadMagic,
    // Ei 64-bittinen / little-endian / version 1.
    BadIdent,
    // Ei ET_EXEC.
    BadType,
    // Ei EM_AARCH64.
    BadMachine,
    // Entry ei ole latauskannassa.
    BadEntry,
    // Boot-marker puuttuu kuvasta.
    MarkerMissing,
    // Kehote puuttuu kuvasta.
    PromptMissing,
};

// Tarkasta ELF-tavut — puhdas funktio, ei I/O:ta.
pub fn verifyBytes(data: []const u8) VerifyError!u64 {
    // Vähintään ELF64-otsikko (64 B).
    if (data.len < 64) return error.TooSmall;
    // Magia: 0x7F 'E' 'L' 'F'.
    if (data[0] != 0x7F or data[1] != 'E' or data[2] != 'L' or data[3] != 'F')
        return error.BadMagic;
    // Luokka = 64-bit (2), data = LE (1), versio = 1.
    if (data[4] != 2 or data[5] != 1 or data[6] != 1) return error.BadIdent;
    // e_type @0x10 u16 LE = ET_EXEC (2).
    const etype: u16 = @as(u16, data[0x10]) | (@as(u16, data[0x11]) << 8);
    if (etype != 2) return error.BadType;
    // e_machine @0x12 u16 LE = EM_AARCH64 (183).
    const machine: u16 = @as(u16, data[0x12]) | (@as(u16, data[0x13]) << 8);
    if (machine != EM_AARCH64) return error.BadMachine;
    // e_entry @0x18 u64 LE = latauskanta.
    var entry: u64 = 0;
    for (0..8) |i| entry |= @as(u64, data[0x18 + i]) << @intCast(i * 8);
    if (entry != EXPECT_ENTRY) return error.BadEntry;
    // Boot-marker löydyttävä kuvasta (rodata).
    if (std.mem.indexOf(u8, data, MARKER) == null) return error.MarkerMissing;
    // Kehote löydyttävä kuvasta.
    if (std.mem.indexOf(u8, data, PROMPT) == null) return error.PromptMissing;
    // Palauta entry kutsujan lokitusta varten.
    return entry;
}

// Pääohjelma — lue ELF, tarkasta, raportoi.
pub fn main() !void {
    // Io-alusta (single-threaded riittää työkalulle).
    var threaded = std.Io.Threaded.init_single_threaded;
    // Io-kahva.
    const io: std.Io = threaded.io();
    // Allokaattori (sivut, ei seurantaa).
    const alloc = std.heap.page_allocator;
    // Työhakemisto = projektin juuri (build-askel ajaa sieltä).
    const cwd = std.Io.Dir.cwd();
    // Lue ELF (max 16 MiB — guest on kilotavuissa).
    const data = std.Io.Dir.readFileAlloc(cwd, io, ELF_PATH, alloc, .limited(16 * 1024 * 1024)) catch {
        // Tiedosto puuttuu (build-askel ei ajanut kerneliä ensin).
        std.debug.print("aarch64-verify: cannot read {s}\n", .{ELF_PATH});
        // Hylkää.
        return error.MissingElf;
    };
    // Tarkasta tavut.
    const entry = verifyBytes(data) catch |err| {
        // Syy CI-riville.
        std.debug.print("aarch64-verify: FAIL {t}\n", .{err});
        // Hylkää.
        return err;
    };
    // Kaikki tarkastukset läpi — entry lokiin toistettavuutta varten.
    std.debug.print("aarch64-verify: PASS entry=0x{x} marker+PROMPT present\n", .{entry});
}

const testing = std.testing;

// Rakenna synteettinen minimi-ELF64 ja aja täysi tarkastus.
fn synthElf() [128]u8 {
    // Nollattu puskuri, johon ladotaan otsikko + marker.
    var buf: [128]u8 = [_]u8{0} ** 128;
    // Magia.
    buf[0] = 0x7F;
    buf[1] = 'E';
    buf[2] = 'L';
    buf[3] = 'F';
    // 64-bit, LE, versio 1.
    buf[4] = 2;
    buf[5] = 1;
    buf[6] = 1;
    // ET_EXEC.
    buf[0x10] = 2;
    // EM_AARCH64 = 183 = 0xB7.
    buf[0x12] = 0xB7;
    // Entry = latauskanta LE.
    var e: u64 = EXPECT_ENTRY;
    for (0..8) |i| {
        buf[0x18 + i] = @truncate(e);
        e >>= 8;
    }
    // Marker + kehote perään.
    @memcpy(buf[64 .. 64 + MARKER.len], MARKER);
    @memcpy(buf[96 .. 96 + PROMPT.len], PROMPT);
    return buf;
}

test "valid synthetic elf passes" {
    const elf = synthElf();
    try testing.expectEqual(EXPECT_ENTRY, try verifyBytes(&elf));
}

test "each corruption is rejected with its own error" {
    // Magia rikki.
    var elf = synthElf();
    elf[0] = 0;
    try testing.expectError(error.BadMagic, verifyBytes(&elf));
    // 32-bit luokka.
    elf = synthElf();
    elf[4] = 1;
    try testing.expectError(error.BadIdent, verifyBytes(&elf));
    // Väärä konetyyppi (x86_64 = 62).
    elf = synthElf();
    elf[0x12] = 62;
    elf[0x13] = 0;
    try testing.expectError(error.BadMachine, verifyBytes(&elf));
    // Väärä entry.
    elf = synthElf();
    elf[0x18] ^= 0x01;
    try testing.expectError(error.BadEntry, verifyBytes(&elf));
    // Marker tuhottu.
    elf = synthElf();
    elf[64] ^= 0xFF;
    try testing.expectError(error.MarkerMissing, verifyBytes(&elf));
    // Liian pieni.
    try testing.expectError(error.TooSmall, verifyBytes(elf[0..16]));
}
