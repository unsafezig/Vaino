//! VFS-ydin — mount-taulukko, tiedostokahvat, open/read/close.
//!
//! **Vastuu**: Tiedostojärjestelmärajapinta ja polun reititys mount-prefixeihin.
//! **Riippuvuudet**: ei
//! **Käytetään**: `vfs.zig`, host-testit

// VFS-virheet — palautetaan open/read-polussa.
pub const VfsError = error{
    // Polkua ei löydy tai tiedostoa ei ole.
    NotFound,
    // Operaatio ei tuettu tälle FS:lle.
    NotSupported,
    // Polku tyhjä tai virheellinen.
    InvalidPath,
    // Avointen tiedostojen taulukko täynnä.
    TooManyFiles,
    // initCore() ei kutsuttu.
    NotInitialized,
    // Monta mountia — ei tilaa.
    TooManyMounts,
};

// Avoimen tiedoston kahva (indeksi open_files-taulukkoon).
pub const FileHandle = u32;
// Virheellinen kahva — close/open palauttaa tämän virhetilanteessa.
pub const INVALID_HANDLE: FileHandle = 0xFFFF_FFFF;
// Montako mount-prefiksiä tuetaan.
pub const MAX_MOUNTS: usize = 4;
// Montako avointa tiedostoa tuetaan.
pub const MAX_OPEN_FILES: usize = 16;
// Maksimi mount-prefixin pituus tavuina.
pub const MAX_PREFIX_LEN: usize = 32;

// Yksittäisen tiedostojärjestelmän operaatiot (tmpfs toteuttaa 6.4).
pub const FileSystemOps = struct {
    // Tiedostojärjestelmän nimi boot-logissa.
    name: []const u8,
    // Avaa tiedosto polusta — palauttaa FS-spesifinen solmu.
    open: *const fn (path: []const u8) VfsError!*anyopaque,
    // Lue data solmusta annetusta offsetista.
    read: *const fn (node: *anyopaque, buf: []u8, offset: u64) VfsError!usize,
    // Sulje solmu ja vapauta resurssit.
    close: *const fn (node: *anyopaque) void,
    // Kirjoita data solmuun offsetista — null = read-only FS (VSL-2 tmpfs
    // toteuttaa, testfs ei). Valinnainen jotta read-only FS:t eivät hajoa.
    write: ?*const fn (node: *anyopaque, buf: []const u8, offset: u64) VfsError!usize = null,
};

// Yksi rekisteröity mount (prefix + ops-vtable).
const MountEntry = struct {
    // Onko mount aktiivinen.
    used: bool,
    // Prefix merkkijonona (esim. "/test").
    prefix: [MAX_PREFIX_LEN]u8,
    // Prefixin pituus tavuina.
    prefix_len: usize,
    // Osoitin tiedostojärjestelmän operaatioihin.
    ops: *const FileSystemOps,
};

// Yksi avoin tiedosto — kahva viittaa tähän.
const OpenFile = struct {
    // Onko kahva käytössä.
    used: bool,
    // Mount-indeksi open_files-taulukossa.
    mount_idx: usize,
    // FS-spesifinen solmu (opaque).
    node: *anyopaque,
};

// Rekisteröidyt mountit.
var mounts: [MAX_MOUNTS]MountEntry = undefined;
// Montako mountia on käytössä.
var mount_count: usize = 0;
// Avoimet tiedostot kahvoittain.
var open_files: [MAX_OPEN_FILES]OpenFile = undefined;
// Onko ydin alustettu.
var initialized: bool = false;

// Nollaa mountit ja avoimet tiedostot.
pub fn initCore() void {
    // Tyhjennä mount-taulukko.
    for (&mounts) |*m| {
        // Merkitse vapaa.
        m.used = false;
        // Nollaa prefix-puskuri.
        @memset(&m.prefix, 0);
        // Ei prefixiä.
        m.prefix_len = 0;
        // Ei ops-vtablea.
        m.ops = undefined;
    }
    // Tyhjennä avointen tiedostojen taulukko.
    for (&open_files) |*f| {
        // Merkitse vapaa.
        f.used = false;
        // Ei mountia.
        f.mount_idx = 0;
        // Ei solmua.
        f.node = undefined;
    }
    // Nollaa laskurit.
    mount_count = 0;
    // Ydin valmis.
    initialized = true;
}

// Tarkista että polku alkaa '/' ja ei ole tyhjä.
fn validatePath(path: []const u8) VfsError!void {
    // Tyhjä polku — virhe.
    if (path.len == 0) return VfsError.InvalidPath;
    // Polun pitää alkaa slashilla.
    if (path[0] != '/') return VfsError.InvalidPath;
}

// Vertaa kaksi prefixiä — true jos path alkaa prefixillä ja seuraava on '/' tai loppu.
fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    // Polku lyhyempi kuin prefix — ei täsmää.
    if (path.len < prefix.len) return false;
    // Vertaa prefix tavu kerrallaan.
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        // Ero prefixissä.
        if (path[i] != prefix[i]) return false;
    }
    // Prefix täsmää — tarkista rajaus ("/tmp" vs "/tmp2").
    if (path.len == prefix.len) return true;
    // Seuraava merkki pitää olla '/' (esim. "/test/file").
    return path[prefix.len] == '/';
}

