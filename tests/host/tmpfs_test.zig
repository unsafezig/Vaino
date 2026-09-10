//! Host-testit tmpfs-ytimelle.

const std = @import("std");
const tmpfs = @import("tmpfs_core");

test "tmpfs add open read close" {
    // Suorita ytimen self-test (addFile + open/read/close).
    tmpfs.runSelfTest() catch return error.TestFailed;
}

test "tmpfs not found" {
    // Puhdas tila.
    tmpfs.initCore();
    // Avaa tuntematon polku → NotFound.
    const result = tmpfs.open("/missing");
    try std.testing.expectError(tmpfs.TmpfsError.NotFound, result);
}

test "tmpfs write read back within bounds" {
    // Puhdas tila + tiedosto.
    tmpfs.initCore();
    try tmpfs.addFile("/note", "hello");
    // Kirjoita jatkoa loppuun (offset 5).
    const n = try tmpfs.writeFile("/note", "-vsl", 5);
    try std.testing.expectEqual(@as(usize, 4), n);
    // Lue takaisin kokonaan.
    const file = try tmpfs.open("/note");
    var buf: [32]u8 = undefined;
    const m = try tmpfs.read(file, &buf, 0);
    try std.testing.expectEqual(@as(usize, 9), m);
    try std.testing.expectEqualSlices(u8, "hello-vsl", buf[0..m]);
}

test "tmpfs write rejects overflow and missing" {
    // Puhdas tila + pieni tiedosto.
    tmpfs.initCore();
    try tmpfs.addFile("/small", "x");
    // Ylikirjoitus yli MAX_FILE_DATA:n → NotSupported (ei katkaisua).
    var big: [300]u8 = undefined;
    @memset(&big, 'A');
    try std.testing.expectError(tmpfs.TmpfsError.NotSupported, tmpfs.writeFile("/small", &big, 0));
    // Tuntematon polku → NotFound.
    try std.testing.expectError(tmpfs.TmpfsError.NotFound, tmpfs.writeFile("/missing", "x", 0));
    // Sisältö säilynyt hylkäyksen jälkeen.
    const file = try tmpfs.open("/small");
    var buf: [8]u8 = undefined;
    const n = try tmpfs.read(file, &buf, 0);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'x'), buf[0]);
}

test "tmpfs lists files for vsl ls" {
    // Puhdas tila + kaksi tiedostoa.
    tmpfs.initCore();
    try tmpfs.addFile("/welcome", "TMPFS");
    try tmpfs.addFile("/note", "hi");
    // Laskuri täsmää.
    try std.testing.expectEqual(@as(usize, 2), tmpfs.fileCount());
    // Molemmat nimet löytyvät listasta.
    var found_welcome = false;
    var found_note = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (tmpfs.fileNameAt(i)) |name| {
            if (name.len == 8 and name[0] == '/' and name[1] == 'w') found_welcome = true;
            if (name.len == 5 and name[0] == '/' and name[1] == 'n') found_note = true;
        }
    }
    try std.testing.expect(found_welcome and found_note);
    // Rajat ulkona → null.
    try std.testing.expect(tmpfs.fileNameAt(99) == null);
}
