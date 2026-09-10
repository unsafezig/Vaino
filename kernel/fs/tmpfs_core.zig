//! tmpfs-ydin — RAM-pohjainen tiedostotaulukko (host-testattava).
//!
//! **Vastuu**: Kiinteä taulukko tiedostoja, open/read/close ilman VFS-riippuvuutta.
//! **Riippuvuudet**: ei
//! **Käytetään**: `tmpfs.zig`, host-testit

// tmpfs-virheet — vastaavat VFS-virheitä mount-wrapperissa.
pub const TmpfsError = error{
    // Polkua / tiedostoa ei löydy.
    NotFound,
    // Operaatio ei tuettu (liian suuri sisältö tms.).
    NotSupported,
    // Polku tyhjä tai virheellinen.
    InvalidPath,
    // Tiedostotaulukko täynnä.
    TooManyFiles,
    // initCore() ei kutsuttu.
    NotInitialized,
};

// Montako tiedostoa tmpfs voi pitää muistissa.
pub const MAX_FILES: usize = 8;
// Montako tavua tiedoston polku voi olla (mountin sisäinen polku).
pub const MAX_NAME_LEN: usize = 64;
// Montako tavua yhden tiedoston sisältö voi olla.
pub const MAX_FILE_DATA: usize = 256;

// Yksi tmpfs-tiedosto kiinteässä taulukossa.
pub const TmpfsFile = struct {
    // Onko slotti käytössä.
    used: bool,
    // Tiedoston polku mountin sisällä (esim. "/welcome").
    name: [MAX_NAME_LEN]u8,
    // Polun pituus tavuina.
    name_len: usize,
    // Tiedoston sisältö RAM-puskurissa.
    data: [MAX_FILE_DATA]u8,
    // Sisällön pituus tavuina.
    data_len: usize,
};

// Kaikki tmpfs-tiedostot — indeksi pysyy vakiona avauksessa.
var files: [MAX_FILES]TmpfsFile = undefined;
// Montako tiedostoa taulukossa.
var file_count: usize = 0;
// Onko tmpfs alustettu.
var initialized: bool = false;

// Nollaa tiedostotaulukko.
pub fn initCore() void {
    // Tyhjennä jokainen slotti.
    for (&files) |*f| {
        // Merkitse vapaa.
        f.used = false;
        // Nollaa polkupuskuri.
        @memset(&f.name, 0);
        // Ei polkua.
        f.name_len = 0;
        // Nollaa datapuskuri.
        @memset(&f.data, 0);
        // Ei dataa.
        f.data_len = 0;
    }
    // Nollaa laskuri.
    file_count = 0;
    // Valmis lisäyksiin.
    initialized = true;
}

// Tarkista mountin sisäinen polku (alkaa '/', ei tyhjä).
fn validateInnerPath(path: []const u8) TmpfsError!void {
    // Tyhjä polku — virhe.
    if (path.len == 0) return TmpfsError.InvalidPath;
    // Polun pitää alkaa slashilla.
    if (path[0] != '/') return TmpfsError.InvalidPath;
    // Liian pitkä puskuriin.
    if (path.len >= MAX_NAME_LEN) return TmpfsError.InvalidPath;
}

// Etsi tiedosto polulla — palauttaa osoittimen tai null.
fn findFile(path: []const u8) ?*TmpfsFile {
    // Käy kaikki slotit.
    var i: usize = 0;
    while (i < MAX_FILES) : (i += 1) {
        // Ohita vapaa slotti.
        if (!files[i].used) continue;
        // Pituus ei täsmää → eri polku.
        if (files[i].name_len != path.len) continue;
        // Vertaa polku tavu kerrallaan.
        var j: usize = 0;
        var match = true;
        while (j < path.len) : (j += 1) {
            // Ero polussa.
            if (files[i].name[j] != path[j]) match = false;
        }
        // Täsmää → palauta osoitin.
        if (match) return &files[i];
    }
    // Ei löytynyt.
    return null;
}

// Lisää tiedosto polulla ja sisällöllä (kopioi puskureihin).
pub fn addFile(path: []const u8, content: []const u8) TmpfsError!void {
    // tmpfs pitää olla alustettu.
    if (!initialized) return TmpfsError.NotInitialized;
    // Tarkista polun muoto.
    try validateInnerPath(path);
    // Sisältö liian suuri.
    if (content.len > MAX_FILE_DATA) return TmpfsError.NotSupported;
    // Tiedosto jo olemassa?
    if (findFile(path) != null) return TmpfsError.NotSupported;
    // Etsi vapaa slotti.
    var slot: ?usize = null;
    var i: usize = 0;
    while (i < MAX_FILES) : (i += 1) {
        // Vapaa?
        if (!files[i].used) {
            // Tallenna ensimmäinen vapaa.
            slot = i;
            break;
        }
    }
    // Taulukko täynnä.
    const idx = slot orelse return TmpfsError.TooManyFiles;
    // Kopioi polku slottiin.
    @memcpy(files[idx].name[0..path.len], path);
    // Tallenna polun pituus.
    files[idx].name_len = path.len;
    // Kopioi sisältö slottiin.
    if (content.len > 0) {
        // Vähintään yksi tavu kopioitavana.
        @memcpy(files[idx].data[0..content.len], content);
    }
    // Tallenna datan pituus.
    files[idx].data_len = content.len;
    // Merkitse slotti käytössä.
    files[idx].used = true;
    // Kasvata tiedostolaskuria.
    file_count += 1;
}

