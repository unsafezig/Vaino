//! Host-testit Linux-hello-generaattorille (VSL-4B).
//!
//! **Vastuu**: Varmenna generoidun ELF:n rakenne itsenäisesti (magia, otsikot,
//!   kooditavut, LEA-paikat, data) ilman QEMU:a. QEMU todistaa suorituksen.

const std = @import("std");
const gen = @import("linux_hello_tool");

// Lue u16 little-endian.
fn get16(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}

// Lue u32 little-endian.
fn get32(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8) | (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
}

// Lue u64 little-endian.
fn get64(b: []const u8, off: usize) u64 {
    return @as(u64, get32(b, off)) | (@as(u64, get32(b, off + 4)) << 32);
}

test "linux hello image layout" {
    // Rakenna kuva kiinteään puskuriin.
    var buf: [gen.IMAGE_LEN]u8 = undefined;
    const n = try gen.buildImage(&buf);
    try std.testing.expectEqual(@as(usize, gen.IMAGE_LEN), n);
    // Liian pieni puskuri hylätään (ei katkaisua).
    var tiny: [16]u8 = undefined;
    try std.testing.expectError(gen.GenError.TooSmall, gen.buildImage(&tiny));
    // ELF-magia + 64-bit LE + versio.
    try std.testing.expectEqual(@as(u8, 0x7F), buf[0]);
    try std.testing.expectEqual(@as(u8, 'E'), buf[1]);
    try std.testing.expectEqual(@as(u8, 'L'), buf[2]);
    try std.testing.expectEqual(@as(u8, 'F'), buf[3]);
    try std.testing.expectEqual(@as(u8, 2), buf[4]);
    try std.testing.expectEqual(@as(u8, 1), buf[5]);
    // ET_EXEC (2), x86_64 (62).
    try std.testing.expectEqual(@as(u16, 2), get16(&buf, 16));
    try std.testing.expectEqual(@as(u16, 62), get16(&buf, 18));
    // Entry = koodin alku (base + CODE_OFF — headeria ei ajeta).
    try std.testing.expectEqual(gen.ENTRY_VADDR + gen.CODE_OFF, get64(&buf, 24));
    try std.testing.expectEqual(@as(u64, 64), get64(&buf, 32));
    try std.testing.expectEqual(@as(u16, 1), get16(&buf, 56));
    // PT_LOAD R-X, offset 0, vaddr entry, align sivu.
    try std.testing.expectEqual(@as(u32, 1), get32(&buf, 64));
    try std.testing.expectEqual(@as(u32, 5), get32(&buf, 68));
    try std.testing.expectEqual(@as(u64, 0), get64(&buf, 72));
    try std.testing.expectEqual(@as(u64, 0x400000), get64(&buf, 80));
    try std.testing.expectEqual(@as(u64, 0x1000), get64(&buf, 112));
    // Koodin alku: mov eax, 63 (uname).
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xB8, 0x3F, 0x00, 0x00, 0x00 }, buf[gen.CODE_OFF..][0..5]);
    // Koodin loppu: mov eax, 60 + syscall (exit).
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xB8, 0x3C, 0x00, 0x00, 0x00 }, buf[gen.CODE_OFF + gen.CODE_LEN - 7 ..][0..5]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0F, 0x05 }, buf[gen.CODE_OFF + gen.CODE_LEN - 2 ..][0..2]);
    // Data: hello + prefix + newline + ok/fail valinnat.
    const d1 = gen.CODE_OFF + gen.CODE_LEN;
    try std.testing.expectEqualSlices(u8, "hello linux\n", buf[d1..][0..12]);
    try std.testing.expectEqualSlices(u8, "vsl-uname: ", buf[d1 + 12 ..][0..11]);
    try std.testing.expectEqualSlices(u8, "vsl-enosys OK\n", buf[d1 + 24 ..][0..14]);
    try std.testing.expectEqualSlices(u8, "vsl-enosys FAIL\n", buf[d1 + 38 ..][0..16]);
}

test "linux hello lea patches resolve" {
    // Rakenna kuva.
    var buf: [gen.IMAGE_LEN]u8 = undefined;
    _ = try gen.buildImage(&buf);
    // Jokainen LEA: disp32 = kohde_vaddr − (lea_vaddr + 7), täsmää dataan.
    // Käy koodi, etsi 48 8D 3x -alkuiset (lea r64, [rel32]).
    var p: usize = gen.CODE_OFF;
    const end = gen.CODE_OFF + gen.CODE_LEN;
    var found: usize = 0;
    while (p + 7 <= end) : (p += 1) {
        // LEA-alku (REX.W + 8D + modrm).
        if (buf[p] != 0x48 or buf[p + 1] != 0x8D) continue;
        // Seuraava tavu modrm (0x35/0x05/0x0D kelpaavat).
        const mod = buf[p + 2];
        if (mod != 0x35 and mod != 0x05 and mod != 0x0D) continue;
        // Lue disp32 etumerkillisenä.
        const disp: i32 = @bitCast(get32(&buf, p + 3));
        // Kohde vaddr.
        const target: i64 = @as(i64, @intCast(gen.ENTRY_VADDR + p)) + 7 + disp;
        // Kohteen file-offset (entry-pohjainen vaddr miinus base).
        const toff: i64 = target - @as(i64, @intCast(gen.ENTRY_VADDR));
        // Kohde datassa (koodin jälkeen, ennen kuvan loppua — file-offsetit
        // sisältävät otsikot, joten rajat CODE_OFF-pohjaiset, ei CODE_LEN).
        try std.testing.expect(toff >= @as(i64, @intCast(gen.CODE_OFF + gen.CODE_LEN)));
        try std.testing.expect(toff < @as(i64, @intCast(gen.IMAGE_LEN)));
        found += 1;
    }
    // Viisi LEA:ta (msg1, msg2, newline, ok, fail).
    try std.testing.expectEqual(@as(usize, 5), found);
}
