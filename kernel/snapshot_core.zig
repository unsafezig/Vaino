//! Snapshot-ydin — sivutaulukävelyn puhdas matematiikka (31.5.1, host-testattava).
//!
//! **Vastuu**: x86_64 4-tason indeksilaskenta + lehtimerkinnän dekoodaus ilman
//!   laitteistoa. Ei `@import`:ia (sama kaava kuin `scope.zig`).
//! **Riippuvuudet**: ei
//! **Käytetään**: `kernel/snapshot.zig` (freestanding-kävely), host-testit.
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md)
//! - Raja on U/S-bitti, ei puolisko: plugin-koodi elää higher-half
//!   osoitteissa omassa PML4:ssään USER-lipulla, kernel-teksti samalla
//!   alueella supervisorina. Snapshottiin kuuluvat VAIN user-lehdet —
//!   kernel-puoliskon kopiointi olisi tupla-allokaatio + restore-vaara.
//! - Huge-sivut (2M/1G) kirjataan yhtenä merkintänä, ei pureta 4K:ksi.

// Bittiä per tason indeksi (512 merkintää/taulu).
pub const INDEX_BITS: u6 = 9;
// Tason indeksimaski.
pub const INDEX_MASK: u64 = 0x1FF;
// Present-bitti (merkintä aktiivinen).
pub const FLAG_PRESENT: u64 = 1 << 0;
// Writable-bitti.
pub const FLAG_WRITABLE: u64 = 1 << 1;
// User-bitti (ring 3) — snapshot-raja.
pub const FLAG_USER: u64 = 1 << 2;
// Huge-bitti (PDPT/PD-tason lehti).
pub const FLAG_HUGE: u64 = 1 << 7;
// Fyysisen osoitteen maski (bitit 51..12).
pub const PHYS_MASK: u64 = 0x000F_FFFF_FFFF_F000;
// Tasosiirtymät: PML4/PDPT/PD/PT.
pub const LEVEL_SHIFT: [4]u6 = .{ 39, 30, 21, 12 };

// Tason indeksi virtuaaliosoitteesta (level 0=PML4 … 3=PT).
pub fn levelIndex(virt: u64, level: u2) u64 {
    // Siirrä tason bitit alas ja maskaa 9 bittiä.
    return (virt >> LEVEL_SHIFT[level]) & INDEX_MASK;
}

// Rakenna virtuaaliosoite neljästä tason indeksistä (12-bit offset nolla).
// Tulos on 48-bittinen muoto — kanonisoi canonicalize():lla ennen vertailua
// linkkeriosoitteisiin (higher-half user-sivut, esim. plugin-koodi).
pub fn composeVirt(l3: u64, l2: u64, l1: u64, l0: u64) u64 {
    // Yhdistä indeksit siirtymillään.
    return (l3 << 39) | (l2 << 30) | (l1 << 21) | (l0 << 12);
}

// Kanonisoi 48-bittinen osoite: bitti 47 etumerkkilaajenee bitteihin 48..63.
// Ilman tätä higher-half user-sivut (PML4 511) eivät täsmää linkkeriosoitteisiin.
pub fn canonicalize(virt48: u64) u64 {
    // Bitti 47 asetettu → yläbitit ykkösiksi (kanoninen higher-half).
    if ((virt48 & (@as(u64, 1) << 47)) != 0) return virt48 | 0xFFFF_0000_0000_0000;
    // Matala puolisko kelpaa sellaisenaan.
    return virt48;
}

// Onko raaka merkintä present-lehti PT-tasolla (4K-sivu)?
pub fn isPageLeaf(raw: u64) bool {
    // Present vaaditaan; huge ei kelpaa PT-tasolla lehtenä.
    return (raw & FLAG_PRESENT) != 0 and (raw & FLAG_HUGE) == 0;
}

// Onko raaka merkintä huge-lehti väylätasolla (PDPT/PD, 1G/2M)?
pub fn isHugeLeaf(raw: u64) bool {
    // Present + huge yhdessä.
    return (raw & FLAG_PRESENT) != 0 and (raw & FLAG_HUGE) != 0;
}

// Onko raaka merkintä user-sivu (snapshottiin) vs supervisor (ohitetaan)?
pub fn isUser(raw: u64) bool {
    // U/S-bitti ratkaisee — ei osoitteen puolisko.
    return (raw & FLAG_USER) != 0;
}

// Onko raaka merkintä kirjoitettava?
pub fn isWritable(raw: u64) bool {
    // W-bitti.
    return (raw & FLAG_WRITABLE) != 0;
}

// Lehtimerkinnän fyysinen perusosoite (kehys-aligned).
pub fn leafPhys(raw: u64) u64 {
    // Maskaa osoitebitit.
    return raw & PHYS_MASK;
}

// Seuraavan tason taulun fyysinen osoite väylämerkinnästä.
pub fn nextTablePhys(raw: u64) u64 {
    // Väylämerkinnän osoite on aina kehys-aligned.
    return raw & PHYS_MASK;
}
