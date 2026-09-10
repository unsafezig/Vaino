// Dirty-test ELF — kirjoita omaan pinoon (W=0-fault!) + sys_write + return.
// global _start — kernelin ELF-loader hyppää tähän (ET_EXEC).
.global _start

_start:
    // Kirjoita 8 tavua omaan pinomuistiin RSP:n alle (suojattu sivu
    // checkpointin jälkeen → aito #PF ring 3:ssa → dirty-merkintä).
    movabs $0x1122334455667788, %rax
    // Tallenna pinon huipun alle (loaderin kartoittama pinosivu).
    mov %rax, -8(%rsp)
    // sys_write(1, msg, 4) — RAX = SYS_write (1).
    mov $1, %rax
    // fd = stdout (UART).
    mov $1, %rdi
    // Merkkijono .rodata:ssa.
    lea msg(%rip), %rsi
    // Neljä tavua "dty\n" (jatkuvuustodiste faultin jälkeen).
    mov $4, %rdx
    // Siirry kerneliin SYSCALL:lla.
    syscall
    // SYS_test_return (10) — palaa kerneliin (plugin run jatkuu).
    mov $10, %rax
    // Ei argumentteja.
    xor %rdi, %rdi
    // Paluu dirty boot-testiin.
    syscall
    // Ei saavuteta.
    ud2

msg:
    // Odotettu serial-tulos: dirty-plugin selvisi faultista.
    .ascii "dty\n"
