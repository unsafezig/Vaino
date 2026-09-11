//! Linux-hello-ELF-generaattori — muokkaamaton Linux-ABI-demo (VSL-4B, host-työkalu).
//!
//! **Vastuu**: Rakenna deterministinen staattinen x86_64-Linux-ELF tavupuskuriin:
//!   uname(63) → write(1,"hello linux") → write("vsl-uname: ") → write(ubuf) →
//!   write("\\n") → invalid(9999, odota -38, cmov-valinta) → exit(koodi).
//!   Ei libc:tä, ei Zinux-shimmiä — pelkkä Linux-syscall-ABI (trap-kohde).
//!   `zig build` ajaa tämän ennen kerneliä; kernel upottaa tuloksen.
//! **Riippuvuudet**: std (host-työkalu; puhdas rakentaja host-testattava).
//! **Käytetään**: `build.zig` (generointiaskel), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - "Muokkaamaton" tarkoittaa: standardi ET_EXEC, tavallinen linkkiosoite
//!   (0x400000), raaka Linux-syscallit — binääriä ei ole käännetty Zinuxia
//!   vasten eikä linkitetty shimmiin. libc:tä ei ole (staattinen raw-ABI).
//! - Ei hyppyjä koodissa (cmov-valinta): generaattori laskee vain
//!   RIP-suhteellisten LEA:iden disp32:t paikkamerkeistä — ei eteenpäin-
//!   hyppyjen offset-laskentaa, ei kokoamisvirheiden arvausta.
//! - Tavut kiinnitetty: sama tulos joka ajolla (ei aikaleimoja) —
//!   host-testi varmentaa magian/entryn/segmentit/koodin itsenäisesti.

// Tuo Zig std — host-työkalu (tiedostokirjoitus, tulostus).
const std = @import("std");

// Linkkiosoite (tavallinen staattinen Linux-osoite — ei Zinux-alue).
pub const ENTRY_VADDR: u64 = 0x400000;
// ELF-otsikko (64 B) + 1 ohjelmaotsikko (56 B) ennen koodia.
pub const CODE_OFF: usize = 120;
// Suorituksen alku: koodin file-offset (headerit kartoitettu muttei ajettu —
// e_entry = base + CODE_OFF, vakiolinkkerikaava; entry=base ajaisi headeria).
// Koodin pituus tavuina (kiinnitetty käsinlaskenta — assert varmentaa).
pub const CODE_LEN: usize = 190;
// Datan pituus (msg1 12 + msg2 12 + msg3 1 + ok 14 + fail 16).
pub const DATA_LEN: usize = 55;
// Koko kuvan pituus (otsikot + koodi + data).
pub const IMAGE_LEN: usize = CODE_OFF + CODE_LEN + DATA_LEN;
// Uname-vastauksen odotettu pituus (trap-emulaatio kirjoittaa tämän).
pub const UNAME_LEN: usize = 7;
// "hello linux\n" pituus.
pub const HELLO_LEN: usize = 12;

// Generointivirheet (puskuri liian pieni — ei hiljaista katkaisua).
pub const GenError = error{
    // Kohdepuskuri alle IMAGE_LEN.
    TooSmall,
};

// Datamerkkijonot koodin perässä (generoija latoo järjestyksessä).
const MSG1 = "hello linux\n";
const MSG2 = "vsl-uname: ";
const MSG3 = "\n";
const MSG_OK = "vsl-enosys OK\n";
const MSG_FAIL = "vsl-enosys FAIL\n";

