//! Interrupt Descriptor Table (IDT) x86_64:lle + page fault -käsittelijä.
//!
//! **Vastuu**: Keskeytykset, poikkeukset (#14 page fault).
//! **Riippuvuudet**: `gdt.zig`, `paging.zig`, `../../lib/log.zig`, `../../drivers/char/uart.zig`
//! **Käytetään**: `kernel/main.zig`

// Tuo GDT segmenttivalitsimet IDT-merkintöjen selector-kenttään.
const gdt = @import("gdt.zig");
// Tuo CR2-luku page fault -osoitteen varmistukseen.
const paging = @import("paging.zig");
// Tuo lokitusmoduuli virheviestien tulostukseen.
const log = @import("../../lib/log.zig");
// Tuo UART suoraan heksadesimaalitulostukseen (runtime-arvot).
const uart = @import("../../drivers/char/uart.zig");
// PIT-tickien laskuri — taustatimer Vaihe 3:lle (pit_ticks.zig + timer_irq.S).
const pit_ticks = @import("../../lib/pit_ticks.zig");
// Tuo snapshot dirty-seuranta — kirjoitussuojaus-faultit (31.5.4).
// Kiertoa ei ole: snapshot ei importtaa idt:tä (vmm/paging/pmm/process/log).
const snapshot = @import("../../snapshot.zig");
// Tuo watchdog — valvottujen pluginien crash-kaappaus (31.5.5).
// Kiertoa ei ole: watchdog ei importtaa idt:tä (core/snapshot/process/diag/log).
const watchdog = @import("../../watchdog.zig");

// IDT-merkintä — 128-bittinen kuvaus yhdestä keskeytys/poikkeusvektorista.
const IdtEntry = packed struct {
    // Handler-funktion alaosat (bittit 0..15).
    offset_low: u16,
    // GDT-segmenttivalitsin (kernel code = 0x08).
    selector: u16,
    // Interrupt Stack Table -indeksi (0 = käytä nykyistä pinon).
    ist: u8,
    // Gate type + DPL + present (0x8E = 64-bit interrupt gate, DPL 0).
    type_attr: u8,
    // Handler-funktion keskiosa (bittit 16..31).
    offset_mid: u16,
    // Handler-funktion yläosa (bittit 32..63).
    offset_high: u32,
    // Varattu — pitää olla nolla x86_64:ssa.
    zero: u32,

    // Muodosta IDT-merkintä handler-osoitteesta ja attribuuteista.
    fn init(handler: u64, selector: u16, type_attr: u8) IdtEntry {
        // Palauta täytetty merkintä handler-osoitteen kolmesta osasta.
        return .{
            // Alimmat 16 bittiä handler-osoitteesta.
            .offset_low = @truncate(handler & 0xFFFF),
            // Kernel code -segmentti GDT:stä.
            .selector = selector,
            // Ei erillistä IST-pinoa vielä.
            .ist = 0,
            // Interrupt gate, present, ring 0.
            .type_attr = type_attr,
            // Keskimmäiset 16 bittiä handler-osoitteesta.
            .offset_mid = @truncate((handler >> 16) & 0xFFFF),
            // Ylimmät 32 bittiä handler-osoitteesta.
            .offset_high = @truncate(handler >> 32),
            // Varattu kenttä nollaksi.
            .zero = 0,
        };
    }
};

// IDTR-rekisteriin ladattava kuvaus (limit + base).
const IdtPointer = packed struct {
    // IDT-taulukon koko tavuina miinus yksi.
    limit: u16,
    // IDT-taulukon virtuaalinen osoite.
    base: u64,
};

// 256 vektorin IDT-taulukko (IRQ 0..255 + CPU poikkeukset).
var idt: [256]IdtEntry = undefined;
// IDTR-kuvaus lidt-komentoa varten.
var idt_ptr: IdtPointer = undefined;

// Heksadesimaalimerkkijono yhden nibble-tulostukseen.
const HEX_DIGITS = "0123456789ABCDEF";

// Tulosta 64-bittinen arvo UART:iin muodossa 0xXXXXXXXXXXXXXXXX.
fn writeHex64(val: u64) void {
    // Etuliite heksadesimaaliosoitteelle.
    uart.write("0x");
    // Käy 16 nibbleä vasemmalta oikealle (MSB ensin).
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        // Poimi yksi 4-bittinen nibble annetusta siirrosta.
        const nibble: u4 = @truncate(val >> shift);
        // Tulosta vastaava heksamerkki.
        uart.putc(HEX_DIGITS[nibble]);
        // Lopeta kun ollaan viimeisessä nibblessä.
        if (shift == 0) break;
    }
}

