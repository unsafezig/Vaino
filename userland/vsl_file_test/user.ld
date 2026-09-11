/* userland/vsl_file_test/user.ld — VSL file-I/O -demo @ 0xFFFFFFFF90097000 */

/* Ring 3 file-demo — oma LOAD-alue (vapaa: crash loppuu ennen 0x...97000). */
ENTRY(_start)

SECTIONS
{
    /* Demon virtuaalinen latausosoite — higher-half 4K-sivut. */
    . = 0xFFFFFFFF90097000;

    /* Suoritettava koodi (_start start.S:stä + Zig main). */
    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    /* Vain-luku -data. */
    .rodata : {
        *(.rodata .rodata.*)
    }

    /* Alustettu data. */
    .data : {
        *(.data .data.*)
    }

    /* Nollattu BSS. */
    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    }
}
