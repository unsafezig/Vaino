//! VirtIO block -ajuri — VirtIO PCI common-cfg + yksi virtqueue.
//!
//! **Vastuu**: Etsi virtio-blk PCI, lue sektori 0 boot-testissä.
//! **Riippuvuudet**: `../bus/pci.zig`, `../../mm/pmm.zig`, `../../mm/vmm.zig`
//! **Käytetään**: `kernel/main.zig`

// Tuo PCI — laitteen etsintä, BAR ja capabilityt.
const pci = @import("../bus/pci.zig");
// Tuo PMM — DMA-puskurien fyysiset kehykset.
const pmm = @import("../../mm/pmm.zig");
// Tuo VMM — HHDM ja sivukartoitus.
const vmm = @import("../../mm/vmm.zig");
// Tuo lokitus boot-testiin.
const log = @import("../../lib/log.zig");
// Tuo sivukoko ja PageFlags.
const paging = @import("../../arch/x86_64/paging.zig");

// VirtIO status: driver kuittaa laitteen.
const STATUS_ACK: u8 = 1;
// VirtIO status: driver valmis.
const STATUS_DRIVER: u8 = 2;
// VirtIO status: driver OK (virtqueue käytössä).
const STATUS_DRIVER_OK: u8 = 4;
// VirtIO status: feature negotiation OK.
const STATUS_FEATURES_OK: u8 = 8;
// VirtIO block: read request type.
const BLK_T_IN: u32 = 0;
// VirtIO block: status OK.
const BLK_S_OK: u8 = 0;
// Virtq desc flag: next descriptor in chain.
const DESC_F_NEXT: u16 = 1;
// Virtq desc flag: device writes this buffer.
const DESC_F_WRITE: u16 = 2;
// Yksi sektori = 512 tavua.
const SECTOR_SIZE: usize = 512;
// Queue depth boot-testille.
const QUEUE_SIZE: u16 = 4;
// Common cfg offset: device_status (u8).
const CFG_DEVICE_STATUS: u64 = 0x14;
// Common cfg offset: queue_select (u16).
const CFG_QUEUE_SELECT: u64 = 0x16;
// Common cfg offset: queue_size (u16).
const CFG_QUEUE_SIZE: u64 = 0x18;
// Common cfg offset: queue_enable (u16).
const CFG_QUEUE_ENABLE: u64 = 0x1C;
// Common cfg offset: queue_notify_off (u16).
const CFG_QUEUE_NOTIFY_OFF: u64 = 0x1E;
// Common cfg offset: queue_desc (u64).
const CFG_QUEUE_DESC: u64 = 0x20;
// Common cfg offset: queue_driver / avail (u64).
const CFG_QUEUE_DRIVER: u64 = 0x28;
// Common cfg offset: queue_device / used (u64).
const CFG_QUEUE_DEVICE: u64 = 0x30;
// Common cfg offset: device_feature_select (u32).
const CFG_DEVICE_FEATURE_SEL: u64 = 0x00;
// Common cfg offset: device_feature (u32).
const CFG_DEVICE_FEATURE: u64 = 0x04;
// Common cfg offset: driver_feature_select (u32).
const CFG_DRIVER_FEATURE_SEL: u64 = 0x08;
// Common cfg offset: driver_feature (u32).
const CFG_DRIVER_FEATURE: u64 = 0x0C;

// Virtqueue descriptor — yksi DMA-segmentti.
const VirtqDesc = extern struct {
    // Fyysinen osoite puskuriin.
    addr: u64,
    // Pituus tavuina.
    len: u32,
    // Liput (NEXT, WRITE).
    flags: u16,
    // Seuraava descriptor ketjussa.
    next: u16,
};

// Virtqueue available ring — driver → device.
const VirtqAvail = extern struct {
    // Virtqueue flags (unused boot-testissä).
    flags: u16,
    // Indeksit edelliseen lisäykseen.
    idx: u16,
    // Descriptor-indeksit.
    ring: [QUEUE_SIZE]u16,
};

// Virtqueue used element.
const VirtqUsedElem = extern struct {
    // Descriptor id.
    id: u32,
    // Kirjoitettujen tavujen määrä.
    len: u32,
};