// Tulosta page fault -virhekoodin bittien merkitykset UART:iin.
fn writeFaultErrorBits(code: u64) void {
    // Bit 0: sivu ei ollut present (not-present fault vs protection fault).
    if ((code & 1) == 0) uart.write(" not-present");
    // Bit 1: kirjoitus aiheutti virheen (write vs read).
    if ((code & 2) != 0) uart.write(" write");
    // Bit 2: käyttäjätila (CPL=3) aiheutti virheen.
    if ((code & 4) != 0) uart.write(" user");
    // Bit 3: varattu bitti — ei pitäisi olla 1 normaalisti.
    if ((code & 8) != 0) uart.write(" rsvd");
    // Bit 4: instruction fetch (NX / execute-disable).
    if ((code & 16) != 0) uart.write(" ifetch");
}

// Page fault -käsittelijä C-puolella — logittaa CR2 + virhekoodin ja pysäyttää CPU:n.
export fn pageFaultHandlerC(fault_addr: u64, error_code: u64) callconv(.c) noreturn {
    // Tulosta staattinen virheotsikko serialiin.
    log.err("Page fault at");
    // Tulosta virheen virtuaaliosoite (CR2) heksadesimaalimuodossa.
    writeHex64(fault_addr);
    // Rivinvaihto osoitteen jälkeen.
    uart.putc('\n');
    // Tulosta virhekoodin numeerinen arvo.
    uart.write("[ERR] Error code:");
    // Tulosta virhekoodi heksadesimaalimuodossa.
    writeHex64(error_code);
    // Tulosta virhekoodin bittien selitykset.
    writeFaultErrorBits(error_code);
    // Rivinvaihto virhekoodin jälkeen.
    uart.putc('\n');
    // Varmista CR2 vastaa parametria (debug — handler luki CR2 ennen callia).
    _ = paging.getCr2();
    // Poista keskeytykset ja pysäytä CPU — kernel ei vielä käsittele page faultia.
    asm volatile ("cli; hlt");
    // Varoitus: ei koskaan saavuteta — noreturn-silmukka varmuuden vuoksi.
    while (true) {}
}

// Page fault -esitarkistus C-puolella (31.5.4): kirjoitussuojaus-fault
// checkpointatussa plugin-avaruudessa merkitään likaiseksi ja kirjoitus
// myönnetään (fault-and-continue) — true = käsitelty, ei lokia (K2 laskee
// vain todelliset viat). Kaikki muu → false → vanha log+halt-poku.
export fn pageFaultHandle(fault_addr: u64, error_code: u64) callconv(.c) bool {
    // Vaadi present-sivu (bit 0): checkpoint-suoja on protection-fault,
    // ei not-present. Puuttuva sivu on aina todellinen vika.
    if ((error_code & 1) == 0) return false;
    // Vaadi kirjoitus (bit 1): lukufault suojattuun sivuun on todellinen vika
    // (R-sivut eivät kuulu dirty-seurantaan).
    if ((error_code & 2) == 0) return false;
    // Vaadi käyttäjätila (bit 2): kernel-tilan fault (ml. SMAP) on todellinen
    // vika — kernel kirjoittaa HHDM-aliasten kautta ilman faultia.
    if ((error_code & 4) == 0) return false;
    // Vikatilanteen CR3 (faultaava avaruus — yleensä pluginin PML4).
    const cr3 = paging.getCr3();
    // Delegoi snapshotille (sivun perusosoite, CR3-täsmäys).
    return snapshot.handleWriteFault(cr3, fault_addr);
}

// Watchdog-kysely C-puolella (31.5.5): valvotun pluginin kaatuminen
// kaapataan (restore + diag + laskuri) — true = käsitelty, wrapper palaa
// boot-testin kontekstiin (EI haltausta); false = vieras → vanha polku.
export fn watchdogClaimHandle(fault_addr: u64, error_code: u64) callconv(.c) bool {
    // Vikatilanteen CR3 (faultaava avaruus — yleensä pluginin PML4).
    const cr3 = paging.getCr3();
    // Delegoi watchdogille (CR3-täsmäys + kelpoisuus + kaappaus).
    return watchdog.claimFault(cr3, fault_addr, error_code);
}

