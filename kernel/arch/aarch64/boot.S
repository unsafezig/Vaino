// boot.S — Zinux ARM64 guest entry (QEMU `virt`, `-kernel` ELF boot).
//
// QEMU loads ELF segments at p_vaddr (linked at 0x40080000) and resets the
// primary CPU into EL2 (no EL3 on `virt` default). This stub:
//   1. parks secondary cores (MPIDR Aff0 != 0 -> WFE loop),
//   2. sets SP to the load base (stack grows down into the 512 KiB gap),
//   3. zeroes .bss,
//   //   4. drops EL2 -> EL1 (HCR_EL2.RW, SPSR_EL2, ERET) if needed,
//   5. calls aarch64_kmain (Zig, callconv(.c)) — never returns.

    .section .text.entry, "ax"
    .global _start
    .type _start, %function
_start:
    // Secondary cores park immediately (SMP bring-up is future work).
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbz     x0, .Lprimary
.Lpark:
    wfe
    b       .Lpark

.Lprimary:
    // Stack top = load base; RAM below is free (DTB lives at RAM base,
    // ~8 KiB — far below any realistic stack depth here).
    ldr     x0, =_start
    mov     sp, x0

    // Zero .bss ([__bss_start, __bss_end)).
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss:
    cmp     x0, x1
    b.hs    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss
.Lbss_done:

    // Which EL are we in? (CurrentEL bits [3:2].)
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #1
    b.eq    .LinEL1
    cmp     x0, #2
    b.ne    .Lpark          // EL3/EL0: unexpected — park, do not proceed.

    // EL2 -> EL1: EL1 is AArch64 (HCR_EL2.RW = bit 31).
    movz    x0, #0x8000, lsl #16
    msr     hcr_el2, x0
    // SPSR_EL2: all masks set + EL1h mode (0x3C5).
    mov     x0, #0x3c5
    msr     spsr_el2, x0
    adr     x0, .LinEL1
    msr     elr_el2, x0
    eret

.LinEL1:
    // ARM64 exception vectors: EL0 SVC requests return through EL1.
    ldr     x0, =aarch64_vectors
    msr     vbar_el1, x0
    isb
    bl      aarch64_kmain
    // kmain never returns; halt if it does.
.Lhalt:
    wfi
    b       .Lhalt
    .size _start, . - _start

// Enter the embedded init entry at EL0t. SP_EL1 remains the kernel exception
// stack; SP_EL0 is reserved for the init process.
    .text
    .global aarch64_enter_init
    .type aarch64_enter_init, %function
aarch64_enter_init:
    ldr     x0, =init_stack
    add     x0, x0, #4096
    msr     sp_el0, x0
    mov     x0, #0              // EL0t, interrupts enabled for now
    msr     spsr_el1, x0
    ldr     x0, =aarch64_init_entry
    msr     elr_el1, x0
    eret
    .size aarch64_enter_init, . - aarch64_enter_init

// VBAR_EL1 vector table. Only the lower-EL AArch64 synchronous vector is
// active in this milestone; all other entries park safely.
    .section .text.vectors, "ax"
    .align 11
    .global aarch64_vectors
    .type aarch64_vectors, %function
aarch64_vectors:
    .rept 8
    b .Lvector_park
    .space 124
    .endr

    // Vector index 8: synchronous exception from lower EL using AArch64.
    b .Lvector_lower_sync
    .space 124
    .rept 7
    b .Lvector_park
    .space 124
    .endr

.Lvector_lower_sync:
    // Preserve x1/x2 while x0..x2 become the C handler arguments.
    stp     x1, x2, [sp, #-16]!
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    mov     x2, x8
    bl      aarch64_exception_sync
    ldp     x1, x2, [sp], #16
    eret

.Lvector_park:
    wfi
    b .Lvector_park
