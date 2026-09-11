# Väinö oikealla raudalla — HP Stream -testausohje

> **Kohde**: Vanha HP Stream -läppäri. Tavoite: Väinö (Zinux) + VSL boottaamaan
> oikealla raudalla ja toimimaan paikallisena demonstrointi-/"serveri"ympäristönä.
> **Periaate**: portaittain, jokaisella stagella yksi todennettava väite.
> Rehelliset rajat on kirjattu — ei luvata verkkoa eikä levyä, joita ei ole.

---

## 0. Mitä tämä ohje ei lupaa (lue ensin)

| Asia | Tila | Syy |
|------|------|-----|
| Boot USB:lta, kernel, muistinhallinta, syscalls, plugin-järjestelmä, shell, VSL | ✅ toimii | Ei QEMU-riippuvuuksia ytimessä |
| HTTP-serveri verkon yli / verkko ylipäänsä | ❌ ei vielä | Ei NIC-ajuria; Phase 35 on loopback-only; VSL-spec kieltää verkon |
| Levypersistenssi (tiedostot säilyvät bootin yli) | ❌ ei vielä | `virtio-blk` on QEMU-only; eMMC:lle ei ajuria → vain tmpfs (RAM) |
| Sarjaporttiloki läppärillä | ❌ ei ole | Läppärissä ei COM-porttia; ainoa konsoli on VGA-näyttö |

"Serveri" tässä ohjeessa tarkoittaa siis: **läppäri joka boottaa Väinön,
ajaa plugineja (ml. VSL) ja palvelee paikallisia demoja näppäimistöltä.**
Verkko-HTTP on Stage 4:n tulevaisuustyö (Realtek-piiri on luonteva
Phase-36-ajurigenerointikohde), ei tämän ohjeen lupaus.

Sivuvaikutus, joka on hyvä uutinen: **sisäinen levy on turvassa.**
Kernelissä ei ole eMMC/SATA-ajuria, joten se ei voi koskea Windows-asennukseen.
USB-tikun irrottaminen palauttaa läppärin normaaliksi Windows-koneeksi —
mitään ei asenneta läppäriin.

---

## Stage 0 — Tunne rautasi (ennen kuin poltat tikun)

HP Stream -malleja on useita sukupolvia, ja kaksi asiaa ratkaisee jatkon:

### 0.1 Mallin tunnistus

Windowsissa: `Win + R` → `msinfo32` → kirjaa ylös:

```
Järjestelmän malli:   ____________________  (esim. HP Stream 11-y000, 14-ax0xx)
Suoritin:             ____________________  (esim. Celeron N3060, Atom Z3735F)
BIOS-tila:            ____________________  (UEFI tai Legacy)
Secure Boot -tila:    ____________________  (On/Off)
RAM:                  ____________________  (yleensä 2–4 Gt, riittää)
```

### 0.2 Mitä vastaukset tarkoittavat

| Havainto | Merkitys Väinölle |
|----------|-------------------|
| CPU on 64-bittinen x86_64 (kaikki Stream-mallit) | ✅ ydin käännetty juuri sille |
| UEFI 64-bit (2017+ mallit) | ✅ ISO boottaa suoraan (`BOOTX64.EFI` on mukana) |
| UEFI 32-bit (2014–2016 Atom-mallit) | ⚠️ Kokeile silti: ISO sisältää myös `BOOTIA32.EFI`, ja Limine osaa ladata 64-bittisen kernelin 32-bittisestä UEFI:stä. Jos valikko ei aukea, tämä on syy. |
| Legacy/CSM-valinta firmwaressa | ✅ helpottaa: perinteinen VGA-tekstitila toimii varmimmin tällä |
| Vain UEFI, ei CSM:ää (yleisin) | ⚠️ **Sokean bootin riski**: kerneli kirjoittaa tekstikonsolin suoraan osoitteeseen `0xB8000` (`kernel/drivers/video/vga.zig`), jota UEFI-GOP-koneessa ei välttämättä näytetä. Bootti voi toimia vaikka ruutu pysyy mustana — katso vianmääritys (Stage 2.3). Tämä on tiedossa oleva puute, ei arvaus. |
| Realtek WiFi/Ethernet | Tiedoksi: ei ajuria vielä → Stage 4:n tulevaisuustyö, ei tämän ohjeen esto |

### 0.3 Vertailuloki QEMU:sta (tee tämä NYT)

