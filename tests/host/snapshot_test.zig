//! Host-testit snapshot-ytimelle (31.5.1).

const std = @import("std");
const snap = @import("snapshot_core");

test "snapshot level indices and compose roundtrip" {
    // Tunnettu osoite: 0xFFFFFFFF90094000 (VSL-base).
    const v: u64 = 0xFFFFFFFF90094000;
    // PML4-indeksi 511 (higher-half).
    try std.testing.expectEqual(@as(u64, 511), snap.levelIndex(v, 0));
    // PDPT-indeksi: (v >> 30) & 0x1FF.
    try std.testing.expectEqual((v >> 30) & 0x1FF, snap.levelIndex(v, 1));
    // PD + PT samoin.
    try std.testing.expectEqual((v >> 21) & 0x1FF, snap.levelIndex(v, 2));
    try std.testing.expectEqual((v >> 12) & 0x1FF, snap.levelIndex(v, 3));
    // Koostaminen tuottaa 48-bittisen muodon (ei etumerkkilaajennusta —
    // kävely vertaa tällä muodolla, kanonisuus CPU:n asia).
    const low48 = v & 0x0000_FFFF_FFFF_FFFF;
    try std.testing.expectEqual(low48 & ~@as(u64, 0xFFF), snap.composeVirt(
        snap.levelIndex(v, 0),
        snap.levelIndex(v, 1),
        snap.levelIndex(v, 2),
        snap.levelIndex(v, 3),
    ));
    // Matala user-osoite kiertää täysin (ei yläbittejä).
    const u: u64 = 0x0000000000401000;
    try std.testing.expectEqual(u, snap.composeVirt(
        snap.levelIndex(u, 0),
        snap.levelIndex(u, 1),
        snap.levelIndex(u, 2),
        snap.levelIndex(u, 3),
    ));
    // Kanonisointi palauttaa higher-half-muodon linkkerivertailuun.
    try std.testing.expectEqual(v & ~@as(u64, 0xFFF), snap.canonicalize(snap.composeVirt(
        snap.levelIndex(v, 0),
        snap.levelIndex(v, 1),
        snap.levelIndex(v, 2),
        snap.levelIndex(v, 3),
    )));
    // Matala osoite säilyy kanonisoinnissa.
    try std.testing.expectEqual(u, snap.canonicalize(u));
    // Nollaosoite → nollaindeksit.
    try std.testing.expectEqual(@as(u64, 0), snap.levelIndex(0, 0));
}

test "snapshot leaf decode user versus supervisor" {
    // User + writable + present 4K-lehti @ phys 0x12345000.
    const user_leaf: u64 = 0x12345000 | snap.FLAG_PRESENT | snap.FLAG_WRITABLE | snap.FLAG_USER;
    try std.testing.expect(snap.isPageLeaf(user_leaf));
    try std.testing.expect(!snap.isHugeLeaf(user_leaf));
    try std.testing.expect(snap.isUser(user_leaf));
    try std.testing.expect(snap.isWritable(user_leaf));
    try std.testing.expectEqual(@as(u64, 0x12345000), snap.leafPhys(user_leaf));
    // Supervisor-lehti (ei user-bittiä) → ohitetaan.
    const kern_leaf: u64 = 0x2000 | snap.FLAG_PRESENT | snap.FLAG_WRITABLE;
    try std.testing.expect(snap.isPageLeaf(kern_leaf));
    try std.testing.expect(!snap.isUser(kern_leaf));
    // Ei-present → ei lehti.
    try std.testing.expect(!snap.isPageLeaf(0x12345000 | snap.FLAG_USER));
    // Huge-lehti (present + huge) → huge, ei 4K-sivu.
    const huge: u64 = 0x400000 | snap.FLAG_PRESENT | snap.FLAG_USER | snap.FLAG_HUGE;
    try std.testing.expect(snap.isHugeLeaf(huge));
    try std.testing.expect(!snap.isPageLeaf(huge));
    try std.testing.expect(snap.isUser(huge));
    // Väylämerkinnän tauluosoite maskataan.
    try std.testing.expectEqual(@as(u64, 0x400000), snap.nextTablePhys(huge));
}
