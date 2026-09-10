/* userland/dirty_test/user.ld — dirty-testi @ 0xFFFFFFFF90095000 */

/* Ring 3 dirty-testi — oma LOAD-alue (vapaa: VSL loppuu ennen 0x...95000). */
ENTRY(_start)

SECTIONS
{
    /* Dirty-testin virtuaalinen latausosoite — higher-half 4K-sivut. */
    . = 0xFFFFFFFF90095000;

    /* Suoritettava koodi (_start start.S:stä). */
    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    /* Vain-luku -data (dirty-viesti). */
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
