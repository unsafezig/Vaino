//! Global Descriptor Table (GDT) x86_64:lle.
//!
//! **Vastuu**: Luo kernel-segmentit ja lataa GDT CPU:hen.
//! **Riippuvuudet**: ei
//! **Käytetään**: `kernel/main.zig` kmain-alustuksessa (Vaihe 2)

// GDT-kuvaus: limit (16b) + base (24b) alaosat.
const GdtEntry = packed struct {
    // Segmentin koko alimmat 16 bittiä (limit_low).
    limit_low: u16,
    // Base-osoitteen alimmat 16 bittiä.
    base_low: u16,
    // Base-osoitteen bitit 16..23.
    base_mid: u8,
    // Access byte — present, DPL, type (code/data).
    access: u8,
    // Granularity + limit bitit 16..19 (4 KiB granularity yleensä).
    granularity: u8,
    // Base-osoitteen bitit 24..31.
    base_high: u8,

    // Muodosta GDT-merkintä annetuista kentistä.
    fn init(base: u32, limit: u32, access: u8, gran: u8) GdtEntry {
        // Palauta täytetty GDT-merkintä limit/base/access/gran -arvoista.
        return .{
            // Limit alimmat 16 bittiä.
            .limit_low = @truncate(limit & 0xFFFF),
            // Base alimmat 16 bittiä.
            .base_low = @truncate(base & 0xFFFF),
            // Base keskimmäiset 8 bittiä.
            .base_mid = @truncate((base >> 16) & 0xFF),
            // Access byte sellaisenaan.
            .access = access,
            // Limit ylimmät 4 bittiä + granularity-bitti.
            .granularity = @truncate(((limit >> 16) & 0x0F) | (gran & 0xF0)),
            // Base ylimmät 8 bittiä.
            .base_high = @truncate((base >> 24) & 0xFF),
        };
    }
};

// GDTR-rekisteriin ladattava kuvaus (limit + osoite).
const GdtPointer = packed struct {
    // GDT-taulukon koko tavuina miinus yksi.
    limit: u16,
    // GDT-taulukon 64-bittinen virtuaalinen osoite.
    base: u64,
};

// GDT-taulukko — 7 merkintää: null, kcode, kdata, udata, ucode, TSS (2 slotia).
var gdt: [7]GdtEntry = undefined;

// 64-bit TSS — ring 3 poikkeukset käyttävät rsp0:aa kernel-pinoksi.
// TARKKAA: packed, EI extern! Laitteiston TSS-asettelu on tiivis: reserved0
// (4B) + rsp0 (8B @ offset 4) + ... — extern-struct lisäisi 4 tavua täytettä
// reserved0:n jälkeen ja siirtäisi rsp0:n offsettiin 8, jolloin CPU lukisi
// roskaa (K5: ensimmäinen ring-3-poikkeus kaatui #SS:ään; GDB-watchpoint +
// QEMU-trace todisteena). Kaikki muut laitteistorakenteet ovat jo packed.
const Tss = packed struct {
    // Varattu — x86_64 TSS aloitus.
    reserved0: u32 = 0,
    // Ring 0 pinon yläreuna kun keskeytys tulee ring 3:sta.
    rsp0: u64 = 0,
    // Ring 1 pinon yläreuna (ei käytössä).
    rsp1: u64 = 0,
    // Ring 2 pinon yläreuna (ei käytössä).
    rsp2: u64 = 0,
    // Varattu.
    reserved1: u64 = 0,
    // IST1..7 — ei käytössä vielä.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    // Varattu.
    reserved2: u64 = 0,
    // Varattu.
    reserved3: u32 = 0,
    // I/O permission bitmap offset — tss-koko = ei bitmapia.
    iopb_offset: u16 = @sizeOf(Tss),
};

// TSS-rakenne — export ltr:lle.
var tss: Tss = .{};
// Ring 0 pinon tila — poikkeus ring 3:sta hyppää tähän pinoon.
var tss_stack: [4096]u8 align(16) linksection(".bss") = undefined;

