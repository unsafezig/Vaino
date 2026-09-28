//! ARM64 Phase 2:n pienin EL0-syscall-polku.

const uart = @import("uart.zig");
const semihost = @import("semihost.zig");

pub const SYS_IPC_SMOKE: u64 = 0;
pub const SYS_EXIT: u64 = 1;
pub const IPC_SMOKE_REQUEST: u64 = 0x49504331; // "IPC1"
pub const IPC_SMOKE_RESPONSE: u64 = 0x49504332; // "IPC2"

// EL0:n oma pino. Kernelin SP_EL1 säilyy exception-paluita varten.
pub export var init_stack: [4096]u8 align(16) linksection(".bss") = undefined;

pub extern fn aarch64_enter_init() callconv(.c) noreturn;

// Ensimmäinen oikea ARM64-userland entry. Se kulkee SVC-rajapinnan kautta.
pub export fn aarch64_init_entry() callconv(.c) noreturn {
    asm volatile ("mov w0, #0x4331; movk w0, #0x4950, lsl #16; mov x8, xzr; svc #0"
        :
        :
        : .{ .memory = true });

    asm volatile ("mov x0, #0; mov x8, #1; svc #0"
        :
        :
        : .{ .memory = true });
    while (true) asm volatile ("wfi" ::: .{ .memory = true });
}

// Vector assembly välittää ESR_EL1:n, ELR_EL1:n ja x8:n.
pub export fn aarch64_exception_sync(esr: u64, elr: u64, nr: u64) u64 {
    const ec = (esr >> 26) & 0x3f;
    // EC=0x15 = SVC instruction executed from AArch64 EL0.
    if (ec != 0x15) {
        while (true) asm volatile ("wfi" ::: .{ .memory = true });
    }

    switch (nr) {
        SYS_IPC_SMOKE => {
            uart.line("Zinux init EL0");
            uart.line("IPC request/response OK");
            asm volatile ("msr elr_el1, %[next]; isb"
                :
                : [next] "r" (elr + 4)
                : .{ .memory = true });
            return IPC_SMOKE_RESPONSE;
        },
        SYS_EXIT => {
            uart.line("Zinux init exit");
            semihost.exit(0);
        },
        else => while (true) asm volatile ("wfi" ::: .{ .memory = true }),
    }
}

test "minimal ARM64 syscall ABI is stable" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u64, 0), SYS_IPC_SMOKE);
    try testing.expectEqual(@as(u64, 1), SYS_EXIT);
    try testing.expectEqual(@as(u64, 0x49504332), IPC_SMOKE_RESPONSE);
}
