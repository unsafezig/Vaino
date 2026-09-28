/* linker.ld — Zinux ARM64 guestin muistikartta (QEMU `virt`, MMU pois)          */
/* QEMU `-kernel` lataa ELF-segmentit p_vaddr:iin; latauskanta 0x40080000.      */
/* (Sama konventio kuin Linux: TEXT_OFFSET 0x80000 RAM-kannasta 0x40000000.)    */

/* Kernelin sisääntulopiste — boot.S `_start` (.text.entry ensimmäisenä).       */
ENTRY(_start)

/* Latauskanta — 512 KiB RAM-kannan yläpuolella (DTB:lle + pinolle tilaa).      */
BASE = 0x40080000;

SECTIONS
{
    /* Kaikki sectionit sijoitetaan latauskannasta alkaen (fyysinen = virtuaalinen). */
    . = BASE;

    /* Sisääntulo ensin — QEMU hyppää ELF entryyn, mutta järjestys on selkeä.   */
    .text : {
        KEEP(*(.text.entry))
        *(.text .text.*)
    }

    /* Vain-luku-data (merkkijonot, vakiot).                                     */
    .rodata : {
        *(.rodata .rodata.*)
    }

    /* Alustettu data.                                                           */
    .data : {
        *(.data .data.*)
    }

    /* Nollattu data — boot.S nollaa tämän välin ennen kmainia.                  */
    __bss_start = .;
    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    }
    __bss_end = .;

    /* Poista debug- ja kommenttiosiot lopullisesta ELF:stä.                     */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
    }
}
