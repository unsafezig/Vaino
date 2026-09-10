//! VFS — kernel-rajapinta boot-testeineen.
//!
//! **Vastuu**: Alustus, mount-rekisteröinti, boot-smoke test.
//! **Riippuvuudet**: `vfs_core.zig`, log
//! **Käytetään**: `kernel/main.zig`, tuleva tmpfs (6.4)

// Tuo ydinlogiikka — mountit, kahvat, open/read/close.
const core = @import("vfs_core.zig");
// Tuo lokitus boot-viesteihin.
const log = @import("../lib/log.zig");

// Uudelleenexportoi virheet ulkoisille käyttäjille.
pub const VfsError = core.VfsError;
// Uudelleenexportoi kahvatyyppi.
pub const FileHandle = core.FileHandle;
// Uudelleenexportoi FS ops -vtable.
pub const FileSystemOps = core.FileSystemOps;
// Uudelleenexportoi mount-raja.
pub const MAX_MOUNTS = core.MAX_MOUNTS;

// Alusta VFS boot-vaiheessa.
pub fn init() void {
    // Nollaa mount- ja kahvataulukot.
    core.initCore();
}

// Rekisteröi tiedostojärjestelmä mount-prefixillä.
pub fn registerMount(prefix: []const u8, ops: *const FileSystemOps) VfsError!void {
    // Delegoi ytimeen.
    return core.registerMount(prefix, ops);
}

// Avaa tiedosto absoluuttisella polulla.
pub fn open(path: []const u8) VfsError!FileHandle {
    // Delegoi ytimeen.
    return core.open(path);
}

// Lue avoimesta tiedostosta.
pub fn read(handle: FileHandle, buf: []u8, offset: u64) VfsError!usize {
    // Delegoi ytimeen.
    return core.read(handle, buf, offset);
}

// Sulje avoin tiedosto.
pub fn close(handle: FileHandle) void {
    // Delegoi ytimeen.
    core.close(handle);
}

// Kirjoita avoimeen tiedostoon (VSL-2 — tmpfs toteuttaa, read-only FS ei).
pub fn write(handle: FileHandle, buf: []const u8, offset: u64) VfsError!usize {
    // Delegoi ytimeen.
    return core.write(handle, buf, offset);
}

// Boot-testi — mount testfs, open/read/close, vahvista "HELLO".
pub fn runBootTest() void {
    // Varmista ydin on alustettu.
    init();
    // Suorita sisäänrakennettu self-test.
    core.runSelfTest() catch {
        // Open/read/close epäonnistui.
        log.err("VFS test failed");
        // Lopeta testi.
        return;
    };
    // Kaikki tarkistukset OK.
    log.info("VFS test OK");
}
