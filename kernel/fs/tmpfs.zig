//! tmpfs — RAM-pohjainen tiedostojärjestelmä kernelille.
//!
//! **Vastuu**: Alusta tmpfs, mount /tmp, boot-smoke test VFS:n kautta.
//! **Riippuvuudet**: `tmpfs_core.zig`, `vfs.zig`, log
//! **Käytetään**: `kernel/main.zig`

// Tuo tmpfs-ydin — tiedostotaulukko.
const core = @import("tmpfs_core.zig");
// Tuo VFS — mount-rekisteröinti ja open/read/close.
const vfs = @import("vfs.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Uudelleenexportoi ydin vakiot.
pub const MAX_FILES = core.MAX_FILES;
// Uudelleenexportoi kirjoitus + listaus VSL-shell-boot-polulle (VSL-2).
pub const addFile = core.addFile;
pub const fileCount = core.fileCount;
pub const fileNameAt = core.fileNameAt;

// Boot-testitiedoston polku mountin sisällä.
const BOOT_FILE_PATH = "/welcome";
// Boot-testitiedoston sisältö (5 tavua).
const BOOT_FILE_DATA = "TMPFS";

// VFS open-callback — delegoi tmpfs-ytimeen.
fn vfsOpen(path: []const u8) vfs.VfsError!*anyopaque {
    // Avaa tmpfs-tiedosto ja palauta opaque-solmu.
    const file = core.open(path) catch |err| switch (err) {
        // Muunna NotFound → VFS NotFound.
        error.NotFound => return vfs.VfsError.NotFound,
        // Muunna InvalidPath → VFS InvalidPath.
        error.InvalidPath => return vfs.VfsError.InvalidPath,
        // Muunna NotInitialized → VFS NotInitialized.
        error.NotInitialized => return vfs.VfsError.NotInitialized,
        // Muunna TooManyFiles → VFS TooManyFiles.
        error.TooManyFiles => return vfs.VfsError.TooManyFiles,
        // Muunna muut → NotSupported.
        error.NotSupported => return vfs.VfsError.NotSupported,
    };
    // Palauta solmu VFS:lle.
    return @ptrCast(file);
}

// VFS read-callback — delegoi tmpfs-ytimeen.
fn vfsRead(node: *anyopaque, buf: []u8, offset: u64) vfs.VfsError!usize {
    // Palauta solmu TmpfsFile-muotoon.
    const file: *core.TmpfsFile = @ptrCast(@alignCast(node));
    // Lue tmpfs-tiedosto (ei virheitä read-polussa).
    return core.read(file, buf, offset);
}

// VFS close-callback — delegoi tmpfs-ytimeen.
fn vfsClose(node: *anyopaque) void {
    // Palauta solmu TmpfsFile-muotoon.
    const file: *core.TmpfsFile = @ptrCast(@alignCast(node));
    // Sulje tmpfs-tiedosto (no-op).
    core.close(file);
}

// VFS write-callback — delegoi tmpfs-ytimeen (VSL-2).
fn vfsWrite(node: *anyopaque, buf: []const u8, offset: u64) vfs.VfsError!usize {
    // Palauta solmu TmpfsFile-muotoon.
    const file: *core.TmpfsFile = @ptrCast(@alignCast(node));
    // Rakenna polkuviipale solmun nimipuskurista.
    const path = file.name[0..file.name_len];
    // Kirjoita ytimeen (virheet VFS-muotoon).
    return core.writeFile(path, buf, offset) catch |err| switch (err) {
        // Tiedosto katosi kesken (ei pitäisi tapahtua) → NotFound.
        error.NotFound => return vfs.VfsError.NotFound,
        // Liian suuri kirjoitus → NotSupported (vastalause, ei katkaisua).
        error.NotSupported => return vfs.VfsError.NotSupported,
        // Huono polku/offset → InvalidPath.
        error.InvalidPath => return vfs.VfsError.InvalidPath,
        // Ei tilaa uudelle (ei tapahdu kirjoituksessa) → TooManyFiles.
        error.TooManyFiles => return vfs.VfsError.TooManyFiles,
        // Alustamaton → NotInitialized.
        error.NotInitialized => return vfs.VfsError.NotInitialized,
    };
}

// tmpfs ops-vtable VFS-mountille.
const tmpfs_ops = vfs.FileSystemOps{
    // Nimi boot-logissa.
    .name = "tmpfs",
    // Avaa tiedosto polusta.
    .open = vfsOpen,
    // Lue tiedoston sisältö.
    .read = vfsRead,
    // Sulje tiedosto.
    .close = vfsClose,
    // Kirjoita tiedostoon (VSL-2).
    .write = vfsWrite,
};

// Alusta tmpfs — tyhjennä taulukko ja lisää boot-tiedosto.
pub fn init() void {
    // Nollaa tiedostotaulukko.
    core.initCore();
    // Lisää /welcome boot-testiin (virheet ohitetaan — boot-testi raportoi).
    core.addFile(BOOT_FILE_PATH, BOOT_FILE_DATA) catch {};
}

// Rekisteröi tmpfs VFS:ään mount-prefixillä /tmp.
pub fn registerMount() vfs.VfsError!void {
    // Liitä tmpfs ops-vtable prefixiin /tmp.
    try vfs.registerMount("/tmp", &tmpfs_ops);
}

// Boot-testi — mount /tmp, avaa /tmp/welcome, lue "TMPFS".
pub fn runBootTest() void {
    // Alusta VFS (nollaa mountit).
    vfs.init();
    // Alusta tmpfs ja boot-tiedosto.
    init();
    // Rekisteröi /tmp-mount.
    registerMount() catch {
        // Mount epäonnistui.
        log.err("tmpfs mount failed");
        // Lopeta testi.
        return;
    };
    // Avaa boot-testitiedosto absoluuttisella polulla.
    const h = vfs.open("/tmp/welcome") catch {
        // Avaus epäonnistui.
        log.err("tmpfs open failed");
        // Lopeta testi.
        return;
    };
    // Puskuri luettavalle datalle.
    var buf: [32]u8 = undefined;
    // Lue tiedoston alusta.
    const n = vfs.read(h, &buf, 0) catch {
        // Luku epäonnistui.
        log.err("tmpfs read failed");
        // Sulje kahva ennen poistumista.
        vfs.close(h);
        // Lopeta testi.
        return;
    };
    // Sulje kahva.
    vfs.close(h);
    // Odotettu 5 tavua.
    if (n != BOOT_FILE_DATA.len) {
        // Väärä pituus.
        log.err("tmpfs read length mismatch");
        // Lopeta testi.
        return;
    }
    // Vertaa sisältö merkki kerrallaan.
    var i: usize = 0;
    while (i < BOOT_FILE_DATA.len) : (i += 1) {
        // Data ei täsmää.
        if (buf[i] != BOOT_FILE_DATA[i]) {
            // Väärä sisältö.
            log.err("tmpfs content mismatch");
            // Lopeta testi.
            return;
        }
    }
    // Kaikki tarkistukset OK.
    log.info("tmpfs test OK");
}