// Virtqueue used ring — device → driver.
const VirtqUsed = extern struct {
    // Virtqueue flags.
    flags: u16,
    // Indeksit edelliseen valmistumiseen.
    idx: u16,
    // Valmistuneet elementit.
    ring: [QUEUE_SIZE]VirtqUsedElem,
};

// Block-pyynnön header (type + sector).
const BlkReqHeader = extern struct {
    // Pyyntötyyppi (IN/OUT).
    typ: u32,
    // Varattu — nollaa.
    reserved: u32,
    // Sektorinumero (512 tavun lohkot).
    sector: u64,
};

// VirtIO PCI common configuration -virtuaalibase.
var common_cfg_base: u64 = 0;
// VirtIO PCI notify-alueen virtuaalibase.
var notify_base: u64 = 0;
// Notify-kirjoituksen kerroin (queue_notify_off * multiplier).
var notify_multiplier: u32 = 0;
// Queue descriptor -taulukon fyysinen osoite.
var desc_phys: u64 = 0;
// Avail ringin fyysinen osoite.
var avail_phys: u64 = 0;
// Used ringin fyysinen osoite.
var used_phys: u64 = 0;
// Block request header + data + status fyysinen osoite.
var req_phys: u64 = 0;
// Aktiivinen queue 0 — edellinen used.idx (driver seuraa laitetta).
var last_used_idx: u16 = 0;

// Kartoita PCI BAR -MMIO-alue — Limine HHDM kattaa jo fyysisen osoiteavaruuden.
fn mapBarRegion(bar_phys: u64) bool {
    // QEMU PCI BAR on HHDM-kartoituksessa (2 MiB huge pages) — ei luoda uusia PTE:itä.
    _ = bar_phys;
    // Onnistuu aina; käytä vmm.physToVirt() rekisteri-IO:hon.
    return true;
}

// Lue u8 common configuration -rekisteristä.
fn cfgRead8(off: u64) u8 {
    // Osoitin common cfg + offset.
    const ptr: *volatile u8 = @ptrFromInt(common_cfg_base + off);
    // Lue volatile.
    return ptr.*;
}

// Kirjoita u8 common configuration -rekisteriin.
fn cfgWrite8(off: u64, value: u8) void {
    // Osoitin common cfg + offset.
    const ptr: *volatile u8 = @ptrFromInt(common_cfg_base + off);
    // Kirjoita volatile.
    ptr.* = value;
}

// Lue u16 common configuration -rekisteristä.
fn cfgRead16(off: u64) u16 {
    // Osoitin common cfg + offset.
    const ptr: *volatile u16 = @ptrFromInt(common_cfg_base + off);
    // Lue volatile.
    return ptr.*;
}

// Lue u32 common configuration -rekisteristä.
fn cfgRead32(off: u64) u32 {
    // Osoitin common cfg + offset.
    const ptr: *volatile u32 = @ptrFromInt(common_cfg_base + off);
    // Lue volatile.
    return ptr.*;
}

// Kirjoita u16 common configuration -rekisteriin.
fn cfgWrite16(off: u64, value: u16) void {
    // Osoitin common cfg + offset.
    const ptr: *volatile u16 = @ptrFromInt(common_cfg_base + off);
    // Kirjoita volatile.
    ptr.* = value;
}

// Kirjoita u32 common configuration -rekisteriin.
fn cfgWrite32(off: u64, value: u32) void {
    // Osoitin common cfg + offset.
    const ptr: *volatile u32 = @ptrFromInt(common_cfg_base + off);
    // Kirjoita volatile.
    ptr.* = value;
}

// Kirjoita u64 common configuration -rekisteriin.
fn cfgWrite64(off: u64, value: u64) void {
    // Osoitin common cfg + offset.
    const ptr: *volatile u64 = @ptrFromInt(common_cfg_base + off);
    // Kirjoita volatile.
    ptr.* = value;
}

// Aseta device_status OR-bitit (u8).
fn setStatus(bits: u8) void {
    // Lue nykyinen status.
    const cur = cfgRead8(CFG_DEVICE_STATUS);
    // OR uudet bitit.
    cfgWrite8(CFG_DEVICE_STATUS, cur | bits);
}

