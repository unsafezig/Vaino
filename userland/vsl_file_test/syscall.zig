//! Syscall-apu — VSL file-I/O -demon paluukutsu.
//!
//! **Vastuu**: sys_test_return (kehitysputki takaisin boot-testiin).
//!   Tulostus kulkee shimmin (`vsl_libc.vslWrite`) kautta — tämä tiedosto
//!   on vain paluureitti, ei Linux-ABI:a.
//! **Riippuvuudet**: ei
//! **Käytetään**: `main.zig`

// Syscall-numero: sys_test_return — palaa kernel boot-jatkoon.
pub const SYS_test_return: u64 = 10;

// Palaa kerneliin boot-testin jatkoon (ei paluuta user-tilaan).
pub fn sysTestReturn() noreturn {
    // SYS_test_return ilman argumentteja.
    asm volatile ("syscall"
        :
        : [num] "{rax}" (SYS_test_return),
          [a1] "{rdi}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true });
    // Ei saavuteta.
    unreachable;
}
