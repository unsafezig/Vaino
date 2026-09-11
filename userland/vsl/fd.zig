//! VSL fd-taulu — Linux-fd-numerot → VSL-resurssit (VSL-2).
//!
//! **Vastuu**: Käyttäjätilan kirjanpito avoimista kuvaajista. Ei syscalleja,
//!   ei allokaatiota — kiinteä taulukko, puhdas logiikka, host-testattava
//!   (sama kaava kuin `linux_abi.zig`).
//! **Riippuvuudet**: ei
//! **Käytetään**: VSL-shell (`shell.zig`), host-testit, tuleva `openat`-shim.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Taulu on VSL:n omaa tilaa, ei kernel-objekti: kernel näkee vain
//!   tavallisia Zinux-syscalleja (read/write/mem_map). Siksi fd-numerot
//!   eivät vuoda kerneliin eikä taulu levennä scopea.
//! - VSL-2:ssa `file`-kind kartoittaa VFS-polkuun; varsinainen luku kulkee
//!   kernelin VFS-boot-polun kautta (boot-testi todistaa), ring-3
//!   `openat`-shim odottaa tiedosto-syscalleja (VSL-4). Rehellinen raja:
//!   `isIoReady(file)` on false kunnes kernel tarjoaa fd-pohjaisen
//!   tiedostoluvun ring-3:lle — taulu ei valehtele tuesta.
//! - fd 0/1/2 on varattu konsolille (stdin/stdout/stderr), kuten Linuxissa.

// fd-taulun virheet — Linux-tyyliin (negatiiviset errno boot/shim-puolella).
pub const FdError = error{
    // Taulukko täynnä (kaikki slotit käytössä).
    TooManyOpen,
    // Huono fd-numero (vapaa tai rajojen ulkopuolella).
    BadFd,
    // Polku tyhjä tai ei ala '/'.
    BadPath,
    // Kind ei tue pyydettyä operaatiota.
    NotSupported,
};

// Montako kuvaajaa VSL pitää auki (VFS MAX_OPEN_FILES -pariteetti).
pub const MAX_FDS: usize = 16;
// stdin/stdout/stderr — varatut, aina auki.
pub const FD_STDIN: u32 = 0;
pub const FD_STDOUT: u32 = 1;
pub const FD_STDERR: u32 = 2;
// Ensimmäinen jaettava fd autogeneroiduille kuvaajille.
pub const FD_FIRST_FREE: u32 = 3;
// Tallennetun polun maksimipituus (tmpfs MAX_NAME_LEN -pariteetti).
pub const MAX_FD_PATH: usize = 64;

// Kuvaajan kind — mihin resurssiin fd on sidottu.
pub const FdKind = enum {
    // Konsoli: stdin (read) / stdout+stderr (write) UART-syscalleilla.
    console,
    // VFS-tiedosto: polku kernelin VFS:ään (boot-polku todistaa VSL-2:ssa).
    file,
    // Putki: tuleva IPC-portti (VSL-4, nyt vain varaus).
    pipe,
};

// Yksi avoin kuvaaja taulukossa.
pub const FdEntry = struct {
    // Onko slotti käytössä.
    used: bool,
    // Resurssikind.
    kind: FdKind,
    // Sidottu polku (file-kindillä), muuten tyhjä.
    path: [MAX_FD_PATH]u8,
    // Polun pituus tavuina.
    path_len: usize,
    // Luku/kirjoitus-offset tavuina.
    offset: u64,
    // Kernelin VFS-kahva (file-kindillä, INVALID ennen sidontaa).
    handle: u32,
};

// Sitomaton kahva — file-fd ei I/O-valmis ennen kernel-avausta.
pub const INVALID_HANDLE: u32 = 0xFFFF_FFFF;

// Kuvaajataulukko — indeksi == fd-numero (0..15).
var table: [MAX_FDS]FdEntry = undefined;
// Onko taulukko alustettu (konsoli-fd:t varattu).
var initialized: bool = false;