// Etsi pidempään osuvan mountin indeksi polulle.
fn findMountForPath(path: []const u8) ?usize {
    // Paras mount-indeksi (pisin prefix).
    var best_idx: ?usize = null;
    // Parhaan prefixin pituus.
    var best_len: usize = 0;
    // Käy kaikki mountit.
    var i: usize = 0;
    while (i < MAX_MOUNTS) : (i += 1) {
        // Ohita vapaa slot.
        if (!mounts[i].used) continue;
        // Prefix slice mount-merkinnästä.
        const prefix = mounts[i].prefix[0..mounts[i].prefix_len];
        // Täsmääkö polku tähän mountiin?
        if (!pathHasPrefix(path, prefix)) continue;
        // Valitse pidempi prefix (spesifisin mount).
        if (prefix.len > best_len) {
            // Päivitä paras.
            best_len = prefix.len;
            best_idx = i;
        }
    }
    // Palauta mount-indeksi tai null.
    return best_idx;
}

// Rekisteröi mount prefixillä ja ops-vtablella.
pub fn registerMount(prefix: []const u8, ops: *const FileSystemOps) VfsError!void {
    // Ydin alustettava ensin.
    if (!initialized) return VfsError.NotInitialized;
    // Prefix ei saa olla tyhjä.
    if (prefix.len == 0) return VfsError.InvalidPath;
    // Prefix pitää alkaa '/'.
    if (prefix[0] != '/') return VfsError.InvalidPath;
    // Prefix liian pitkä puskuriin.
    if (prefix.len >= MAX_PREFIX_LEN) return VfsError.InvalidPath;
    // Etsi vapaa mount-slotti.
    var slot: ?usize = null;
    var i: usize = 0;
    while (i < MAX_MOUNTS) : (i += 1) {
        // Vapaa slot?
        if (!mounts[i].used) {
            // Tallenna ensimmäinen vapaa.
            slot = i;
            break;
        }
    }
    // Ei tilaa uudelle mountille.
    const idx = slot orelse return VfsError.TooManyMounts;
    // Kopioi prefix taulukkoon.
    @memcpy(mounts[idx].prefix[0..prefix.len], prefix);
    // Tallenna pituus.
    mounts[idx].prefix_len = prefix.len;
    // Liitä ops-vtable.
    mounts[idx].ops = ops;
    // Merkitse käytössä.
    mounts[idx].used = true;
    // Kasvata mount-laskuria.
    mount_count += 1;
}

// Avaa tiedosto polusta — palauttaa kahvan.
pub fn open(path: []const u8) VfsError!FileHandle {
    // Ydin alustettava ensin.
    if (!initialized) return VfsError.NotInitialized;
    // Tarkista polun muoto.
    try validatePath(path);
    // Etsi mount polulle.
    const mount_idx = findMountForPath(path) orelse return VfsError.NotFound;
    // Mount-merkintä.
    const mount = &mounts[mount_idx];
    // Prefix slice.
    const prefix = mount.prefix[0..mount.prefix_len];
    // Polku mountin sisällä (prefixin jälkeen tai juuri "/").
    const inner = if (path.len == prefix.len)
        "/"
    else
        path[prefix.len..];
    // Delegoi FS:lle avaus.
    const node = try mount.ops.open(inner);
    // Etsi vapaa kahva-slotti.
    var h: usize = 0;
    while (h < MAX_OPEN_FILES) : (h += 1) {
        // Vapaa slot?
        if (!open_files[h].used) {
            // Tallenna avoin tiedosto.
            open_files[h].used = true;
            open_files[h].mount_idx = mount_idx;
            open_files[h].node = node;
            // Palauta kahva indeksinä.
            return @intCast(h);
        }
    }
    // Ei tilaa — sulje juuri avattu solmu.
    mount.ops.close(node);
    // Liikaa avoimia tiedostoja.
    return VfsError.TooManyFiles;
}

// Lue avoimesta tiedostosta offsetista.
pub fn read(handle: FileHandle, buf: []u8, offset: u64) VfsError!usize {
    // Ydin alustettava ensin.
    if (!initialized) return VfsError.NotInitialized;
    // Kahva indeksinä taulukkoon.
    const idx: usize = @intCast(handle);
    // Indeksi ulos rajojen?
    if (idx >= MAX_OPEN_FILES) return VfsError.NotFound;
    // Kahva ei käytössä?
    if (!open_files[idx].used) return VfsError.NotFound;
    // Mount ja solmu.
    const entry = &open_files[idx];
    const mount = &mounts[entry.mount_idx];
    // Delegoi FS:lle luku.
    return mount.ops.read(entry.node, buf, offset);
}

