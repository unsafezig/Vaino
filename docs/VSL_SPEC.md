# VSL — Väinö Subsystem for Linux (plugin-määrittely)

> **Tila**: VSL-0 stub + VSL-1 mini-ABI + VSL-2 shell-polku + VSL-3 tilakuvaus
> (tämä dokumentti on VSL:n kanoninen spec).
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

## 6. Tilakuvausformaatti (VSL-3, toteutettu 2026-09-11) ✅

```zig
VslState { regs: [16]u64, caps: [8]CapRef, pages: [64]PageRef }
// CapRef{slot, abi_type, rights_mask}, PageRef{virt, dirty: bool}
```

* `userland/vsl/state.zig` — puhdas formaatti (ABI-numerot 1/5, kapasiteetti
  64 == snapshot-inventaario, ei katkaisua); `regs` rehellisesti nollia
  (31.5.2 ei kaappaa rekistereitä — VSL-4 varaus, ei valehtelua).
* Täyttö kernelissä (`vsl_state_syscall.zig::describeCheckpoint`): sivut +
  dirty-liput checkpointista, capit sloteista. Boot todistaa molemmat puolet:
  VSL täysin puhdas, dirty_test tasan yksi likainen sivu pinon huipulla.
* Stateless + BOOT-omisteinen jaettu portti selviää `plugin_swap`:llä
  (41.2, entry-ankkuroitu); omistetut cap:t kuolevat teardownissa kunnes
  omistetun tilan migraatio (31.5-raja, dokumentoitu).
* Restorea sloteille/rekistereille ei väitetä (31.5.3-raja): sivu-rollback
  copy-backilla, ei täyttä prosessiaikaa.

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

## 11. VSL-4 suunta (speksi ennen koodia, 2026-09-11) ⬜

> Research-first (AGENTS.md): tavoite + rajat + kumottavuus kirjataan
> ennen ensimmäistä koodiriviä. Kumpikaan säie ei opeta kerneliin Linuxia —
> VSL opettelee Zinuxia (core pysyy puhtaana).

| Säie | Tavoite | Kokoarvio |
|------|---------|-----------|
| **4A** | fd-syscallit ring-3:ssa (`open/read/close` VFS-taustalla, `isIoReady(file)=true`) | Pieni, mitattava koe |
| **4B** | Trap-and-emulate muokkaamattomille Linux-ELF:eille (Linux-syscall → Zinux-käännös trap-polulla) | Suurin kernel-työ sitten 31.5:n |

**4A-suunnitelma (toteutettu 2026-09-11) ✅:** `SYS_vfs_open/read/close`
(29/30/31 — dispatch-taulukko nyt täynnä) + `vfs.errnoOf/isOpen` +
`vsl_libc`-shim (`vslOpenFile/vslReadFile/vslCloseFile`, fd-reititys,
R10-offset) + `vsl_file_test`-demo ring-3:ssa (`vsl-file: TMPFS`).
Boot-todiste: ENOENT/EINVAL/EBADF-negatiivit + invoke open/read/close +
ring-3 open→read→EOF→close→tuplasulku-EBADF. Ei uusia cap-tyyppejä.
Kahvat globaalissa taulukossa (ei per-pid-fd:tä — yhden pluginin koe).

**4B-rajaus (tutkimusvaihe, ei lupausta):** edellyttää per-plugin
syscall-pysäytystä (IDT/`syscall_entry`-haara + Linux-numeroiden käännös
`linux_abi`-taululla) sekä VSL-4-rekisterikaappausta (`VslState.regs`
täyttyy ensi kertaa). Avoin kysymys: signaalit + `fork`-semantiikka rajataan
ulos ensimmäisestä kokeesta (ENOSYS + dokumentoitu syy). Onnistumiskriteeri
etukäteen: staattisesti käännetty `hello`-Linux-ELF tulostaa UART:iin ilman
shim-uudelleenlinkitystä; epäonnistuminenkin kirjataan (negative result).

**Yhteiset ei-tavoitteet (voimassa 4A+4B):** ei täyttä POSIXia/busyboxia, ei
verkkoa, ei virtio-writeä, ei VT-x/EPT:tä (vaihtoehto B yhä hylätty —
paluu vasta kun 4B todistaa käännösmallin), ei IRQ/MMIO-cap-tyyppejä VSL:ää
varten, ei `dispatch`-taulua yli 32:n ilman mitattua tarvetta.

**Metriikat (AGENTS.md: Measurement):** käännettyjen vs. ENOSYS-hylättyjen
suhde (4A: fd-opit, 4B: trap-vektorit), myönnetyt/evätyt capit per
VSL-lataus, spec-burden (tämä luku + `linux_abi`-diff vs. boilerplate).