// Ilmoita laitteelle queue 0 (PCI notify-alue).
fn notifyQueue0() void {
    // Valitse queue 0 ennen notify_off-lukua.
    cfgWrite16(CFG_QUEUE_SELECT, 0);
    // Lue notify offset tälle queue:lle.
    const notify_off = cfgRead16(CFG_QUEUE_NOTIFY_OFF);
    // Laske notify-osoite: base + off * multiplier.
    const byte_off = @as(u64, notify_off) * @as(u64, notify_multiplier);
    // Kirjoita queue index notify-alueeseen.
    const ptr: *volatile u16 = @ptrFromInt(notify_base + byte_off);
    // Queue 0 kick.
    ptr.* = 0;
}

// Allokoi yksi 4 KiB kehys ja palauta phys + virt (HHDM).
fn allocDmaPage(out_phys: *u64) ?[*]u8 {
    // Allokoi fyysinen kehys.
    const frame = pmm.allocFrame() orelse return null;
    // Muunna kehysindeksi → fyysinen osoite.
    const phys = pmm.frameToPhys(frame);
    // Tallenna phys kutsujalle.
    out_phys.* = phys;
    // CPU-pääsy HHDM-kautta.
    return @ptrFromInt(vmm.physToVirt(phys));
}

// Alusta virtqueue 0 — descriptor/avail/used osoitteet laitteelle.
fn setupQueue() bool {
    // Valitse queue 0.
    cfgWrite16(CFG_QUEUE_SELECT, 0);
    // Aseta queue koko.
    cfgWrite16(CFG_QUEUE_SIZE, QUEUE_SIZE);
    // Descriptor-taulukko laitteelle.
    cfgWrite64(CFG_QUEUE_DESC, desc_phys);
    // Avail ring laitteelle.
    cfgWrite64(CFG_QUEUE_DRIVER, avail_phys);
    // Used ring laitteelle.
    cfgWrite64(CFG_QUEUE_DEVICE, used_phys);
    // Queue valmis.
    cfgWrite16(CFG_QUEUE_ENABLE, 1);
    // Onnistui.
    return true;
}

// Lue yksi sektori levyltä — palauttaa true jos status OK (VSL-2: parametrisoitu).
fn readSector(sector_num: u64, data_out: *[SECTOR_SIZE]u8) bool {
    // Descriptor-taulukko CPU-puolella.
    const desc: [*]VirtqDesc = @ptrFromInt(vmm.physToVirt(desc_phys));
    // Avail ring CPU-puolella.
    const avail: *VirtqAvail = @ptrFromInt(vmm.physToVirt(avail_phys));
    // Used ring CPU-puolella.
    const used: *VirtqUsed = @ptrFromInt(vmm.physToVirt(used_phys));
    // Used idx — volatile (laite kirjoittaa DMA:lla).
    const used_idx_ptr: *volatile u16 = @ptrFromInt(@intFromPtr(&used.idx));
    // Request-sivu: header + data + status peräkkäin.
    const req_base: [*]u8 = @ptrFromInt(vmm.physToVirt(req_phys));
    // Header osoite request-sivulla.
    const hdr: *BlkReqHeader = @ptrCast(@alignCast(req_base));
    // Data-puskuri headerin jälkeen.
    const data_ptr = req_base + @sizeOf(BlkReqHeader);
    // Status-tavu datan jälkeen (laite kirjoittaa).
    const status_ptr: *volatile u8 = @ptrFromInt(@intFromPtr(req_base + @sizeOf(BlkReqHeader) + SECTOR_SIZE));
    // Valmistele read-pyyntö annetulle sektorille.
    hdr.* = .{ .typ = BLK_T_IN, .reserved = 0, .sector = sector_num };
    // Nollaa status ennen pyyntöä.
    status_ptr.* = 0xFF;
    // Descriptor 0: header (device read-only).
    desc[0] = .{
        .addr = req_phys,
        .len = @sizeOf(BlkReqHeader),
        .flags = DESC_F_NEXT,
        .next = 1,
    };
    // Descriptor 1: data (device writes 512 tavua).
    desc[1] = .{
        .addr = req_phys + @sizeOf(BlkReqHeader),
        .len = SECTOR_SIZE,
        .flags = DESC_F_NEXT | DESC_F_WRITE,
        .next = 2,
    };
    // Descriptor 2: status (device writes 1 tavu).
    desc[2] = .{
        .addr = req_phys + @sizeOf(BlkReqHeader) + SECTOR_SIZE,
        .len = 1,
        .flags = DESC_F_WRITE,
        .next = 0,
    };
    // Lisää descriptor 0 avail-ringiin.
    avail.ring[0] = 0;
    // Memory fence ennen idx-päivitystä.
    asm volatile ("" ::: .{ .memory = true });
    // Julkaise pyyntö — kasvata avail.idx.
    avail.idx += 1;
    // Memory fence ennen notifya.
    asm volatile ("" ::: .{ .memory = true });
    // Ilmoita laitteelle queue 0 (PCI notify).
    notifyQueue0();
    // Odota used.idx > last_used_idx (polling, ei IRQ).
    var spins: u32 = 0;
    while (used_idx_ptr.* == last_used_idx) {
        // Kasvata timeout-laskuria.
        spins += 1;
        // Timeout — epäonnistui.
        if (spins > 1_000_000) return false;
    }
    // Päivitä seurattu used-indeksi.
    last_used_idx = used_idx_ptr.*;
    // Kopioi luettu sektori ulos.
    @memcpy(data_out, data_ptr[0..SECTOR_SIZE]);
    // Palauta true jos status OK.
    return status_ptr.* == BLK_S_OK;
}

