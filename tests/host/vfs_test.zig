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
