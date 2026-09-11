//! Host-testit VSL-tilakuvaukselle (VSL-3, 41.1).
//!
//! **Vastuu**: Formaatin validointijärjestys + kapasiteettirajat ilman
//! laitteistoa. Checkpoint-täyttö on boot-katettu (`vsl_state_syscall.zig`).

const std = @import("std");
const st = @import("vsl_state");

test "vsl state init empty" {
    // Tyhjä kuvaus: versio leimattu, laskurit nollassa, ei likaisia.
    const s = st.VslState.init();
    try std.testing.expectEqual(st.VSL_STATE_VERSION, s.version);
    try std.testing.expectEqual(@as(usize, 0), s.caps_len);
    try std.testing.expectEqual(@as(usize, 0), s.pages_len);
    try std.testing.expectEqual(@as(usize, 0), s.dirtyCount());
    try std.testing.expect(!s.containsPage(0xFFFFFFFF90094000));
}

test "vsl state add vectors" {
    // Kelvolliset viitteet kasvattavat laskureita.
    var s = st.VslState.init();
    try s.addCap(0, st.ABI_TYPE_PORT, 0x0C);
    try s.addCap(1, st.ABI_TYPE_MEMORY, 0x13);
    try std.testing.expectEqual(@as(usize, 2), s.caps_len);
    try s.addPage(0xFFFFFFFF90094000, false);
    try s.addPage(0xFFFFFFFF90095000, true);
    try std.testing.expectEqual(@as(usize, 2), s.pages_len);
    // Dirty-laskenta + ankkurihaku.
    try std.testing.expectEqual(@as(usize, 1), s.dirtyCount());
    try std.testing.expect(s.containsPage(0xFFFFFFFF90095000));
    try std.testing.expect(!s.containsPage(0x1234000));
    // Tuntematon ABI-tyyppi hylätään (0, 2, 3, 4 — kernel .memory=2 ei kelpaa,
    // ABI-bitti 5 on ainoa muistimuoto tässä kerroksessa).
    try std.testing.expectError(error.BadCapType, s.addCap(2, 0, 0x0C));
    try std.testing.expectError(error.BadCapType, s.addCap(2, 2, 0x0C));
    try std.testing.expectError(error.BadCapType, s.addCap(2, 3, 0x0C));
    // Varattu bitti + tyhjä maski hylätään.
    try std.testing.expectError(error.BadRights, s.addCap(2, st.ABI_TYPE_PORT, 0x40));
    try std.testing.expectError(error.BadRights, s.addCap(2, st.ABI_TYPE_PORT, 0));
    // Nolla-osoite ei ole sivuviite.
    try std.testing.expectError(error.BadPage, s.addPage(0, false));
}

test "vsl state capacity rejects overflow" {
    // Täytä cap-taulu (8) — yhdeksäs hylätään.
    var s = st.VslState.init();
    var i: u32 = 0;
    while (i < st.MAX_STATE_CAPS) : (i += 1) {
        try s.addCap(i, st.ABI_TYPE_PORT, 0x0C);
    }
    try std.testing.expectEqual(@as(usize, st.MAX_STATE_CAPS), s.caps_len);
    try std.testing.expectError(error.TooManyCaps, s.addCap(8, st.ABI_TYPE_PORT, 0x0C));
    // Täytä sivutaulu (64) — 65. hylätään (ei hiljaista katkaisua).
    var p = st.VslState.init();
    var j: u64 = 0;
    while (j < st.MAX_STATE_PAGES) : (j += 1) {
        try p.addPage(0xFFFFFFFF90094000 + j * 0x1000, false);
    }
    try std.testing.expectEqual(@as(usize, st.MAX_STATE_PAGES), p.pages_len);
    try std.testing.expectError(error.TooManyPages, p.addPage(0xFFFFFFFF91094000, false));
}
