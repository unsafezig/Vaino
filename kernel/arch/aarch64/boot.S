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
    bl      aarch64_kmain
    // kmain never returns; halt if it does.
.Lhalt:
    wfi
    b       .Lhalt
    .size _start, . - _start
