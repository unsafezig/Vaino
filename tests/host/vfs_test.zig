//! Host-testit VFS-ytimelle.

const std = @import("std");
const vfs = @import("vfs_core");

test "vfs open read close roundtrip" {
    // Puhdas tila + test-mount.
    vfs.runSelfTest() catch return error.TestFailed;
}

test "vfs not found on bad path" {
    // Puhdas tila.
    vfs.initCore();
    // Rekisteröi test-mount.
    try vfs.registerTestMount();
    // Tuntematon polku → NotFound.
    const result = vfs.open("/test/missing");
    try std.testing.expectError(vfs.VfsError.NotFound, result);
}

test "vfs invalid path" {
    // Puhdas tila.
    vfs.initCore();
    // Tyhjä polku → InvalidPath.
    const result = vfs.open("");
    try std.testing.expectError(vfs.VfsError.InvalidPath, result);
}

test "vfs write rejected on read-only testfs" {
    // Puhdas tila + test-mount (ei write-opta).
    vfs.initCore();
    try vfs.registerTestMount();
    // Avaa lukuun.
    const h = try vfs.open("/test/hello");
    // Kirjoitus read-only FS:ään → NotSupported (ei hiljaista hylkäystä).
    var buf: [4]u8 = .{ 'x', 'x', 'x', 'x' };
    const result = vfs.write(h, &buf, 0);
    try std.testing.expectError(vfs.VfsError.NotSupported, result);
    // Sulje kahva.
    vfs.close(h);
}

test "vfs errno mapping matches linux numbers" {
    // NotFound → ENOENT (-2, zinuxabi-peili).
    try std.testing.expectEqual(@as(i64, -2), vfs.errnoOf(vfs.VfsError.NotFound));
    // InvalidPath → EINVAL (-22).
    try std.testing.expectEqual(@as(i64, -22), vfs.errnoOf(vfs.VfsError.InvalidPath));
    // NotSupported/NotInitialized → ENOSYS (-38).
    try std.testing.expectEqual(@as(i64, -38), vfs.errnoOf(vfs.VfsError.NotSupported));
    try std.testing.expectEqual(@as(i64, -38), vfs.errnoOf(vfs.VfsError.NotInitialized));
    // TooManyFiles/TooManyMounts → ENOMEM (-12).
    try std.testing.expectEqual(@as(i64, -12), vfs.errnoOf(vfs.VfsError.TooManyFiles));
    try std.testing.expectEqual(@as(i64, -12), vfs.errnoOf(vfs.VfsError.TooManyMounts));
}

test "vfs isOpen tracks handles" {
    // Alustamaton → mikään ei auki.
    vfs.initCore();
    try vfs.registerTestMount();
    // Tuntematon kahva kiinni.
    try std.testing.expect(!vfs.isOpen(7));
    // Rajojen ulkopuoli kiinni.
    try std.testing.expect(!vfs.isOpen(99));
    // Avaa → auki.
    const h = try vfs.open("/test/hello");
    try std.testing.expect(vfs.isOpen(h));
    // Sulje → kiinni (idempotentti close ei kaada toista sulkua).
    vfs.close(h);
    try std.testing.expect(!vfs.isOpen(h));
    vfs.close(h);
    try std.testing.expect(!vfs.isOpen(h));
}
