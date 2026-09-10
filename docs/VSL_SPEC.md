# VSL — Väinö Subsystem for Linux (plugin-määrittely)

> **Tila**: VSL-0 stub + VSL-1 mini-ABI (tämä dokumentti on VSL:n kanoninen spec).
> **Periaate**: Linux on yksi plugin muiden joukossa. Core pysyy puhtaana —
> kaikki Linux-kompleksisuus elää `userland/vsl/`:ssä. `AI proposes. Kernel decides.`
> (AGENTS.md). Eristysinvariantit I1–I7 (`docs/PLUGIN_MODEL.md`) pätevät VSL:ään
> kuten jokaiseen pluginiin.

---

## 1. Mikä VSL on / ei ole (`VSL/README.md` → Zinux-termein)

* **On**: replaceable user-space plugin (`pid` + oma `page_table` + `Scope`),
  mini-Linux-ABI-kääntäjä, snapshot-valmis tilakuvausformaatti (VSL-3).
* **Ei ole**: kerneli, Linux-jakelu, natiiviajurien korvaaja, vapaa pääsy hostiin.
* **Upstream-suhde**: `Fork/VSL/` (täysi Linux-puu) on referenssi + fixture.
  Sitä ei käännetä kerneliin. Zinux-koodi elää `Zinux/userland/vsl/`:ssä.

## 2. Arkkitehtuurivalinta (3 vaihtoehtoa arvioitu)

| # | Malli | Päätös | Perustelu |
|---|-------|--------|-----------|
| A | Syscall-käännös (WSL1-tyyli) | **VALITTU** | Sopii nykyrajoihin (32 slottia, 32B IPC), ei kernel-muutoksia, pieni mitattava koe |
| B | VM-isäntä (WSL2/KVM, VT-x/EPT) | **HYLÄTTY toistaiseksi** | Ei VMX/EPT-tukea, `virtio_blk` osaa vain `readSector0`, suurin uusi koodipinta — negative result, palataan VSL-4+:ssa |
| C | Co-host stub (Linux datana) | **VALITTU VSL-0:ksi** | Todistaa lifecycle-manifest-scope-gateway-ketjun ilman Linux-kompleksisuutta |

VSL-0 = C-stub, VSL-1 = A-mini-ABI käyttäjätilassa. B kirjattu hylättynä —
ei piilotettuja VM-suunnitelmia.

## 3. Mini-ABI (VSL-1)

Linux-syscall-numerot (x86_64) → Zinux-syscallit (`libs/zinuxabi.zig`).
Käännös elää **käyttäjätilassa** (`userland/vsl/linux_abi.zig`), ei kernelissä —
kernel ei opettele Linuxia, VSL opettelee Zinuxia.

| Linux nr | Nimi | Zinux-vastine | Huomio |
|----------|------|---------------|--------|
| 0 | read | `SYS_read (11)` | fd 0/1/2 UART, muut → EBADF toistaiseksi |
| 1 | write | `SYS_write (1)` | suora läpimeno |
| 12 | brk | `SYS_mem_map (23)` | 1 sivu/kutsu, memory-cap vaaditaan |
| 9 | mmap | `SYS_mem_map (23)` | vain anonyymi 1-sivu toistaiseksi |
| 60 | exit | `SYS_exit (2)` | suora läpimeno |
| 39 | getpid | `SYS_getpid (3)` | suora läpimeno |
| 63 | uname | stub (`"VSL"`) | ei kernel-kyselyä — VSL vastaa itse |

Tuntematon numero → `ENOSYS (-38)`. Käännös ei koskaan levennä scopea:
pyydetty `⊆ scope`, `grant` kielletty VSL-scopessa (negatiiviset testit).

**Väliaikainen rajoite (rehellisesti)**: vain shimmiä (`vsl_libc.zig`) vasten
käännetyt testibinäärit toimivat. Muokkaamattomien Linux-ELF:ien
trap-and-emulate on tulevaisuutta (VSL-4), ei väitetä toimivaksi nyt.

## 4. Manifest + scope (sama portti kuin muilla plugineilla)

```zig
// Manifesti (rekisterikuljetus, Phase-30-kaava):
name = "vsl", version = 1, abi_version = 1,
caps = [{ type = 1 (port), rights = SEND|RECV },  // IPC-väylä
        { type = 5 (memory), rights = MAP|READ|WRITE }], // brk/mmap
// Scope:
allowed_types = TYPE_PORT | TYPE_MEMORY,          // bitti 1 + bitti 5
allowed_rights = READ|WRITE|SEND|RECV|MAP,        // ei GRANT
max_caps = 4,
```

