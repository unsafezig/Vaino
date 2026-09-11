// Käyttäjätilan VSL file-I/O -demo — hyppää Zig vslFileMain:iin.
.global _start
.extern vslFileMain

_start:
    // Kutsu Zig file-demo (open/read/close shimmin kautta).
    call vslFileMain
    // Ei saavuteta — vslFileMain kutsuu sys_test_return.
    ud2