Ennen rautaa, ota talteen mitä *pitäisi* näkyä. Build-koneella:

```bash
zig build boot-test 2>&1 | tee qemu-referenssi.log
```

Tämä loki on totuus, johon läppärin VGA-tulostetta verrataan rivi riviltä.
Tärkeimmät markerit (järjestyksessä):

```
Zinux boot OK
... (ajurien ja pluginien OK-rivejä, mm. "plg", "vsl", "VSL fs OK") ...
All boot tests OK
Full boot OK
```

> Huom: QEMU-lokissa näkyvät virtio-verkkolevy-testit (`VirtIO block ...`)
> epäonnistuvat läppärillä siististi (`device not found` + jatkuu) —
> ajuri on kirjoitettu palaamaan eikä jumiutumaan. Se on odotettu ero,
> ei vika.

---

## Stage 1 — Build-ympäristö ja USB-tikku

### 1.1 Kone ja työkalut

Rakenna Linuxissa (tai WSL:ssä — repo on testattu siellä; Windowsilla
ISO-vaihe jumittuu `cc`:n puutteeseen):

```bash
zig version        # pitää olla 0.16.0
sudo apt-get install -y xorriso curl gcc qemu-system-x86   # qemu vain vertailuun
```

### 1.2 ISO:n rakentaminen

```bash
zig build test     # host-testit läpi ensin — rikkinäistä ei polteta tikulle
zig build iso      # tuottaa zig-out/zinux.iso
```

Boot-tila valitaan tässä vaiheessa (raudan ensikokeiluun **smoke**):

| Komennon optio | Mitä läppärillä tapahtuu | Milloin |
|----------------|--------------------------|---------|
| (oletus, smoke) | Perusalustus + `Zinux boot OK` + `Smoke boot OK`, sitten pysähtyy (`cli; hlt` — turvallinen halt, näyttöön jää tuloste) | **Ensimmäinen rautabootti — aloita tällä** |
| `-Dboot=full` | Koko testisarja + `All boot tests OK` + pysähtyy | Kun smoke näkyy |
| `-Dboot=dev` | Testisarja + jää scheduleriin (ABAB-demo, näppäimistö elää) | Vuorovaikutteinen kokeilu + "serveri käy" -demo |

Esim: `zig build -Dboot=full iso`

> Huom: `qemu_exit`-pysäytys kirjoittaa QEMU-porttiin `0xF4`, jota raudassa
> ei ole — kirjoitus menee tyhjään ja kone jää siistiin haltiin. Ei haittaa,
> ei sammuta konetta; virtanappi Realtyöntyy normaalisti.

### 1.3 ISO tikulle (LUE: tuhoava operaatio tikulle)

