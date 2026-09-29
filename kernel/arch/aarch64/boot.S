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
    // Do not trap EL1/EL0 FP/SIMD to EL2 (CPTR_EL2.TFP = bit 10).
    // Without this, any compiler-emitted NEON faults as Undefined.
    mrs     x0, cptr_el2
    bic     x0, x0, #0x400
    msr     cptr_el2, x0
    // SPSR_EL2: all masks set + EL1h mode (0x3C5).
    mov     x0, #0x3c5
    msr     spsr_el2, x0
    adr     x0, .LinEL1
    msr     elr_el2, x0
    eret

.LinEL1:
    // Enable EL1/EL0 FP/SIMD (CPACR_EL1.FPEN = bits 21:20 = 0b11).
    // The guest runs compiler-generated Zig everywhere; scalar-only
    // codegen cannot be enforced, so the FPU is enabled rather than
    // trapped. FP context save/restore across service switches is a
    // later phase (no switch preserves q-regs yet).
    mrs     x0, cpacr_el1
    orr     x0, x0, #0x300000
    msr     cpacr_el1, x0
    isb
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
    // Aarch64ExceptionFrame: x0-x30, ESR_EL1, ELR_EL1, SPSR_EL1 (272 B).
    // Keep this in lockstep with exception_frame.zig and its offset test.
    sub     sp, sp, #272
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    mrs     x9, esr_el1
    str     x9, [sp, #248]
    mrs     x9, elr_el1
    str     x9, [sp, #256]
    mrs     x9, spsr_el1
    str     x9, [sp, #264]

    mov     x0, sp
    bl      aarch64_exception_sync
    ldr     x9, [sp, #256]
    msr     elr_el1, x9
    ldr     x9, [sp, #264]
    msr     spsr_el1, x9
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30, [sp, #240]
    add     sp, sp, #272
    eret

.Lvector_park:
    wfi
    b .Lvector_park