// Nollaa taulukko ja varaa 0/1/2 konsolille.
pub fn initTable() void {
    // Tyhjennä jokainen slotti.
    for (&table) |*e| {
        // Merkitse vapaa.
        e.used = false;
        // Oletuskind konsoli (korvataan avauksessa).
        e.kind = .console;
        // Nollaa polkupuskuri.
        @memset(&e.path, 0);
        // Ei polkua.
        e.path_len = 0;
        // Offset nollasta.
        e.offset = 0;
        // Ei kernel-kahvaa.
        e.handle = INVALID_HANDLE;
    }
    // Varatut konsolikuvaajat aina auki.
    table[FD_STDIN].used = true;
    table[FD_STDOUT].used = true;
    table[FD_STDERR].used = true;
    // Alustettu.
    initialized = true;
}

// Tarkista polun muoto (ei-tyhjä, alkaa '/', mahtuu puskuriin).
fn validatePath(path: []const u8) FdError!void {
    // Tyhjä polku — virhe.
    if (path.len == 0) return FdError.BadPath;
    // Absoluuttinen polku vaaditaan (kuten VFS).
    if (path[0] != '/') return FdError.BadPath;
    // Liian pitkä puskuriin.
    if (path.len >= MAX_FD_PATH) return FdError.BadPath;
}

// Avaa polku file-kuvaajaksi — palauttaa fd-numeron (≥3).
pub fn openFile(path: []const u8) FdError!u32 {
    // Taulukko alustettava ensin (konsolit varattu).
    if (!initialized) return FdError.BadFd;
    // Tarkista polku ennen slotin varausta (halpa → kallis).
    try validatePath(path);
    // Etsi vapaa slotti alkaen FD_FIRST_FREE:stä (0..2 varattu).
    var i: u32 = FD_FIRST_FREE;
    while (i < MAX_FDS) : (i += 1) {
        // Vapaa slotti löytyi.
        if (!table[i].used) {
            // Merkitse käytetyksi file-kindillä.
            table[i].used = true;
            table[i].kind = .file;
            // Kopioi polku slottiin.
            @memcpy(table[i].path[0..path.len], path);
            table[i].path_len = path.len;
            // Offset alusta.
            table[i].offset = 0;
            // Ei kernel-kahvaa vielä (shim sitoo sys_vfs_open-paluusta).
            table[i].handle = INVALID_HANDLE;
            // Palauta fd-numero.
            return i;
        }
    }
    // Ei vapaata slottia.
    return FdError.TooManyOpen;
}

// Sulje kuvaaja — varatut konsolit (0..2) eivät sulkeudu.
pub fn closeFd(fd: u32) FdError!void {
    // Taulukko alustettava ensin.
    if (!initialized) return FdError.BadFd;
    // Konsolikuvaajat pysyvät auki (Linux-pariteetti: sulkeminen on no-op
    // VSL-2:ssa — ei virhettä, jotta shellin cleanup ei kaadu).
    if (fd <= FD_STDERR) return;
    // Rajojen ulkopuolella.
    if (fd >= MAX_FDS) return FdError.BadFd;
    // Vapaa slotti — ei mitään suljettavaa.
    if (!table[fd].used) return FdError.BadFd;
    // Vapauta slotti (polku nollataan seuraavassa avauksessa).
    table[fd].used = false;
    table[fd].path_len = 0;
    table[fd].offset = 0;
    // Katkaise kernel-sidonta (kahva vapautettu syscallilla erikseen).
    table[fd].handle = INVALID_HANDLE;
}

// Hae kuvaajan kind — BadFd jos vapaa/alustamaton/rajat ulkona.
pub fn kindOf(fd: u32) FdError!FdKind {
    // Taulukko alustettava ensin.
    if (!initialized) return FdError.BadFd;
    // Rajojen ulkopuolella.
    if (fd >= MAX_FDS) return FdError.BadFd;
    // Vapaa slotti.
    if (!table[fd].used) return FdError.BadFd;
    // Palauta kind.
    return table[fd].kind;
}