// Alusta VirtIO block -laite PCI-löydöstä (modern PCI transport).
fn initDevice(dev: pci.PciDevice) bool {
    // Ota memory + bus master käyttöön.
    pci.enableDevice(dev.addr);
    // Etsi VirtIO PCI capabilityt (common + notify).
    const caps = pci.findVirtioPciCaps(dev.addr) orelse {
        // Modern VirtIO PCI capability puuttuu.
        log.err("VirtIO PCI caps missing");
        return false;
    };
    // Common cfg BAR fyysinen base.
    const common_bar_phys = pci.readBarMem(dev.addr, caps.common_bar) orelse {
        // Common BAR ei memory-mapped.
        log.err("VirtIO common BAR missing");
        return false;
    };
    // Notify BAR fyysinen base.
    const notify_bar_phys = pci.readBarMem(dev.addr, caps.notify_bar) orelse {
        // Notify BAR ei memory-mapped.
        log.err("VirtIO notify BAR missing");
        return false;
    };
    // Kartoita common BAR MMIO.
    if (!mapBarRegion(common_bar_phys)) {
        // Sivukartoitus epäonnistui.
        log.err("VirtIO common BAR map failed");
        return false;
    }
    // Kartoita notify BAR MMIO (jos eri BAR).
    if (notify_bar_phys != common_bar_phys) {
        // Erillinen notify-BAR — kartoita se.
        if (!mapBarRegion(notify_bar_phys)) return false;
    }
    // Common cfg virtuaaliosoite BAR + offset.
    common_cfg_base = vmm.physToVirt(common_bar_phys) + caps.common_offset;
    // Notify-alue virtuaaliosoite.
    notify_base = vmm.physToVirt(notify_bar_phys) + caps.notify_offset;
    // Notify stride multiplier capabilitysta.
    notify_multiplier = caps.notify_multiplier;
    // Reset status ja ACK.
    cfgWrite8(CFG_DEVICE_STATUS, 0);
    setStatus(STATUS_ACK);
    setStatus(STATUS_DRIVER);
    // Feature negotiation — lue device feature -sanat.
    cfgWrite32(CFG_DEVICE_FEATURE_SEL, 0);
    _ = cfgRead32(CFG_DEVICE_FEATURE);
    cfgWrite32(CFG_DEVICE_FEATURE_SEL, 1);
    _ = cfgRead32(CFG_DEVICE_FEATURE);
    // Hyväksy 0 featurea sanassa 0.
    cfgWrite32(CFG_DRIVER_FEATURE_SEL, 0);
    cfgWrite32(CFG_DRIVER_FEATURE, 0);
    // Modern VirtIO PCI vaatii VIRTIO_F_VERSION_1 (bit 32 → word 1 bit 0).
    cfgWrite32(CFG_DRIVER_FEATURE_SEL, 1);
    cfgWrite32(CFG_DRIVER_FEATURE, 1);
    setStatus(STATUS_FEATURES_OK);
    // Varmista laite hyväksyi featuret (status bit 3 pysyy).
    if ((cfgRead8(CFG_DEVICE_STATUS) & STATUS_FEATURES_OK) == 0) {
        // Feature negotiation hylätty.
        log.err("VirtIO feature negotiation failed");
        return false;
    }
    // Allokoi DMA-sivut.
    const desc_virt = allocDmaPage(&desc_phys) orelse return false;
    const avail_virt = allocDmaPage(&avail_phys) orelse return false;
    const used_virt = allocDmaPage(&used_phys) orelse return false;
    const req_virt = allocDmaPage(&req_phys) orelse return false;
    // Nollaa descriptor/ring-sivut.
    @memset(desc_virt[0..paging.PAGE_SIZE], 0);
    @memset(avail_virt[0..paging.PAGE_SIZE], 0);
    @memset(used_virt[0..paging.PAGE_SIZE], 0);
    @memset(req_virt[0..paging.PAGE_SIZE], 0);
    // Avail alkaa nollasta; used seuraa laitetta.
    last_used_idx = 0;
    // Alusta virtqueue.
    if (!setupQueue()) return false;
    // Driver valmis.
    setStatus(STATUS_DRIVER_OK);
    return true;
}

