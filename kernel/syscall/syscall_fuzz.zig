//! Syscall-fuzz — boot-aikainen dispatch-rajapinnan fuzz-testi.
//!
//! **Vastuu**: Kutsu invoke() satunnaisilla numeroilla, varmista ENOSYS/EBADF.
//! **Riippuvuudet**: `syscall_fuzz_core.zig`, `dispatch.zig`, log
//! **Käytetään**: `kernel/main.zig`

// Tuo fuzz-ydin — odotukset ja LCG.
const core = @import("syscall_fuzz_core.zig");
// Tuo jaettu ABI — virhekoodit vertailuun.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3.
const dispatch = @import("dispatch.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Lue RDTSC entropiaa fuzz-seedille.
fn readRdtsc() u64 {
    // RDTSC palauttaa EDX:EAX.
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    // Suorita RDTSC inline (freestanding: muistitulokset).
    asm volatile (
        \\rdtsc
        \\mov %%eax, %[l]
        \\mov %%edx, %[h]
        : [l] "=m" (lo),
          [h] "=m" (hi),
        :
        : .{ .rax = true, .rdx = true, .memory = true });
    // Yhdistä 64-bit arvoksi.
    return (@as(u64, hi) << 32) | lo;
}

// Aja yksi fuzz-kierros — palauta true jos tulos odotettu.
fn fuzzOne(seed: *u64, enosys_hits: *usize) bool {
    // Satunnainen syscall-numero.
    const num = core.fuzzSyscallNum(seed);
    // Ohita vaaralliset (exit, read, user ptr, …).
    if (core.isDangerous(num)) return true;
    // Satunnaiset argumentit — ei dereferoida user-osoitteita turvallisesti.
    const a1 = core.fuzzArg(seed);
    const a2 = core.fuzzArg(seed);
    const a3 = core.fuzzArg(seed);
    const a4 = core.fuzzArg(seed);
    const a5 = core.fuzzArg(seed);
    const a6 = core.fuzzArg(seed);
    // sys_write len>0 dereferoi — pakota len=0 tai huono fd.
    const safe_a3 = if (num == abi.SYS_write) @as(u64, 0) else a3;
    const safe_a1 = if (num == abi.SYS_write) a1 else a1;
    // Kutsu dispatch invoke.
    const ret = dispatch.invoke(num, safe_a1, a2, safe_a3, a4, a5, a6);
    // Odottamaton ENOSYS → virhe.
    if (core.expectEnosys(num)) {
        // Laske ENOSYS-osumat.
        if (core.isEnosys(ret)) enosys_hits.* += 1;
        // Pitää olla ENOSYS.
        return core.isEnosys(ret);
    }
    // Rekisteröity turvallinen — hyväksy getpid tai muu stub.
    if (num == abi.SYS_getpid) return ret == 1;
    // sys_write — hyväksy EBADF (huono fd) tai 0 (len=0).
    if (num == abi.SYS_write) return ret == abi.EBADF or ret == 0;
    // Muu rekisteröity ei vaarallinen — ei pitäisi tapahtua.
    return false;
}

// Tarkista kaikki taulukon ulkopuoliset numerot palauttavat ENOSYS.
fn fuzzOutOfRange() bool {
    // Testattavat ulko-rajat (33 = ensimmäinen tyhjä slotti 33-kokoisessa
    // taulukossa — VSL-4B kasvatti 32:sta; 32 on nyt sys_plugin_trap).
    const nums = [_]u64{ 33, 64, 100, 0xFFFF, 0xFFFFFFFF };
    // Käy jokainen.
    for (nums) |num| {
        // invoke(0-arg) pitää palauttaa ENOSYS.
        const ret = dispatch.invoke(num, 0, 0, 0, 0, 0, 0);
        // Ei ENOSYS → epäonnistuminen.
        if (!core.isEnosys(ret)) return false;
    }
    // Kaikki OK.
    return true;
}

// Tarkista rekisteröimättömät slotit 0..31 palauttavat ENOSYS.
fn fuzzEmptySlots() bool {
    // Käy slotit 0..31.
    var num: u64 = 0;
    while (num < core.TABLE_SIZE) : (num += 1) {
        // Ohita rekisteröidyt.
        if (core.isRegistered(num)) continue;
        // Tyhjän slotin pitää palauttaa ENOSYS.
        const ret = dispatch.invoke(num, 0, 0, 0, 0, 0, 0);
        if (!core.isEnosys(ret)) return false;
    }
    // Kaikki tyhjät slotit OK.
    return true;
}

// Boot-testi — fuzzaa syscall dispatch -rajapintaa.
pub fn runBootTest() void {
    // Ulko-rajat ENOSYS.
    if (!fuzzOutOfRange()) {
        // Taulukon ulkopuoliset eivät palauta ENOSYS.
        log.err("Syscall fuzz out-of-range failed");
        return;
    }
    // Tyhjät slotit ENOSYS.
    if (!fuzzEmptySlots()) {
        // Rekisteröimätön slotti palautti handlerin.
        log.err("Syscall fuzz empty slot failed");
        return;
    }
    // Satunnainen fuzz LCG:llä.
    var seed: u64 = readRdtsc() | 1;
    // ENOSYS-osumien laskuri.
    var enosys_hits: usize = 0;
    // Aja FUZZ_ROUNDS kierrosta.
    var round: usize = 0;
    while (round < core.FUZZ_ROUNDS) : (round += 1) {
        // Yksi fuzz-kierros.
        if (!fuzzOne(&seed, &enosys_hits)) {
            // Odottamaton paluuarvo.
            log.err("Syscall fuzz round failed");
            return;
        }
    }
    // Tarpeeksi ENOSYS-osumia satunnaisfuzzissa.
    if (!core.bootFuzzOk(enosys_hits)) {
        // Liian vähän tuntemattomia hylätty.
        log.err("Syscall fuzz ENOSYS count low");
        return;
    }
    // Kaikki fuzz-testit OK.
    log.info("Syscall fuzz OK");
}