// Kirjoita u16 little-endian (ELF-kentät).
fn put16(buf: []u8, off: usize, v: u16) void {
    // Pikkutavu ensin.
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

// Kirjoita u32 little-endian (ELF-kentät + disp32-paikat).
fn put32(buf: []u8, off: usize, v: u32) void {
    // Tavut alimmasta alkaen.
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

// Kirjoita u64 little-endian (ELF-kentät).
fn put64(buf: []u8, off: usize, v: u64) void {
    // Ala- ja yläpuoliskot erikseen.
    put32(buf, off, @truncate(v));
    put32(buf, off + 4, @truncate(v >> 32));
}

// Kopioi tavut puskuriin kohdasta (ei ylivuotoa — kutsuja mitoittaa).
fn putBytes(buf: []u8, off: usize, bytes: []const u8) void {
    // Tavujono sellaisenaan.
    @memcpy(buf[off..][0..bytes.len], bytes);
}

// Rakenna kuva puskuriin — palauttaa kirjoitetut tavut (IMAGE_LEN).
// LEA-paikat täytetään generoinnin aikana lasketuista label-offseteista.
pub fn buildImage(out: []u8) GenError!usize {
    // Puskuriin mahduttava koko kuva.
    if (out.len < IMAGE_LEN) return GenError.TooSmall;
    // Nollaa kuva (määrittelemättömät tavut eivät vuoda).
    @memset(out[0..IMAGE_LEN], 0);
    // --- ELF-otsikko (64 tavua) ---
    // Magia 7F E L F.
    out[0] = 0x7F;
    out[1] = 'E';
    out[2] = 'L';
    out[3] = 'F';
    // Luokka 64-bit, data LE, versio 1, ABI SystemV.
    out[4] = 2;
    out[5] = 1;
    out[6] = 1;
    out[7] = 0;
    // Tyyppi ET_EXEC (2), kone x86_64 (62), versio 1.
    put16(out, 16, 2);
    put16(out, 18, 62);
    put32(out, 20, 1);
    // Entry = koodin alku (base + CODE_OFF — ei headeria).
    put64(out, 24, ENTRY_VADDR + CODE_OFF);
    put64(out, 32, 64);
    put64(out, 40, 0);
    // Liput 0, otsikkokoko 64, ohjelmaotsikko 56×1, ei sektioita.
    put32(out, 48, 0);
    put16(out, 52, 64);
    put16(out, 54, 56);
    put16(out, 56, 1);
    put16(out, 58, 0);
    put16(out, 60, 0);
    put16(out, 62, 0);
    // --- Ohjelmaotsikko (1×56, PT_LOAD R-X) ---
    // Tyyppi LOAD (1), liput R+X (5).
    put32(out, 64, 1);
    put32(out, 68, 5);
    // Offset 0, vaddr ENTRY, koko kuva (koodi+data samassa R-X-segmentissä).
    put64(out, 72, 0);
    put64(out, 80, ENTRY_VADDR);
    put64(out, 88, ENTRY_VADDR);
    put64(out, 96, IMAGE_LEN);
    put64(out, 104, IMAGE_LEN);
    // Tasaus sivu (offset 0 ≡ vaddr mod sivu — kongruenssi voimassa).
    put64(out, 112, 0x1000);
    // --- Koodi (kiinnitetyt tavut, paikat täytetään alla) ---
    // Kursorin alku.
    var c: usize = CODE_OFF;
    // Datan file-offsetit (koodin perässä annetussa järjestyksessä).
    const d1 = CODE_OFF + CODE_LEN;
    const d2 = d1 + MSG1.len;
    const d3 = d2 + MSG2.len;
    const d4 = d3 + MSG3.len;
    const d5 = d4 + MSG_OK.len;
    // Apu: RIP-suhteellinen disp32 LEA:lle kohdassa p (7-tavuinen käsky).
    // disp = kohde_vaddr − (käskyn_vaddr + 7).
    const disp = struct {
        fn d(p: usize, target_off: usize) u32 {
            // Kohteen virtuaaliosoite.
            const tv: i64 = @intCast(ENTRY_VADDR + target_off);
            // Seuraavan käskyn virtuaaliosoite.
            const nv: i64 = @intCast(ENTRY_VADDR + p + 7);
            // Erotus sopii i32:een (pieni kuva).
            return @bitCast(@as(i32, @intCast(tv - nv)));
        }
    }.d;
    // mov eax, 63 (uname).
    putBytes(out, c, &[_]u8{ 0xB8, 0x3F, 0x00, 0x00, 0x00 });
    c += 5;
    // sub rsp, 32 (ubuf pinossa).
    putBytes(out, c, &[_]u8{ 0x48, 0x83, 0xEC, 0x20 });
    c += 4;
    // mov rdi, rsp.
    putBytes(out, c, &[_]u8{ 0x48, 0x89, 0xE7 });
    c += 3;
    // mov edx, 32 (uname-puskurin pituus — rekisteri roskaa entryssä).
    putBytes(out, c, &[_]u8{ 0xBA, 0x20, 0x00, 0x00, 0x00 });
    c += 5;
    // syscall.
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // mov eax, 1; mov edi, 1 (write hello).
    putBytes(out, c, &[_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0xBF, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    // lea rsi, [rel msg1].
    putBytes(out, c, &[_]u8{ 0x48, 0x8D, 0x35 });
    put32(out, c + 3, disp(c, d1));
    c += 7;
    // mov edx, 12; syscall.
    putBytes(out, c, &[_]u8{ 0xBA, 0x0C, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // mov eax, 1; mov edi, 1 (write prefix).
    putBytes(out, c, &[_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0xBF, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    // lea rsi, [rel msg2].
    putBytes(out, c, &[_]u8{ 0x48, 0x8D, 0x35 });
    put32(out, c + 3, disp(c, d2));
    c += 7;
    // mov edx, 12; syscall.
    putBytes(out, c, &[_]u8{ 0xBA, 0x0C, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // mov eax, 1; mov edi, 1 (write ubuf 7).
    putBytes(out, c, &[_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0xBF, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    // mov rsi, rsp (ubuf yhä pinossa).
    putBytes(out, c, &[_]u8{ 0x48, 0x89, 0xE6 });
    c += 3;
    // mov edx, 7; syscall.
    putBytes(out, c, &[_]u8{ 0xBA, 0x07, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // mov eax, 1; mov edi, 1 (write newline).
    putBytes(out, c, &[_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0xBF, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    // lea rsi, [rel msg3].
    putBytes(out, c, &[_]u8{ 0x48, 0x8D, 0x35 });
    put32(out, c + 3, disp(c, d3));
    c += 7;
    // mov edx, 1; syscall.
    putBytes(out, c, &[_]u8{ 0xBA, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // add rsp, 32 (pino takaisin).
    putBytes(out, c, &[_]u8{ 0x48, 0x83, 0xC4, 0x20 });
    c += 4;
    // mov eax, 9999 (tuntematon Linux-numero).
    putBytes(out, c, &[_]u8{ 0xB8, 0x0F, 0x27, 0x00, 0x00 });
    c += 5;
    // syscall.
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // cmp rax, -38 (ENOSYS-odotus).
    putBytes(out, c, &[_]u8{ 0x48, 0x83, 0xF8, 0xDA });
    c += 4;
    // sete bl (bl=1 jos ENOSYS).
    putBytes(out, c, &[_]u8{ 0x0F, 0x94, 0xC3 });
    c += 3;
    // lea rax, [rel msg_ok]; lea rcx, [rel msg_fail] (cmov-valinta).
    putBytes(out, c, &[_]u8{ 0x48, 0x8D, 0x05 });
    put32(out, c + 3, disp(c, d4));
    c += 7;
    putBytes(out, c, &[_]u8{ 0x48, 0x8D, 0x0D });
    put32(out, c + 3, disp(c, d5));
    c += 7;
    // mov edx, 14 (ok-pituus); mov r8d, 16 (fail-pituus).
    putBytes(out, c, &[_]u8{ 0xBA, 0x0E, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x41, 0xB8, 0x10, 0x00, 0x00, 0x00 });
    c += 6;
    // cmovne rax, rcx (väärä vastaus → fail-osoite).
    putBytes(out, c, &[_]u8{ 0x48, 0x0F, 0x45, 0xC1 });
    c += 4;
    // cmovne eax, r8d (väärä vastaus → fail-pituus).
    putBytes(out, c, &[_]u8{ 0x41, 0x0F, 0x45, 0xC0 });
    c += 4;
    // mov rsi, rax; mov eax, 1; mov edi, 1; syscall (valittu rivi).
    putBytes(out, c, &[_]u8{ 0x48, 0x89, 0xC6 });
    c += 3;
    putBytes(out, c, &[_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0xBF, 0x01, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // movzx edi, bl; xor edi, 1 (ok→exit 0, fail→exit 1).
    putBytes(out, c, &[_]u8{ 0x0F, 0xB6, 0xFB });
    c += 3;
    putBytes(out, c, &[_]u8{ 0x83, 0xF7, 0x01 });
    c += 3;
    // mov eax, 60 (exit); syscall.
    putBytes(out, c, &[_]u8{ 0xB8, 0x3C, 0x00, 0x00, 0x00 });
    c += 5;
    putBytes(out, c, &[_]u8{ 0x0F, 0x05 });
    c += 2;
    // Kursori täsmää kiinnitettyyn pituuteen (käsinlaskenta todistettu).
    std.debug.assert(c == CODE_OFF + CODE_LEN);
    // --- Data (msg1..fail annetussa järjestyksessä) ---
    putBytes(out, d1, MSG1);
    putBytes(out, d2, MSG2);
    putBytes(out, d3, MSG3);
    putBytes(out, d4, MSG_OK);
    putBytes(out, d5, MSG_FAIL);
    // Palauta koko kuvan pituus.
    return IMAGE_LEN;
}

// Kohdetiedosto build-puussa (generointiaskel ajaa cwd=juuressa).
pub const OUT_PATH = "kernel/loader/linux_hello_prog.bin";

// Pääohjelma — rakenna kuva + kirjoita tiedostoon + yhteenveto.
pub fn main() !void {
    // Kiinteä puskuri koko kuvalle (ei allokaatiota).
    var buf: [IMAGE_LEN]u8 = undefined;
    // Rakenna kuva.
    const n = try buildImage(&buf);
    // Io-alusta työkalulle (plugin_verify-kaava, Zig 0.16 API).
    var threaded = std.Io.Threaded.init_single_threaded;
    // Io-kahva.
    const io: std.Io = threaded.io();
    // Työhakemisto (generointiaskel ajaa juuressa).
    const cwd = std.Io.Dir.cwd();
    // Kirjoita tiedostoon (luo/korvaa — deterministiset tavut).
    try std.Io.Dir.writeFile(cwd, io, .{ .sub_path = OUT_PATH, .data = buf[0..n] });
    // Yhteenveto serialiin (build-loki todistaa generoinnin).
    std.debug.print("linux-hello: {d} bytes -> {s}\n", .{ n, OUT_PATH });
}
