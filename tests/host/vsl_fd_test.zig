//! Host-testit VSL fd-taululle + mini-shellille (VSL-2).

const std = @import("std");
const fd = @import("vsl_fd");
const shell = @import("vsl_shell");

test "vsl fd console reserved and file alloc free" {
    // Puhdas taulukko — 3 konsolia varattu.
    fd.initTable();
    try std.testing.expectEqual(@as(usize, 3), fd.openCount());
    // Konsoli-kindit oikein.
    try std.testing.expectEqual(fd.FdKind.console, try fd.kindOf(0));
    try std.testing.expectEqual(fd.FdKind.console, try fd.kindOf(1));
    try std.testing.expectEqual(fd.FdKind.console, try fd.kindOf(2));
    // Konsoli-I/O valmis ring-3-polulla.
    try std.testing.expect(fd.isIoReady(1));
    // Avaa tiedosto → ensimmäinen vapaa fd (3).
    const h = try fd.openFile("/tmp/welcome");
    try std.testing.expectEqual(@as(u32, 3), h);
    // Kind file, ei vielä I/O-valmis (rehellinen raja).
    try std.testing.expectEqual(fd.FdKind.file, try fd.kindOf(h));
    try std.testing.expect(!fd.isIoReady(h));
    // Laskuri kasvanut.
    try std.testing.expectEqual(@as(usize, 4), fd.openCount());
    // Sulje → vapautuu.
    try fd.closeFd(h);
    try std.testing.expectEqual(@as(usize, 3), fd.openCount());
    // Suljettu fd → BadFd.
    try std.testing.expectError(fd.FdError.BadFd, fd.kindOf(h));
}

test "vsl fd rejects bad paths and full table" {
    // Puhdas taulukko.
    fd.initTable();
    // Tyhjä polku → BadPath.
    try std.testing.expectError(fd.FdError.BadPath, fd.openFile(""));
    // Suhteellinen polku → BadPath.
    try std.testing.expectError(fd.FdError.BadPath, fd.openFile("tmp/x"));
    // Rajat ulkona → BadFd.
    try std.testing.expectError(fd.FdError.BadFd, fd.kindOf(99));
    try std.testing.expectError(fd.FdError.BadFd, fd.closeFd(99));
    // Konsolin sulkeminen on no-op (ei virhettä).
    try fd.closeFd(1);
    try std.testing.expectEqual(@as(usize, 3), fd.openCount());
    // Täytä taulukko (13 vapaata slottia 3..15).
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        _ = try fd.openFile("/tmp/f");
    }
    // Täysi → TooManyOpen.
    try std.testing.expectError(fd.FdError.TooManyOpen, fd.openFile("/tmp/overflow"));
}

test "vsl shell parses help ls cat noop unknown" {
    // help (etumerkit leikataan).
    const h = try shell.parseLine("  help  \n");
    try std.testing.expect(h == .help);
    // ls polulla.
    const l = try shell.parseLine("ls /tmp");
    try std.testing.expect(l == .ls);
    try std.testing.expectEqualSlices(u8, "/tmp", l.ls);
    // cat polulla + rivinvaihto.
    const c = try shell.parseLine("cat /tmp/welcome\n");
    try std.testing.expect(c == .cat);
    try std.testing.expectEqualSlices(u8, "/tmp/welcome", c.cat);
    // Tyhjä rivi → noop.
    const n = try shell.parseLine("   \n");
    try std.testing.expect(n == .noop);
    // Tuntematon → sana vastalauseena.
    const u = try shell.parseLine("rm -rf /");
    try std.testing.expect(u == .unknown);
    try std.testing.expectEqualSlices(u8, "rm", u.unknown);
}

test "vsl shell rejects missing and long paths" {
    // ls ilman polkua → MissingPath.
    try std.testing.expectError(shell.ParseError.MissingPath, shell.parseLine("ls"));
    // cat ilman polkua → MissingPath.
    try std.testing.expectError(shell.ParseError.MissingPath, shell.parseLine("cat   "));
    // Ylipitkä polku → PathTooLong.
    var long: [80]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '/';
    var cmd: [84]u8 = undefined;
    @memcpy(cmd[0..4], "cat ");
    @memcpy(cmd[4..84], &long);
    try std.testing.expectError(shell.ParseError.PathTooLong, shell.parseLine(&cmd));
}