```bash
lsblk                          # TUNNISTA tikku varmasti, esim. /dev/sdb
sudo dd if=zig-out/zinux.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

⚠️ **`of=` väärin = kyseisen levyn sisältö tuhoutuu.** Tarkista `lsblk`:llä
kahdesti: tikku on yleensä pieni (~8–32 Gt) vs. koneen oma levy. Älä koske
`nvme0n1`/`mmcblk0`-laitteisiin.

### 1.4 Firmwaren asetukset (HP Stream, käynnistyksen yhteydessä `Esc` → `F10`)

1. **Secure Boot → Disabled.** Pakollinen: Limine-bootloaderia ei ole
   allekirjoitettu Microsoftin avaimella, kone kieltäytyy muuten.
2. **USB Device Boot → Enabled**, ja boot-järjestyksessä USB ennen sisäistä levyä
   (tai käytä kertakäynnistysvalikkoa: `Esc` → `F9`, valitse USB-tikku).
3. Jos valikossa on **Legacy/CSM-vaihtoehto**, kokeile sitä ensin (VGA-teksti
   toimii varmimmin). Jos vain UEFI, jatka sillä — katso sokean bootin kohta.
4. Tallenna (`F10`) ja boottaa tikulta. Limine-valikon pitäisi aueta
   3 sekunnin timeoutilla (`limine.conf`).

---

## Stage 2 — Ensimmäinen rautabootti ja havainnot

### 2.1 Smoke (ensimmäinen yritys)

Tikku sisään → boot → odota ~10 s → lue näyttö. Odotus:

```
Zinux kernel starting...
Target: x86_64 freestanding
GDT initialized
IDT initialized
...
Zinux boot OK
Smoke boot OK        ← kone pysähtyy tähän, tuloste jää näytölle
```

Verrtaa `qemu-referenssi.log`:iin. Täsmää = ydin elää raudalla.

### 2.2 Full ja dev

Kun smoke täsmää: rakenna `-Dboot=full`-ISO ja boottaa. Odotus: koko sarja
läpi + `All boot tests OK` + `Full boot OK`. Sitten `-Dboot=dev`: kone jää
käymään (ajastin + näppäimistö elävät jos rauta sallii) — tämä on
"serveri käy" -tilasi toistaiseksi.

### 2.3 Vianmääritysmatriisi (kopioi havaintopäiväkirjaan)

| Oire | Todennäköinen syy | Mitä teet |
|------|-------------------|------------|
| Limine-valikko ei aukea / tikku ohitetaan | Secure Boot päällä, USB-boot pois, tai 32-bit UEFI ilman tukea | Tarkista Stage 1.4; kokeile toista USB-porttia; 32-bit-UEFI-koneessa varmista että tikulla on `EFI/BOOT/BOOTIA32.EFI` |
| Musta ruutu Limine-valikon jälkeen, levy-LED välkkyy | **Sokea bootti**: UEFI-GOP-kone ilman CSM:ää, `0xB8000`-teksti ei näy vaikka kerneli käy | Yritä Legacy/CSM-tilaa; jos ei ole, bootti on todennäköisesti silti edennyt — jatka full-tikulla ja päättele onnistuminen pysähtymisestä (levy hiljenee, kone ei reboottaa). Pysyvä korjaus = framebuffer-ajuri (kirjaa issue) |
| Jumiutuu näppäimistö-initissä (viimeinen rivi ennen keyboard-testiä) | Kone ilman i8042-yhteensopivuutta: `flushOutput()`-silmukassa ei ole timeoutia (tiedossa oleva rajoite `kernel/drivers/char/keyboard.zig`:ssä) | Kirjaa malli + rivi ylös; QEMU-vertailu vahvistaa kohdan. Korjaus kuuluu kernelin puolelle (timeout + graceful-degrade), ei tähän ohjeeseen |
| `VirtIO block device not found` | Odotettu: läppärissä ei virtio-laitetta | Ei vika — jatkuu automaattisesti |
| Näppäimistö ei vastaa dev-tilassa | IRQ1 ei saavu (APIC-reititys ilman legacy-PIC:iä) tai layout-rajoite (vain US, ei shift/nuolia) | Kokeile USB-näppäimistöä; kirjaa ylös. Shell toimii parhaiten QEMU:ssa toistaiseksi |
| Ajastin-demo (ABAB) ei tikitä dev-tilassa | PIT puuttuu/pois uudesta piirisarjasta (IRQ0 ei saavu) | Odotettu mahdollisuus; blocking-IPC odotukset ovat spin-rajoitteisia eivätkä jumiudu |

### 2.4 Havaintopäiväkirja (liitä issueen / muistiinpanoihin)

```
Malli: ____________________  UEFI: 32/64-bit  CSM: on/ei  Secure Boot: off
Tikku: smoke / full / dev   Tulos: ____________________
Viimeinen VGA-rivi: ________________________________________
QEMU-referenssi täsmää riviin: ____ asti
Aika boot-valikosta pysähdykseen: ____ s
Uusintayritykset / huomiot: ____________________
```

---

## Stage 3 — VSL + shell läppärillä (ei verkkoa, ei levyä)

Kun full-bootti menee läpi raudalla, kaikki tässä toimii ilman lisäajureita
(VSL on puhdas userland-plugin — se kulkee kernelin mukana tikulla):

- **VSL-stub**: sarjassa/VGA:lla `vsl` + `VSL stub OK` — Linux-pluginin elinkaari (load → run ring-3:ssa → unload) scope-portin läpi.
- **VSL-ABI**: `VSL ABI OK` — Linux-syscallien käännös (`write`/`exit`/`getpid`/…); tuntematon numero → `ENOSYS`, grant-pyyntö → hylkäys.
- **VSL-fs**: `vsl-ls: welcome`, `vsl-cat: TMPFS` — `help/ls/cat`-shell tmpfs:n päällä (RAM-levy; sisältö katoaa bootissa — odotettua, ei bugi).
- **Interaktiivinen shell** (dev-tila, jos näppäimistö elää): `help`, `meminfo`, `ps` — jälkimmäinen listaa oikeat PID:t prosessitaulukosta.

Kokeilurunko yhdelle istunnolle:

```
1. Boot dev-tikku, odota testisarja läpi
2. Kirjoita: help  → listaa komennot
3. Kirjoita: ps    → vähintään boot + plugin-prosessit
4. Kirjoita: meminfo → kehys- ja heap-laskurit
5. VSL-demot näkyvät jo boot-sarjassa (ei erillistä käynnistystä)
```

---

## Stage 4 — "Serveri" tänään ja verkko huomenna

**Tänään (tämä ohje):** läppäri + dev-tikku = käynnissä oleva Väinö-järjestelmä,
joka ajaa plugineja eristyksissä IPC:n yli. Demonstroi sitä näin:
uptime-pluginin elinaika + VSL-komennot + pluginin pysäytys/uudelleenkäynnistys
ilman koko järjestelmän rebuildia (POC.md Phase 10:n hengen mukaisesti —
kaikki paikallisesti, näppäimistöltä).

**Verkko-HTTP (ei tänään):** vaatii NIC-ajurin + TCP-pinon, joita ei ole.
Rehellinen tiekartta, ei esto:

1. Tunnista verkkopiiri: Linux/Windows-puolella `lspci`/`msinfo32` →
   todennäköisesti Realtek (kirjaa PCI ID).
2. Realtek on luonteva **Phase-36-kohde**: laite ilmoittaa kykynsä
   (`docs/HW_CAP_PROTOCOL.md`), plan generoidaan (`kernel/hw_gen.zig`),
   elinkaari testataan ensin feikkiä, sitten QEMU:a ja viimein tätä
   läppäriä vasten.
3. Vasta NIC:n jälkeen: TCP (Phase 35:n jatko, nyt loopback-only) → web-plugin
   (POC.md Phase 6–8) → sivu puhelimesta auki → pitkäaikaistesti (Phase 9).

Älä siis kirjaa "verkko ei toimi" bugiksi — se on dokumentoitu puute
(VSL-spec §9, FEDERATION.md F-L1), jolla on omistaja (tiekartta) ja
koekenttä (tämä läppäri).

---

## Turvaohjeet (lue ennen ensimmäistä boottia)

1. **Tikku on ainoa mihin kirjoitat.** `dd`:n `of=`-kohde tarkistetaan kahdesti.
2. **Sisäinen levy on koskematon** — kernelissä ei ole eMMC/SATA-ajuria,
   joten se ei voi vahingoittaa Windowsia edes teoriassa tässä vaiheessa.
3. **Jumista selviää virtanapilla** (5 s pohjassa). QEMU-exit-pysähdys ja
   scheduler-idle ovat normaaleja lopputiloja, eivät kaatumisia.
4. **Secure Boot takaisin päälle** jos palautat koneen Windows-käyttöön
   (firmware palautuu, tikun boottaus vain lakkaa toimimasta).
5. **Sarjaporttia ei ole** — kaikki havainnot tehdään näytöltä (ota kuva
   puhelimella lokin sijaan; liitä päiväkirjaan).

---

## Sanasto (lyhyesti)

| Termi | Tarkoittaa tässä ohjeessa |
|-------|---------------------------|
| Smoke / full / dev | Build-optio `-Dboot=`: nopea alustus / täysi testisarja / vuorovaikutteinen ajo |
| VSL (Väinö Subsystem for Linux) | Userland-plugin joka kääntää minimi-Linux-ABI:n Zinux-syscalleiksi — toimii tikulta ilman asennusta |
| tmpfs | RAM-levy: tiedostot toimivat mutta katoavat virran katketessa |
| Sokea bootti | Kerneli käy mutta VGA-teksti ei näy (UEFI-GOP ilman CSM:ää) |
| Eeden-serialit (`Eeden Gate: PASSED` ym.) | Elinkaaridemojen onnistumisrivejä — iloinen merkki, ei virhe |

*Ohjeen tila: laadittu koodikatselmuksen pohjalta (ajurit, boot-polku, rajoitteet
tarkistettu lähteistä). Päivitä Stage 2.3:aa sitä mukaa kun oikeita
havaintoja kertyy — jokainen rivi tuolla on arvokkaampi kuin teoria.*
