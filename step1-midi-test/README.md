# Piano VR: stap 1, MIDI-test

Minimale Godot 4.6-app voor de Steam Frame (native Linux ARM64, OpenXR). Hij toont:

- een virtueel 88-toetsenklavier op ware grootte dat oplicht bij elke aanslag (kleur = aanslagsterkte);
- een live MIDI-log, tellers (aanslagen, losgelaten, polyfonie, "wees"-note-offs) en pedaalstanden;
- een diagnosepaneel: platform, geluidsdriver, OpenXR en blend modes (passthrough), ALSA-kaarten,
  `/dev/snd` en USB-apparaten (Yamaha en full-speed worden gemarkeerd);
- passthrough (alpha blend) als de runtime dat aanbiedt;
- een kalibratie met twee punten (controller op A0 en op C8) die het virtuele klavier op de echte piano legt.

Zonder headset start de app in een gewoon venster, handig om op de pc te testen.
Met `-- --demo` speelt hij nep-MIDI af.

Zie [TESTPLAN.md](TESTPLAN.md) voor de test op de headset.

## Structuur

| Bestand | Rol |
|---|---|
| `scripts/main.gd` | XR-opstart, passthrough, scene, bediening, panelen, kalibratie, demo |
| `scripts/midi_monitor.gd` | MIDI openen/herscannen, events naar signalen, statistieken |
| `scripts/piano_keyboard.gd` | 88-toetsen-geometrie op ware maat + plaatsen via twee hoekpunten (herbruikbaar in stap 2-3) |
| `scripts/diagnostics.gd` | Systeeminfo via `/proc` en `/sys` (geen externe tools nodig in de runtime-container) |
| `export_presets.cfg` | `Steam Frame Arm64` (Linux arm64) en een pc-preset |

## Bekende valkuilen (geverifieerd)

- **Godot ALSA-MIDI heeft een echte geluidsdriver nodig.** Godot 4.6 laadt `libasound` alleen mee met de
  ALSA- of PulseAudio-geluidsdriver. Met de Dummy-driver crasht `OS.open_midi_inputs()` (gereproduceerd
  in headless-modus). De app controleert dit en schakelt MIDI dan uit met een melding.
- **Geen automatische hotplug.** Godot scant MIDI-apparaten alleen bij `open_midi_inputs()`. De app
  herscant elke 3 s zolang er niets gevonden is; daarna met B/Y.
- **Note-off als "note-on met velocity 0"** wordt correct als loslaten behandeld.

Getest met Godot 4.6.2 op Linux x86_64 (headless + Xvfb, met de demo). Nog niet getest op de Frame
zelf of met de echte piano: dat is precies wat het testplan doet.

## Credits

De aanpak voor uitlijning (klavier op ware maat, tegels per toets) is bestudeerd in
[piARno](https://github.com/piARn0/piARnoApp) (MIT). De code hier is nieuw geschreven.