// Sido kernelin VFS-kahva file-kuvaajaan (shim sys_vfs_open-paluusta).
// Vain file-kind sitoo; konsoli/pipe hylkäävät (väärä kerros).
pub fn bindHandle(fd: u32, handle: u32) FdError!void {
    // Taulukko alustettava ensin.
    if (!initialized) return FdError.BadFd;
    // Rajojen ulkopuolella.
    if (fd >= MAX_FDS) return FdError.BadFd;
    // Vapaa slotti.
    if (!table[fd].used) return FdError.BadFd;
    // Vain file-kind kantaa kernel-kahvaa.
    if (table[fd].kind != .file) return FdError.NotSupported;
    // Tallenna kahva.
    table[fd].handle = handle;
}

// Lue kuvaajan kernel-kahva — BadFd jos vapaa/rajat ulkona, INVALID_HANDLE
// jos file avattu mutta kernel-avaus tekemättä.
pub fn handleOf(fd: u32) FdError!u32 {
    // Taulukko alustettava ensin.
    if (!initialized) return FdError.BadFd;
    // Rajojen ulkopuolella.
    if (fd >= MAX_FDS) return FdError.BadFd;
    // Vapaa slotti.
    if (!table[fd].used) return FdError.BadFd;
    // Palauta kahva (konsolilla aina INVALID — niillä ei ole VFS-kahvaa).
    return table[fd].handle;
}

// Lue kuvaajan offset (shimmin sequentiaalilukuun).
pub fn tableOffset(fd: u32) FdError!u64 {
    // Taulukko alustettava ensin.
    if (!initialized) return FdError.BadFd;
    // Rajojen ulkopuolella.
    if (fd >= MAX_FDS) return FdError.BadFd;
    // Vapaa slotti.
    if (!table[fd].used) return FdError.BadFd;
    // Palauta offset.
    return table[fd].offset;
}

// Siirrä kuvaajan offsettia luetuilla tavuilla (saturaatio, ei kierrosta).
// Puhdas apu shimmin sequentiaaliluvulle — host-testattava ilman syscalleja.
pub fn advanceOffset(fd: u32, n: u64) FdError!void {
    // Taulukko alustettava ensin.
    if (!initialized) return FdError.BadFd;
    // Rajojen ulkopuolella.
    if (fd >= MAX_FDS) return FdError.BadFd;
    // Vapaa slotti.
    if (!table[fd].used) return FdError.BadFd;
    // Siirrä kattoon asti.
    table[fd].offset +|= n;
}

// Onko kuvaaja I/O-valmis ring-3-polulla?
// Konsoli kyllä (UART-syscallit 1/11); file kyllä vasta kernel-kahvan
// sidonnan jälkeen (VSL-4A) — boot-testi todistaa VFS-polun ring-3:sta.
// Sidomaton file valehtelisi tuesta, joten se on yhä ei-valmis.
pub fn isIoReady(fd: u32) bool {
    // Kind ratkaisee; tuntematon fd → ei valmis.
    const k = kindOf(fd) catch return false;
    return switch (k) {
        // Konsoli-I/O toimii ring-3:sta asti.
        .console => true,
        // Tiedosto-I/O vaatii sidotun kernel-kahvan.
        .file => table[fd].handle != INVALID_HANDLE,
        // Putki odottaa portti-sidontaa (VSL-4).
        .pipe => false,
    };
}

// Montako kuvaajaa auki (konsolit mukaan lukien).
pub fn openCount() usize {
    // Alustamaton → nolla.
    if (!initialized) return 0;
    // Laskuri.
    var n: usize = 0;
    // Käy taulukko.
    for (table) |e| {
        // Käytössä → laske.
        if (e.used) n += 1;
    }
    // Palauta määrä.
    return n;
}
