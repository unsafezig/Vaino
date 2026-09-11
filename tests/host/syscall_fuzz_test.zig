//! Host-testit syscall-fuzz-ytimelle.

const std = @import("std");
const fuzz = @import("syscall_fuzz_core");

test "expect enosys for unknown slots" {
    // Slot 0 ei rekisteröity.
    try std.testing.expect(fuzz.expectEnosys(0));
    // Slot 4 sys_ipc_send rekisteröity (Vaihe 8.1).
    try std.testing.expect(!fuzz.expectEnosys(4));
    // Slot 33 ensimmäinen tyhjä (VSL-4B: taulukko 33, 32 on trap).
    try std.testing.expect(fuzz.expectEnosys(33));
    // sys_write rekisteröity.
    try std.testing.expect(!fuzz.expectEnosys(1));
    // VFS-syscallit rekisteröity (VSL-4A: 29/30/31, taulukko täynnä).
    try std.testing.expect(!fuzz.expectEnosys(29));
    try std.testing.expect(!fuzz.expectEnosys(30));
    try std.testing.expect(!fuzz.expectEnosys(31));
}

test "dangerous syscalls flagged" {
    // exit ja read vaarallisia fuzzissa.
    try std.testing.expect(fuzz.isDangerous(2));
    try std.testing.expect(fuzz.isDangerous(11));
    // getpid turvallinen.
    try std.testing.expect(!fuzz.isDangerous(3));
    // ipc_send/recv dereferoivat user-osoitteita.
    try std.testing.expect(fuzz.isDangerous(4));
    try std.testing.expect(fuzz.isDangerous(5));
    // VFS-syscallit vaarallisia (user-osoite + kahvataulu, VSL-4A).
    try std.testing.expect(fuzz.isDangerous(29));
    try std.testing.expect(fuzz.isDangerous(30));
    try std.testing.expect(fuzz.isDangerous(31));
    // Trap-enable vaarallinen (persoonallisuus-mutaatio, VSL-4B).
    try std.testing.expect(fuzz.isDangerous(32));
    try std.testing.expect(!fuzz.expectEnosys(32));
}

test "lcg and fuzz num deterministic" {
    // Kiinteä seed.
    var seed: u64 = 12345;
    // Kaksi peräkkäistä numeroa.
    const n1 = fuzz.fuzzSyscallNum(&seed);
    const n2 = fuzz.fuzzSyscallNum(&seed);
    // Eri arvot (todennäköisesti).
    try std.testing.expect(n1 < 128);
    try std.testing.expect(n2 < 128);
    // Sama seed → sama sarja.
    var seed2: u64 = 12345;
    try std.testing.expect(fuzz.fuzzSyscallNum(&seed2) == n1);
    try std.testing.expect(fuzz.fuzzSyscallNum(&seed2) == n2);
}

test "boot fuzz ok threshold" {
    // Liian vähän ENOSYS.
    try std.testing.expect(!fuzz.bootFuzzOk(0));
    // Riittävästi.
    try std.testing.expect(fuzz.bootFuzzOk(fuzz.MIN_ENOSYS_HITS));
}