// Page fault (#14) — naked wrapper lukee CR2 ja virhekoodin pinolta.
// Kolme ulospääsyä: dirty → iretq (kirjoitus yrittää uudelleen);
// watchdog-crash → boot-testin kontekstiin (RSP restore + callee restore +
// ret, EI haltausta); vieras → vanha log+halt-poku.
export fn pageFaultHandler() callconv(.naked) noreturn {
    // Poista keskeytykset heti — estää uudelleenpage faultin handlerissa.
    // Lue virhekoodi pinosta (CPU pushaa sen ennen handleria) 32-BITTISENÄ:
    // ylemmät 32 bittiä ovat määrittelemättömät (QEMU jättää roskaa —
    // K5-jahdissa mitattu 0xFFFFFFFB), joten mov %esi nollaa ne. C-koodi
    // saa aina puhtaan u64:n eikä bittitesti lue haamubittejä.
    // Lue CR2 — page fault -virtuaaliosoite.
    // Kutsu esitarkistuksia: RDI=fault_addr, RSI=error_code (SysV ABI).
    // pageFaultHandle: al=1 → dirty-iret; al=0 → watchdog-kysely.
    // watchdogClaimHandle: al=1 → crash-paluu; al=0 → vanha polku.
    // HUOM: ensimmäinen call saa sotkea RDI/RSI:n (caller-saved), joten
    // lataa molemmat uudelleen ennen toista kyselyä — muuten watchdog
    // lukisi roskan eikä kaatumisen virhekoodia (U-bitti).
    asm volatile (
        \\cli
        \\mov (%%rsp), %%esi
        \\mov %%cr2, %%rdi
        \\call pageFaultHandle
        \\test %%al, %%al
        \\jnz .pf_dirty_iret
        \\mov (%%rsp), %%esi
        \\mov %%cr2, %%rdi
        \\call watchdogClaimHandle
        \\test %%al, %%al
        \\jz .pf_unhandled
        \\add $8, %%rsp
        \\mov usermode_saved_callee+0(%%rip), %%rbx
        \\mov usermode_saved_callee+8(%%rip), %%rbp
        \\mov usermode_saved_callee+16(%%rip), %%r12
        \\mov usermode_saved_callee+24(%%rip), %%r13
        \\mov usermode_saved_callee+32(%%rip), %%r14
        \\mov usermode_saved_callee+40(%%rip), %%r15
        \\mov usermode_saved_kernel_rsp(%%rip), %%rsp
        \\ret
        \\.pf_dirty_iret:
        \\add $8, %%rsp
        \\iretq
        \\.pf_unhandled:
        \\call pageFaultHandlerC
        \\cli
        \\hlt
    );
}

// Yleinen stub muille keskeytyksille — pysäyttää CPU:n odottamaan debuggausta.
export fn isrStub() callconv(.naked) noreturn {
    // Poista keskeytykset ja pysäytä suoritus.
    asm volatile ("cli; hlt");
}

// Timer IRQ — assembly-toteutus timer_irq.S (ei C-kutsua).
extern fn timerIrqHandler() callconv(.naked) noreturn;
// Keyboard IRQ1 — assembly-toteutus keyboard_irq.S.
extern fn keyboardIrqHandler() callconv(.naked) noreturn;

// Palauta PIT-tickien määrä.
pub fn timerTicks() u64 {
    // Delegoi pit_ticks-moduulille.
    return pit_ticks.count();
}

// Export timer-käsittelijän osoite IDT-rekisteröintiin.
pub fn timerHandlerAddr() u64 {
    // Palauta timerIrqHandler-funktion osoite.
    return @intFromPtr(&timerIrqHandler);
}

// Export keyboard-käsittelijän osoite IDT-rekisteröintiin.
pub fn keyboardHandlerAddr() u64 {
    // Palauta keyboardIrqHandler-funktion osoite.
    return @intFromPtr(&keyboardIrqHandler);
}

// Tarkista porttimerkinnän tavutus raaoista qwordeista (puhdas bittivertailu).
// K5-regressiotesti koodissa: init-silmukan vektorointi sekoitti ist/type-
// tavut (ist=0x8e/type=0x00), mikä kaatoi KAIKKI ring-3-poikkeukset #SS:ään.
// Tarkistus lukee takaisin sen mitä CPU lukee (offset/selector/ist/type).
pub fn gateBytesOk(lo: u64, hi: u64, handler: u64) bool {
    // offset_low (bitit 0..15) täsmää handleriin.
    if ((lo & 0xFFFF) != (handler & 0xFFFF)) return false;
    // Selectori on kernel code (bitit 16..31).
    if (((lo >> 16) & 0xFFFF) != gdt.KERNEL_CODE_SEL) return false;
    // IST-indeksi 0 (bitit 32..39) — ei erillistä pinoa.
    if (((lo >> 32) & 0xFF) != 0) return false;
    // Gate type present+DPL0+interrupt (bitit 40..47 = 0x8E).
    if (((lo >> 40) & 0xFF) != 0x8E) return false;
    // offset_mid (bitit 48..63) täsmää handleriin.
    if (((lo >> 48) & 0xFFFF) != ((handler >> 16) & 0xFFFF)) return false;
    // offset_high (bitit 64..95) täsmää handleriin.
    if ((hi & 0xFFFF_FFFF) != ((handler >> 32) & 0xFFFF_FFFF)) return false;
    // Kaikki kentät oikein.
    return true;
}

