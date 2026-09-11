// Crash-test ELF — lue kartoittamatonta muistia (aito not-present #PF).
// global _start — kernelin ELF-loader hyppää tähän (ET_EXEC).
.global _start

_start:
    // Lataa kartoittamaton kanoninen osoite (ei PT:tä plugin-avaruudessa).
    movabs $0x1234000, %rax
    // Lue sieltä → not-present #PF ring 3:ssa (P=0,W=0,U=1).
    // Watchdog kaappaa (restore + diag + laskuri) ja palaa boot-testiin;
    // ilman watchdogia vanha log+halt-poku pysäyttäisi CPU:n.
    mov (%rax), %rax
    // Ei saavuteta kaapatussa ajossa (paluu boot-testiin, ei tänne).
    ud2