// Avaa tiedosto polusta — palauttaa solmuosoitin.
pub fn open(path: []const u8) TmpfsError!*TmpfsFile {
    // tmpfs pitää olla alustettu.
    if (!initialized) return TmpfsError.NotInitialized;
    // Tarkista polun muoto.
    try validateInnerPath(path);
    // Etsi tiedosto taulukosta.
    return findFile(path) orelse TmpfsError.NotFound;
}

// Lue tiedoston sisältö offsetista puskuriin.
pub fn read(file: *TmpfsFile, buf: []u8, offset: u64) TmpfsError!usize {
    // Offset yli tiedoston?
    if (offset >= file.data_len) return 0;
    // Luettavissa olevat tavut offsetista loppuun.
    const avail = file.data_len - @as(usize, @intCast(offset));
    // Kopioi enintään puskurin koko.
    const ncopy = @min(buf.len, avail);
    // Kopioi data ulos.
    @memcpy(buf[0..ncopy], file.data[@intCast(offset)..][0..ncopy]);
    // Palauta luettujen tavujen määrä.
    return ncopy;
}

// Sulje tiedosto — staattinen taulukko, ei vapautusta.
pub fn close(file: *TmpfsFile) void {
    // Solmu pysyy taulukossa — VFS vapauttaa kahvan.
    _ = file;
}

// Kirjoita tiedostoon offsetista — luo aukkoja nollilla, rajaa MAX_FILE_DATA:aan.
// Ylikirjoittaa olemassaolevaa tai jatkaa loppua; liian suuri → NotSupported
// (ei hiljaista katkaisua — kutsuja saa vastalauseen).
pub fn writeFile(path: []const u8, buf: []const u8, offset: u64) TmpfsError!usize {
    // tmpfs pitää olla alustettu.
    if (!initialized) return TmpfsError.NotInitialized;
    // Tarkista polun muoto.
    try validateInnerPath(path);
    // Etsi olemassaoleva tiedosto.
    const file = findFile(path) orelse return TmpfsError.NotFound;
    // Offset yli sisällön → aukko nollataan (harva kirjoitus, rajattu).
    const off: usize = @intCast(offset);
    // Aukko + data ei mahdu puskuriin → NotSupported.
    if (off > MAX_FILE_DATA) return TmpfsError.NotSupported;
    if (off + buf.len > MAX_FILE_DATA) return TmpfsError.NotSupported;
    // Nollaa aukko vanhan lopun ja offsetin väliltä.
    while (file.data_len < off) : (file.data_len += 1) {
        // Täytä nollalla.
        file.data[file.data_len] = 0;
    }
    // Kopioi data offsetista.
    if (buf.len > 0) {
        // Vähintään yksi tavu kopioitavana.
        @memcpy(file.data[off..][0..buf.len], buf);
    }
    // Päivitä pituus jos kirjoitus jatkoi loppua.
    const end = off + buf.len;
    if (end > file.data_len) file.data_len = end;
    // Palauta kirjoitettujen tavujen määrä.
    return buf.len;
}

// Montako tiedostoa taulukossa (ls-laskuri VSL-shellille).
pub fn fileCount() usize {
    // Alustamaton → nolla.
    if (!initialized) return 0;
    // Palauta laskuri.
    return file_count;
}

// Tiedoston polku indeksillä — null jos vapaa/rajat ulkona (ls-rivit).
// Indeksi on taulukkoindeksi 0..MAX_FILES, ei aukiololaskuri.
pub fn fileNameAt(idx: usize) ?[]const u8 {
    // Rajojen ulkopuolella.
    if (idx >= MAX_FILES) return null;
    // Vapaa slotti.
    if (!files[idx].used) return null;
    // Palauta polkuviipale.
    return files[idx].name[0..files[idx].name_len];
}

// Boot/host self-test — addFile + open/read/close.
pub fn runSelfTest() TmpfsError!void {
    // Puhdas tila.
    initCore();
    // Lisää testitiedosto.
    try addFile("/hello", "TMPFS");
    // Avaa tiedosto.
    const file = try open("/hello");
    // Puskuri luettavalle datalle.
    var buf: [32]u8 = undefined;
    // Lue alusta.
    const n = try read(file, &buf, 0);
    // Sulje (no-op).
    close(file);
    // Odotettu 5 tavua ("TMPFS").
    if (n != 5) return TmpfsError.NotSupported;
    // Vertaa sisältö merkki kerrallaan.
    const expect = "TMPFS";
    var i: usize = 0;
    while (i < expect.len) : (i += 1) {
        // Data ei täsmää.
        if (buf[i] != expect[i]) return TmpfsError.NotSupported;
    }
}