* Lataus: `sys_plugin_load(embedded_id=1, ...)` → EINVAL tuntemattomalla id:llä,
  EPERM eskalaatiolla (grant-pyyntö), ENOMEM täydellä rekisterillä (8).
* Ajo: `loader.runPlugin(pid)` ring-3:ssa, sarjaan `vsl\n`.
* Purku: `sys_plugin_unload(pid)` — vain lataaja tai boot, muuten EPERM.

## 5. Muisti- ja latausosoitteet (ei päällekkäisyyksiä)

| Plugin | Latausosoite | Pinon heap-slot | Embed-id | Binääri |
|--------|--------------|-----------------|----------|---------|
| plugin_test | `0xFFFFFFFF9008D000` | 116 | 0 | `plugin_prog.bin` |
| plugin_xfer | `0xFFFFFFFF90092000` (+`.capboot` `...93000`) | 117 | test-only | `plugin_xfer_test_prog.bin` |
| **vsl** | **`0xFFFFFFFF90094000`** | **118** | **1** | **`vsl_prog.bin`** |

## 6. Tilakuvausformaatti (VSL-3-valmius, ei toteutusta vielä)

```zig
VslState { regs: [16]u64, caps: [8]CapRef, pages: []PageRef }
// CapRef{slot, abi_type, rights_mask}, PageRef{virt, dirty: bool}
```

Stateless + BOOT-omisteinen jaettu portti selviää jo `plugin_swap`:llä;
omistetut cap:t kuolevat teardownissa kunnes Phase 31.5 (`snapshot.zig`)
toteutetaan. Ei väitetä restorea toimivaksi nyt.

## 7. Mitattavat metriikat (AGENTS.md: Measurement)

* Myönnetyt/evätyt capabilityt per VSL-lataus (scope-testi laskee).
* Käännettyjen vs. ENOSYS-hylättyjen Linux-syscallien suhde (host-testi).
* Boot-sarjaotos: `vsl / VSL stub OK / VSL ABI OK / All boot tests OK`.
* Spec-burden: tämä tiedosto (~150 riviä) + `linux_abi.zig` (~100) vs.
  geneerinen boilerplate (`build.zig`-embed, loader-haara).

## 8. Testit

```bash
zig build test
# incl. vsl_abi_test (käännösvektorit + grant-es kalaation hylkäys)
# incl. vsl_fd_test (fd-taulu + shell-parser) + tmpfs write/list + vfs write-reject
zig build boot-test
# sarja: vsl / VSL stub OK / VSL ABI OK / VirtIO block multi OK /
#        vsl-ls: welcome / vsl-cat: TMPFS / VSL fs OK / All boot tests OK
```

## 9. Ei-tavoitteet (scope-creep-esto)

Ei täyttä POSIXia, ei busyboxia VSL-2:ssa, ei virtio-writeä, ei verkkoa,
ei VT-x:ää, ei IRQ/MMIO-cap-tyyppejä coressa VSL:ää varten, ei
`dispatch`-taulun kasvattamista yli 32:n ennen kuin mini-ABI todistaa tarpeen.

## 10. VSL-2 toteutus (2026-09-10) ✅

* `userland/vsl/fd.zig` — fd-taulu (16 slottia, 0/1/2 konsoli, `isIoReady`
  true vain konsolille; file/pipe rehellisesti false kunnes fd-syscallit).
* `userland/vsl/shell.zig` — `help/ls/cat`-parseri (`MissingPath → PathTooLong`).
* `virtio_blk`: `readSector0` → `readSector(n)`; sektori 1 status-OK + nollatarkistus.
* VFS: valinnainen `write`-op (`null` → `NotSupported`); tmpfs `writeFile`
  (aukkonollaus, `MAX_FILE_DATA`-raja, ei katkaisua) + `fileCount/fileNameAt`.
* Boot-testi `vsl_fs_syscall.zig`: NotFound-negatiivi → `vsl-ls: welcome` →
  `vsl-cat: TMPFS` → `hello-vsl`-takaisinluku → `VSL fs OK`.
* Ring-3-rajoite ennallaan: tiedosto-I/O kulkee boot-polulla kunnes
  fd-syscallit (VSL-4). `openat` yhä ENOSYS shimissä.
