# Testplan stap 1: Clavinova CLP-230 → Steam Frame (USB-MIDI)

Doel: vóór we lessen bouwen, zeker weten dat (a) de headset de piano ziet, (b) een
native Godot-app de noten binnenkrijgt en (c) passthrough beschikbaar is voor apps.
Reken op ongeveer 45 minuten. Vul de tabel onderaan in en stuur me het bestand
`piano_vr_diagnose.txt` terug.

## Wat je nodig hebt

- Clavinova CLP-230 met een **USB-B naar USB-C**-kabel (of USB-B naar USB-A plus hub).
- **Sterk aangeraden:** een kleine USB-C-hub met USB 2.0-poorten en **PD-doorvoer** (opladen).
  De CLP-230 is een "full-speed" USB 1.1-apparaat. Precies dat type apparaat faalt op dit moment
  soms op de directe poort van de Frame en werkt wel via een hub
  ([SteamOS issue #2846](https://github.com/valvesoftware/steamos/issues/2846)). Met een PD-hub
  laadt de Frame bovendien op terwijl je speelt.
- Pc met de **SteamOS Devkit Client** en **Godot 4.6** (met export templates).
- Steam Frame met **Developer Mode** aan (Instellingen › Systeem › Developer Mode), met een wachtwoord ingesteld.

---

## Fase 0: ziet SteamOS de piano? (10 min, nog zonder app)

1. Zet de piano aan en verbind hem **rechtstreeks** met de Frame.
2. Log in vanaf je pc: `ssh steamos@<ip-van-de-headset>`
3. Voer uit en bewaar de uitvoer:
   ```bash
   cat /proc/asound/cards
   ls -l /dev/snd/
   lsusb 2>/dev/null || ls /sys/bus/usb/devices/
   sudo dmesg | tail -40
   ```
   **Goed:** in `cards` staat een Yamaha-regel (bv. `CLP-230` of `Digital Piano`) en in `/dev/snd/` staat een `midiC?D0`.
   **Fout:** in `dmesg` staat `error -71` of `device descriptor read`. Probeer dan de hub (stap 5).
4. Ruwe MIDI-test (vervang `C1` door het nummer uit stap 3):
   ```bash
   cat /dev/snd/midiC1D0 | od -An -tx1 -w3
   ```
   Speel een paar toetsen. Je moet regels zien zoals `90 3c 45` (noot aan) en `90 3c 00` (noot los).
   Een `fe` die steeds terugkomt is "active sensing" van de Clavinova, dat is normaal. Stop met Ctrl+C.
5. Lukt het niet direct, herhaal 3 en 4 **via de hub**. Lukt het nog niet, test de 5-pins
   **MIDI OUT** van de piano met een class-compliant USB-MIDI-kabel (ook via de hub).

Als fase 0 slaagt, is de grootste onzekerheid van het project weg.

## Fase 1 (optioneel): app op je pc

1. Open de map `step1-midi-test` in Godot 4.6 (Import › `project.godot`).
2. Druk op F5. Zonder headset start de app in een gewoon venster.
3. Zonder piano: start met `-- --demo` (Project › Project Settings › Run › Main Run Args `--demo`,
   of vanaf de commandoregel `godot --path . -- --demo`). Je ziet dan nepnoten oplichten.
4. Met de piano aan je pc: elke aanslag moet oplichten. (Op Windows heeft de CLP-230
   mogelijk de Yamaha USB-MIDI-driver nodig. Op Linux en de Frame niet.)

## Fase 2: app op de Steam Frame

1. In Godot: Project › Export › preset **Steam Frame Arm64** › Export Project
   (niet "Export PCK"). Of vanaf de commandoregel:
   `godot --headless --path . --export-release "Steam Frame Arm64"`
   Het resultaat staat in `build/frame-arm64/`.
2. SteamOS Devkit Client › Title Upload:
   - Name: `Piano VR MIDI Test`
   - Local Folder: `build/frame-arm64`
   - Start Command: `PianoVRMidiTest.arm64`
   - Runtime: **Steam Linux Runtime 3.0 ARM64 (Sniper)**
3. Upload, en dan Start. De app staat ook in je bibliotheek onder Non-Steam › Devkit Game.
4. Als het diagnosepaneel `Geluidsdriver: Dummy` toont: zet bij Eigenschappen › Startopties
   `%command% --audio-driver ALSA` en start opnieuw. (Godot laadt de ALSA-MIDI-bibliotheek alleen
   mee met een echte geluidsdriver.)

### Bediening in de headset

| Knop | Actie |
|---|---|
| Rechter trekker | Kalibreren: 1e keer linkervoorhoek van A0, 2e keer rechtervoorhoek van C8 (geel bolletje = meetpunt) |
| A / X | Passthrough aan/uit |
| B / Y | MIDI opnieuw scannen (na loskoppelen/aansluiten) |
| Linker trekker | Statistieken op nul + diagnose opslaan |

## Checklist op de headset

| # | Test | Hoe | Verwacht | Resultaat |
|---|---|---|---|---|
| 1 | Geluidsdriver | Diagnosepaneel rechts | `PulseAudio` of `ALSA`, niet `Dummy` | |
| 2 | OpenXR | Diagnosepaneel | `OpenXR geinitialiseerd: true`, systeemnaam staat erbij | |
| 3 | Passthrough | Diagnosepaneel + kijken | `ALPHA_BLEND ... true` en je ziet je kamer achter het klavier | |
| 4 | USB | Diagnosepaneel | Regel met `0499` en `<== YAMAHA`, snelheid 12 | |
| 5 | MIDI-ingang | Bovenste paneel | De naam van de Clavinova in plaats van "GEEN MIDI-apparaat" | |
| 6 | Alle 88 toetsen | Glissando van A0 naar C8, wit en zwart | Elke toets licht op, A0 en C8 ook | |
| 7 | Aanslag | Heel zacht, dan heel hard | Velocity loopt van ongeveer 5-20 tot 110-127; kleur van blauw naar oranje | |
| 8 | Polyfonie | Beide onderarmen op de toetsen, dan loslaten | "Max tegelijk" 15 of meer; daarna "Ingedrukt nu 0" en Aanslagen = Losgelaten | |
| 9 | Pedalen | Elk pedaal langzaam indrukken | sustain (CC64), sostenuto (CC66) en soft (CC67) bewegen; noteer of sustain tussenwaarden geeft | |
| 10 | Vertraging | Snelle herhaalde noten | Licht en klank voelen gelijktijdig | |
| 11 | Hotplug | Kabel los en terug, dan B/Y | Apparaat verschijnt opnieuw | |
| 12 | Kalibratie | Rechter trekker op A0 links-voor, dan C8 rechts-voor | Gemeten ≈ 122 cm; virtueel klavier valt op het echte (noteer afwijking in cm) | |
| 13 | Stabiliteit | 10 minuten spelen | Geen hangende noten, geen haperingen | |
| 14 | Opladen (hub) | Met PD-hub en lader | Batterij stijgt of blijft gelijk | |

## Resultaten terugsturen

De app schrijft `piano_vr_diagnose.txt` bij het opstarten en telkens als je op de linker
trekker drukt. Het volledige pad staat bovenaan in het diagnosepaneel (`user://`).
Kopieer het naar je pc, bijvoorbeeld:

```bash
scp "steamos@<ip-van-de-headset>:~/.local/share/godot/app_userdata/Piano VR MIDI Test/piano_vr_diagnose.txt" .
```

Stuur me dat bestand, de uitvoer van fase 0 en de ingevulde tabel. Daarmee beslissen we stap 2.
