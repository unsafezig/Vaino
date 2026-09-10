/* userland/vsl/user.ld — VSL-plugin @ 0xFFFFFFFF90094000 */

/* Ring 3 VSL-plugin — oma LOAD-alue (vapaa: xfer loppuu 0x...93000). */
ENTRY(_start)

SECTIONS
{
    /* VSL:n virtuaalinen latausosoite — higher-half 4K-sivut. */
    . = 0xFFFFFFFF90094000;

    /* Suoritettava koodi (_start start.S:stä). */
    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    /* Vain-luku -data (VSL-viesti). */
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
