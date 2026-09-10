// Ring 3 siirtym ja paluu - iretq + ret.
// Vaihe 26: di=entry, si=user_stack_top, dx=user_cs, cx=user_ss,
//           r8=rflags, r9 cr3 (kohde-prosessin PML4 fysinen osoite).
.global usermodeEnterIret
.global usermodeReturnToKernel
.global usermode_saved_kernel_rsp
.global usermode_saved_callee
.global saved_kernel_cr3

usermodeEnterIret:
    // Tallenna kernel RSP ennen iretq-kehyksen rakentamista.
    mov %rsp, usermode_saved_kernel_rsp(%rip)
    // Tallenna callee-saved (K4): ring 3 + test_return-paluu eivät säilytä
    // näitä (syscall_entry.S:n popit ohitetaan), joten talletus/palautus
    // globaaliin taulukkoon (järjestys: rbx, rbp, r12, r13, r14, r15).
    mov %rbx, usermode_saved_callee+0(%rip)
    mov %rbp, usermode_saved_callee+8(%rip)
    mov %r12, usermode_saved_callee+16(%rip)
    mov %r13, usermode_saved_callee+24(%rip)
    mov %r14, usermode_saved_callee+32(%rip)
    mov %r15, usermode_saved_callee+40(%rip)
    // Vaihe 26: aseta CR3 = kohde-prosessin PML4 ennen iretq --
    //            varmistaa per-prosessi muisti-isolaatio user-tilassa.
    // r9:ss on cr3 (functioargumentti). Aseta aina CR3:han.
    mov %r9, %cr3
    // iretq pinon kehys (viimeinen push = RIP, popataan ensin).
    push %rcx
    push %rsi
    push %r8
    push %rdx
    push %rdi
    // Siirry ring 3:een.
    iretq

usermodeReturnToKernel:
    // Vaihe 26: palauta kernel CR3 ennen pinon vaihtoa, jotta kaik-
    // ki kernel-globalit (log, vmm...) ovat oikeilla osoitteilla.
    mov saved_kernel_cr3(%rip), %rax
    test %rax, %rax
    jz .skip_cr3_restore
    mov %rax, %cr3
.skip_cr3_restore:
    // Palauta callee-saved ennen pinon vaihtoa (K4 — plugin sotki nämä).
    mov usermode_saved_callee+0(%rip), %rbx
    mov usermode_saved_callee+8(%rip), %rbp
    mov usermode_saved_callee+16(%rip), %r12
    mov usermode_saved_callee+24(%rip), %r13
    mov usermode_saved_callee+32(%rip), %r14
    mov usermode_saved_callee+40(%rip), %r15
    // Palauta boot-pino ja hyppää runBootTest-jatkoon.
    mov usermode_saved_kernel_rsp(%rip), %rsp
    ret