// Kirjoita avoimeen tiedostoon offsetista (VSL-2).
pub fn write(handle: FileHandle, buf: []const u8, offset: u64) VfsError!usize {
    // Ydin alustettava ensin.
    if (!initialized) return VfsError.NotInitialized;
    // Kahva indeksinä taulukkoon.
    const idx: usize = @intCast(handle);
    // Indeksi ulos rajojen?
    if (idx >= MAX_OPEN_FILES) return VfsError.NotFound;
    // Kahva ei käytössä?
    if (!open_files[idx].used) return VfsError.NotFound;
    // Mount ja solmu.
    const entry = &open_files[idx];
    const mount = &mounts[entry.mount_idx];
    // Read-only FS (write-op puuttuu) → NotSupported, ei hiljaista hylkäystä.
    const w = mount.ops.write orelse return VfsError.NotSupported;
    // Delegoi FS:lle kirjoitus.
    return w(entry.node, buf, offset);
}

// Sulje avoin tiedosto kahvalla.
pub fn close(handle: FileHandle) void {
    // Ydin alustettava — muuten ei mitään tehtävää.
    if (!initialized) return;
    // Kahva indeksinä.
    const idx: usize = @intCast(handle);
    // Indeksi ulos rajojen?
    if (idx >= MAX_OPEN_FILES) return;
    // Kahva ei käytössä?
    if (!open_files[idx].used) return;
    // Mount ja solmu ennen vapautusta.
    const entry = &open_files[idx];
    const mount = &mounts[entry.mount_idx];
    // Delegoi FS:lle sulkeminen.
    mount.ops.close(entry.node);
    // Merkitse kahva vapaaksi.
    entry.used = false;
}

// --- Boot/host-testin sisäänrakennettu test-FS ---

// Testitiedoston sisältö (5 tavua).
const TEST_FILE_DATA = "HELLO";
// Testitiedoston polku mountin sisällä.
const TEST_FILE_INNER = "/hello";

// Yksinkertainen testisolmu — vain staattinen data.
const TestNode = struct {
    // Viittaus dataan.
    data: []const u8,
};

// Test-FS solmu staista datasta.
var test_node = TestNode{ .data = TEST_FILE_DATA };

// Test-FS open — tunnistaa vain "/hello".
fn testFsOpen(path: []const u8) VfsError!*anyopaque {
    // Vertaa polkua odotettuun.
    if (path.len != TEST_FILE_INNER.len) return VfsError.NotFound;
    // Indeksi vertailussa.
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        // Merkki ei täsmää.
        if (path[i] != TEST_FILE_INNER[i]) return VfsError.NotFound;
    }
    // Palauta testisolmu opaque-muodossa.
    return @ptrCast(&test_node);
}

// Test-FS read — kopioi data offsetista.
fn testFsRead(node: *anyopaque, buf: []u8, offset: u64) VfsError!usize {
    // Palauta solmu TestNode-muotoon.
    const n: *TestNode = @ptrCast(@alignCast(node));
    // Offset yli datan?
    if (offset >= n.data.len) return 0;
    // Luettavissa oleva pituus.
    const avail = n.data.len - @as(usize, @intCast(offset));
    // Kopioi max buf.len tai avail.
    const ncopy = @min(buf.len, avail);
    // Kopioi tavut.
    @memcpy(buf[0..ncopy], n.data[@intCast(offset)..][0..ncopy]);
    // Palauta luettujen tavujen määrä.
    return ncopy;
}

// Test-FS close — ei vapautettavaa (staattinen solmu).
fn testFsClose(node: *anyopaque) void {
    // Ei heap-allokaatiota — tyhjä.
    _ = node;
}

// Test-FS ops-vtable boot/host-testeille.
pub const testFileSystemOps = FileSystemOps{
    // Nimi boot-logissa.
    .name = "testfs",
    // Avaa tiedosto.
    .open = testFsOpen,
    // Lue tiedosto.
    .read = testFsRead,
    // Sulje tiedosto.
    .close = testFsClose,
};

// Rekisteröi sisäänrakennettu test-FS mount "/test" alle.
pub fn registerTestMount() VfsError!void {
    // Mount testfs → /test.
    try registerMount("/test", &testFileSystemOps);
}

// Suorita open/read/close -kierros test-mountilla (host + boot).
pub fn runSelfTest() VfsError!void {
    // Alusta ydin puhtaaksi.
    initCore();
    // Rekisteröi test-mount.
    try registerTestMount();
    // Avaa /test/hello.
    const h = try open("/test/hello");
    // Puskuri luettavalle datalle.
    var buf: [32]u8 = undefined;
    // Lue alusta.
    const n = try read(h, &buf, 0);
    // Sulje kahva.
    close(h);
    // Odotettu 5 tavua.
    if (n != TEST_FILE_DATA.len) return VfsError.NotSupported;
    // Vertaa sisältö.
    var i: usize = 0;
    while (i < TEST_FILE_DATA.len) : (i += 1) {
        // Data ei täsmää.
        if (buf[i] != TEST_FILE_DATA[i]) return VfsError.NotSupported;
    }
}
