/* userland/crash_test/user.ld — crash-testi @ 0xFFFFFFFF90096000 */

/* Ring 3 crash-testi — oma LOAD-alue (vapaa: dirty loppuu ennen 0x...96000). */
ENTRY(_start)

SECTIONS
{
    /* Crash-testin virtuaalinen latausosoite — higher-half 4K-sivut. */
    . = 0xFFFFFFFF90096000;

    /* Suoritettava koodi (_start start.S:stä). */
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