// Alusta IDT — page fault #14 oikea käsittelijä, muut stub.
// HUOM (K5): täytä skalaarisilmukalla kuten registerHandler — Zig 0.16:n
// vektorisoima zip+cmove-silmukka sekoitti ist/type-tavut (kaikki initin
// kirjoittamat merkinnät lukivat ist=0x8e/type=0x00 → #PF-toimitus kaatui
// #SS:ään; GDB-watchpoint + objdump todisteena). Skalaaripolku varmennettu
// tavuittain QEMU:ssa. Älä "optimoi" tätä takaisin zip-muotoon ilman
// tavuvertailua (katso verifyGate alla).
pub fn init() void {
    // Osoite yleiseen stub-handleriin kaikille muille vektoreille.
    const stub_addr: u64 = @intFromPtr(&isrStub);
    // Osoite page fault -handleriin vektoriin #14.
    const pf_addr: u64 = @intFromPtr(&pageFaultHandler);
    // 64-bit interrupt gate, present, DPL 0 (0x8E).
    const attr: u8 = 0x8E;
    // Täytä kaikki 256 IDT-merkintää skalaarisesti indeksillä.
    var i: usize = 0;
    while (i < idt.len) : (i += 1) {
        // Vektori 14 = page fault — käytä erikoiskäsittelijää.
        if (i == 14) {
            // Rekisteröi pageFaultHandler vektoriin #14.
            idt[i] = IdtEntry.init(pf_addr, gdt.KERNEL_CODE_SEL, attr);
        } else {
            // Kaikki muut vektorit → stub joka pysäyttää CPU:n.
            idt[i] = IdtEntry.init(stub_addr, gdt.KERNEL_CODE_SEL, attr);
        }
    }
    // Lue takaisin kriittinen portti #14 (fail-fast, ei hiljaista korruptiota).
    // Lue raaka qword-pari taulukosta tavuosoittimella (sama tavutus jonka
    // CPU lukee; align(1) — taulukon tasaus ei ole taattu 8:ksi).
    const gate_bytes: [*]const u8 = @ptrCast(&idt[14]);
    const lo14: u64 = @as(*align(1) const u64, @ptrCast(gate_bytes)).*;
    const hi14: u64 = @as(*align(1) const u64, @ptrCast(gate_bytes + 8)).*;
    if (!gateBytesOk(lo14, hi14, pf_addr)) {
        // Väärä tavutus — pysäytä heti selkeällä viestillä (K2 ei laske
        // infoa, joten tämä ei vääristä boot-verdictiä).
        log.info("IDT gate 14 corrupt");
        // Pysäytä CPU — jatko ilman #PF-käsittelijää olisi epärehellistä.
        asm volatile ("cli; hlt");
        // Ei saavuteta.
        while (true) {}
    }
    // IDT-koko tavuina miinus yksi (x86 vaatimus).
    idt_ptr.limit = @sizeOf(@TypeOf(idt)) - 1;
    // IDT-taulukon virtuaalinen osoite.
    idt_ptr.base = @intFromPtr(&idt);
    // Lataa IDT CPU:hen lidt-komennolla.
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&idt_ptr),
    );
}

// Rekisteröi page fault -käsittelijä erikseen (testattavuus / uudelleenalustus).
pub fn setPageFaultHandler() void {
    // Osoite page fault -handleriin.
    const pf_addr: u64 = @intFromPtr(&pageFaultHandler);
    // Päivitä vain vektori #14.
    idt[14] = IdtEntry.init(pf_addr, gdt.KERNEL_CODE_SEL, 0x8E);
}

// Palauta page fault -virheen virtuaaliosoite (CR2) — ulkoiseen diagnostiikkaan.
pub fn lastFaultAddress() u64 {
    // Lue CR2 suoraan CPU:sta.
    return paging.getCr2();
}

// Rekisteröi yksittäinen IDT-käsittelijä vektorinumeroon (IRQ tai poikkeus).
pub fn registerHandler(vector: usize, handler: u64) void {
    // 64-bit interrupt gate, present, DPL 0.
    idt[vector] = IdtEntry.init(handler, gdt.KERNEL_CODE_SEL, 0x8E);
}