// Palauta TSS ring-0 pinon tavu-slice canary-seurantaa varten.
pub fn tssStackSlice() []u8 {
    // Viittaus koko pinomuistialueeseen.
    return &tss_stack;
}

// TSS GDT-valitsin (indeksi 5 → 0x28) — korvaa Liminen TR=0x38.
pub const TSS_SEL: u16 = 0x28;

// Kirjoita 128-bittinen TSS-kuvaus GDT:hen (kaksi peräkkäistä merkintää).
fn setTssDescriptor(idx: usize, base: u64, limit: u32) void {
    // TSS-kuvauksen ensimmäinen puoli (indeksi idx).
    gdt[idx].limit_low = @truncate(limit);
    gdt[idx].base_low = @truncate(base);
    gdt[idx].base_mid = @truncate(base >> 16);
    gdt[idx].access = 0x89;
    gdt[idx].granularity = @truncate((limit >> 16) & 0x0F);
    gdt[idx].base_high = @truncate(base >> 24);
    // TSS-kuvauksen toinen puoli — base bitit 32..63.
    const upper: *u64 = @ptrCast(&gdt[idx + 1]);
    upper.* = @truncate(base >> 32);
}

// GDT-kuvaus jota lgdt-komento käyttää.
var gdt_ptr: GdtPointer = undefined;

// Segmenttivalitsimet (offsetit GDT:ssä * 8).
// Kernel code -segmentti (GDT indeksi 1 → 0x08).
pub const KERNEL_CODE_SEL: u16 = 0x08;
// Kernel data -segmentti (GDT indeksi 2 → 0x10).
pub const KERNEL_DATA_SEL: u16 = 0x10;
// User data -segmentti ring 3:lle (GDT indeksi 3 → 0x18) — SYSRET: base+8.
pub const USER_DATA_SEL: u16 = 0x18;
// User code -segmentti ring 3:lle (GDT indeksi 4 → 0x20) — SYSRET: base+16.
pub const USER_CODE_SEL: u16 = 0x20;

// Alusta GDT ja lataa se CPU:hen lgdt-komennolla.
pub fn init() void {
    // Nollamerkintä — pakollinen GDT:n ensimmäinen entry.
    gdt[0] = GdtEntry.init(0, 0, 0, 0);
    // Kernel code: present, ring 0, executable, readable (0x9A).
    gdt[1] = GdtEntry.init(0, 0, 0x9A, 0xA0);
    // Kernel data: present, ring 0, writable (0x92).
    gdt[2] = GdtEntry.init(0, 0, 0x92, 0xA0);
    // User data ennen user codea — SYSCALL/SYSRET vaatii SS=base+8, CS=base+16.
    gdt[3] = GdtEntry.init(0, 0, 0xF2, 0xA0);
    // User code: present, ring 3, executable (0xFA).
    gdt[4] = GdtEntry.init(0, 0, 0xFA, 0xA0);
    // TSS ring 0 -pino — poikkeukset ring 3:sta (iretq / page fault).
    tss.rsp0 = @intFromPtr(&tss_stack) + tss_stack.len;
    // TSS-kuvaus GDT-merkintöihin 5..6.
    setTssDescriptor(5, @intFromPtr(&tss), @sizeOf(Tss));
    // GDTR.limit = taulukon koko tavuina - 1.
    gdt_ptr.limit = @sizeOf(@TypeOf(gdt)) - 1;
    // GDTR.base = GDT-taulukon osoite muistissa.
    gdt_ptr.base = @intFromPtr(&gdt);
    // Lataa uusi GDT CPU:hen — aktivoi segmenttirekisterit seuraavalla far jump:lla tarvittaessa.
    asm volatile ("lgdt (%[ptr])"
        :
        : [ptr] "r" (&gdt_ptr),
    );
    // Lataa kernel data -segmentti SS:ään ja DS/ES:ään (FS/GS jätetään myöhemmin).
    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%ss
        :
        :
        : .{ .ax = true });
    // Lataa TSS — korvaa Liminen virheellinen TR=0x38 ring 3 -poikkeuksia varten.
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (@as(u16, TSS_SEL)),
    );
}