// Boot-testi — etsi virtio-blk, lue sektori 0, vahvista "ZINUX" magic.
pub fn runBootTest() void {
    // Varmista PCI-laitelista (pci.runBootTest skannaa jo).
    if (pci.deviceCount() == 0) pci.scan();
    // Etsi VirtIO block -PCI-laite.
    const dev = pci.findVirtioBlock() orelse {
        // QEMU ilman virtio-blk — ohita testi.
        log.err("VirtIO block device not found");
        return;
    };
    // Alusta laite.
    if (!initDevice(dev)) {
        // PCI common cfg / queue alustus epäonnistui.
        log.err("VirtIO block init failed");
        return;
    }
    // Vahvista laitteen tunnistus.
    log.info("VirtIO block device OK");
    // Puskuri sektorin 0 datalle.
    var sector: [SECTOR_SIZE]u8 = undefined;
    // Lue sektori 0.
    if (!readSector(0, &sector)) {
        // DMA read epäonnistui.
        log.err("VirtIO block read failed");
        return;
    }
    // Tarkista testilevy magic (build.zig kirjoittaa "ZINUX" alkuun).
    const magic = "ZINUX";
    // Vertaa 5 tavua (ei std.mem.eql freestandingissä).
    var ok_magic = true;
    // Indeksi vertailusilmukassa.
    var mi: usize = 0;
    // Käy magic-merkit.
    while (mi < magic.len) : (mi += 1) {
        // Ero → magic ei täsmää.
        if (sector[mi] != magic[mi]) ok_magic = false;
    }
    if (!ok_magic) {
        // Väärä data — levy/ei alustettu.
        log.err("VirtIO block sector magic mismatch");
        return;
    }
    // Kaikki OK.
    log.info("VirtIO block read OK");
    // VSL-2: monisektoriluku — sektori 1 (testilevy: nollia, status OK).
    var sector1: [SECTOR_SIZE]u8 = undefined;
    // Lue sektori 1 samalla jonolla (peräkkäinen pyyntö).
    if (!readSector(1, &sector1)) {
        // Toinen peräkkäinen luku epäonnistui.
        log.err("VirtIO block multi read failed");
        return;
    }
    // Varmista sektori 1 on nollia (testilevy kirjoittaa vain magicin sektoriin 0).
    var all_zero = true;
    // Indeksi nollatarkistuksessa.
    var zi: usize = 0;
    // Käy koko sektori.
    while (zi < SECTOR_SIZE) : (zi += 1) {
        // Nollasta poikkeava tavu.
        if (sector1[zi] != 0) all_zero = false;
    }
    if (!all_zero) {
        // Odottamaton data sektorissa 1.
        log.err("VirtIO block sector1 not zero");
        return;
    }
    // Peräkkäinen monisektoriluku OK (VSL-levypolun perusta).
    log.info("VirtIO block multi OK");
}
