//! Host-testit VSL mini-ABI:lle (VSL-1).
//!
//! **Vastuu**: Pinnaa Linux→Zinux-käännösvektorit + shim-luokittelijat ilman
//!   laitteistoa. Kernel-valvonta (scope/gateway) testataan bootissa.

const std = @import("std");
const linux_abi = @import("vsl_abi");
const vsl_libc = @import("vsl_libc");
const fd = @import("vsl_fd");

test "vsl translates supported linux syscalls" {
    // read → sys_read.
    try std.testing.expectEqual(linux_abi.ZINUX_READ, linux_abi.linuxToZinux(linux_abi.LINUX_READ).?);
    // write → sys_write.
    try std.testing.expectEqual(linux_abi.ZINUX_WRITE, linux_abi.linuxToZinux(linux_abi.LINUX_WRITE).?);
    // mmap → sys_mem_map.
    try std.testing.expectEqual(linux_abi.ZINUX_MEM_MAP, linux_abi.linuxToZinux(linux_abi.LINUX_MMAP).?);
    // brk → sys_mem_map.
    try std.testing.expectEqual(linux_abi.ZINUX_MEM_MAP, linux_abi.linuxToZinux(linux_abi.LINUX_BRK).?);
    // getpid → sys_getpid.
    try std.testing.expectEqual(linux_abi.ZINUX_GETPID, linux_abi.linuxToZinux(linux_abi.LINUX_GETPID).?);
    // exit → sys_exit.
    try std.testing.expectEqual(linux_abi.ZINUX_EXIT, linux_abi.linuxToZinux(linux_abi.LINUX_EXIT).?);
    // openat → sys_vfs_open (VSL-4A).
    try std.testing.expectEqual(linux_abi.ZINUX_VFS_OPEN, linux_abi.linuxToZinux(linux_abi.LINUX_OPENAT).?);
    // close → sys_vfs_close (VSL-4A).
    try std.testing.expectEqual(linux_abi.ZINUX_VFS_CLOSE, linux_abi.linuxToZinux(linux_abi.LINUX_CLOSE).?);
}

test "vsl rejects unknown and defers uname internally" {
    // Tuntematon numero → null.
    try std.testing.expect(linux_abi.linuxToZinux(9999) == null);
    // uname käsitellään sisäisesti, ei kernel-kutsua.
    try std.testing.expect(linux_abi.isHandledInternally(linux_abi.LINUX_UNAME));
    // write ei ole sisäinen.
    try std.testing.expect(!linux_abi.isHandledInternally(linux_abi.LINUX_WRITE));
    // brk/mmap tarvitsevat memory-capin.
    try std.testing.expect(linux_abi.needsMemoryCap(linux_abi.LINUX_BRK));
    // write ei tarvitse memory-cappia.
    try std.testing.expect(!linux_abi.needsMemoryCap(linux_abi.LINUX_WRITE));
}

test "vsl shim support matrix and uname copy" {
    // Tuettu: write (suora käännös).
    try std.testing.expect(vsl_libc.isSupported(linux_abi.LINUX_WRITE));
    // Tuettu: uname (sisäinen vastaus).
    try std.testing.expect(vsl_libc.isSupported(linux_abi.LINUX_UNAME));
    // Tuettu: openat/close (VFS-syscallit, VSL-4A).
    try std.testing.expect(vsl_libc.isSupported(linux_abi.LINUX_OPENAT));
    try std.testing.expect(vsl_libc.isSupported(linux_abi.LINUX_CLOSE));
    // classifyReturn: nolla/positiivinen → null (ei virhettä).
    try std.testing.expect(vsl_libc.classifyReturn(4) == null);
    // classifyReturn: negatiivinen kulkee läpi.
    try std.testing.expectEqual(@as(i64, -9), vsl_libc.classifyReturn(-9).?);
    // unameCopy täyteen puskuriin: "VSL 0.1" = 7 tavua.
    var buf: [16]u8 = undefined;
    // Kopioi vastaus.
    const n = vsl_libc.unameCopy(&buf);
    // Varmista pituus.
    try std.testing.expectEqual(@as(usize, 7), n);
    // Varmista sisältö.
    try std.testing.expectEqualSlices(u8, "VSL 0.1", buf[0..n]);
    // unameCopy katkaistuun puskuriin: ei ylivuotoa.
    var tiny: [3]u8 = undefined;
    // Kopioi katkaistuna.
    const m = vsl_libc.unameCopy(&tiny);
    // Varmista katkaistu pituus.
    try std.testing.expectEqual(@as(usize, 3), m);
    // Varmista etuliite.
    try std.testing.expectEqualSlices(u8, "VSL", tiny[0..m]);
}

test "vsl shim fd errors without syscalls" {
    // fd-virhemäppäys negatiivisiksi (puhdas, ei syscalleja).
    try std.testing.expectEqual(@as(i64, -9), vsl_libc.fdErrToNeg(fd.FdError.BadFd));
    try std.testing.expectEqual(@as(i64, -22), vsl_libc.fdErrToNeg(fd.FdError.BadPath));
    try std.testing.expectEqual(@as(i64, -12), vsl_libc.fdErrToNeg(fd.FdError.TooManyOpen));
    try std.testing.expectEqual(@as(i64, -38), vsl_libc.fdErrToNeg(fd.FdError.NotSupported));
    // Puhdas taulukko — konsolit varattu.
    fd.initTable();
    // Konsolin sulku no-op ilman syscalleja (Linux-pariteetti).
    try std.testing.expectEqual(@as(i64, 0), vsl_libc.vslCloseFile(1));
    // Tuntematon fd → EBADF ilman syscalleja.
    try std.testing.expectEqual(@as(i64, -9), vsl_libc.vslCloseFile(9));
    try std.testing.expectEqual(@as(i64, -9), vsl_libc.vslReadFile(9, &[_]u8{}));
    // Sitomaton file-fd → EBADF (ei valehtelua tuesta, ei syscalleja).
    const h = try fd.openFile("/tmp/welcome");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(i64, -9), vsl_libc.vslReadFile(h, &buf));
    try std.testing.expectEqual(@as(i64, 0), vsl_libc.vslCloseFile(h));
}
