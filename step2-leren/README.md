# KeySight

Leer piano spelen op je eigen piano met de Steam Frame. KeySight draait native op de Frame
(Godot 4.6, Linux ARM64, OpenXR) en legt vallende noten over de echte toetsen (passthrough).

## Wat het doet

- **Vallende noten** in een verticaal vlak op de achterrand van de toetsen. De onderkant van een
  balk raakt de toets precies op het moment van aanslaan, en de lengte van de balk is de duur.
  Rechterhand oranje, linkerhand blauw. De doeltoets licht vooraf op: groen = raak, rood = fout.
  Er is een zachte gloed op de plek waar de balk de toets raakt.
- **Wachtmodus**: de klok staat stil bij elk akkoord (noten binnen 40 ms) tot je alle tonen
  hebt ingedrukt. Je mag 0,35 s te vroeg zijn. De klok start bij de eerste juiste toets.
- **Meespelen** in tempo 30-150%. Oefenen **per hand**: de andere hand wordt gedimd getoond
  en hoeft niet.
- **MIDI-bestanden**: format 0 en 1, tempowissels, running status, pedaal (CC64). Het drumkanaal
  wordt overgeslagen. Handen: met twee sporen is het spoor met de hoogste gemiddelde toon de
  rechterhand, anders wordt gesplitst op de centrale C.
  Eigen bestanden: zet `.mid` in `~/pianovr/songs` op de headset (naast `KeySight.arm64`), of in
  `user://songs`.
- **Feedback**: tijdens het spelen raak/fout/gemist per noot. Na afloop een resultatenkaart
  (percentage, raak/fout/gemist/reeks, timing, lastigste stuk, één tip) en een volledig rapport
  in `rapporten/` met timing (vroeg/laat, spreiding), verwisselde toetsen, linker- tegen
  rechterhand, wit tegen zwart, loslaten van lange noten, dynamiek, pedaalwissels en tips.
  De beste score per lied staat in de liedjeslijst.
- **Automatische kalibratie**: druk met het gele bolletje van een controller een paar echte
  toetsen in. Via MIDI weet de app precies welke toets het was. Een kleinste-kwadratenlijn
  bepaalt plek, richting en breedte van jouw klavier. Uitschieters, twee toetsen tegelijk en
  een breedte die meer dan 5% afwijkt worden geweigerd. Daarna kun je met **Bijstellen** het
  klavier met de sticks nog verschuiven, omhoog/omlaag zetten en draaien. Wordt bewaard.

## Bediening

| Waar | Actie |
|---|---|
| Controller | Wijs naar het scherm, trekker = klikken, stick = lijst scrollen. A/X start/pauze, B/Y opnieuw |
| Zonder controller | Middelste pedaal = start/pauze/opnieuw. In het menu: laagste A = vorig lied, laagste B = volgend lied |
| Pc (test) | Muis op het scherm, spatie, pijltjes (lied/tempo), W, H, R, B (-5 s), K, P, Esc |

## Bouwen en testen

```bash
godot --headless --path . --import
godot --headless --path . -- --selftest          # MIDI, kalibratie-wiskunde, wachtmodus, scores
godot --path . -- --demo --song 5 --nowait        # speelt zelf, met kleine foutjes
godot --headless --path . --export-release "Steam Frame Arm64"   # -> build/frame-arm64/KeySight.arm64
```

Op de headset staat het in `~/pianovr` (`keysight.sh` start de app en schrijft
`keysight_last_run.log`), in de bibliotheek als non-Steam-snelkoppeling **KeySight**.
Gebruikersgegevens (kalibratie, instellingen, scores, rapporten): `~/.local/share/KeySight/`.

## Structuur

| Bestand | Rol |
|---|---|
| `scripts/main.gd` | XR, scène, toestanden (menu/les/resultaat/kalibratie), invoer, opslaan |
| `scripts/app_ui.gd` | Interface: thema, menu, les-balk, resultatenkaart, kalibratie, diagnose |
| `scripts/vr_screen.gd` | SubViewport op een vlak; straal/muis naar knop-events |
| `scripts/practice_session.gd` | Liedklok, wachtmodus, raak/fout/gemist, rapport en tips |
| `scripts/note_highway.gd` | Vallende noten (MultiMesh), gloed, toets-hints |
| `scripts/midi_file.gd` | MIDI-bestanden inlezen (SMF) |
| `scripts/auto_calibrator.gd` | Kalibratie met MIDI + controllerpositie |
| `scripts/piano_keyboard.gd` | 88-toetsenklavier op ware maat, lagen voor hint/aanslag/flits |
| `scripts/midi_monitor.gd`, `scripts/diagnostics.gd` | Uit stap 1 |
| `scripts/selftest.gd` | Zelftest zonder headset |

## Licenties en credits

- Idee en kleuren van de vallende tegels per hand: [piARno](https://github.com/piARn0/piARnoApp)
  (MIT, © 2016 Joong-Won Seo, Mohammad Naanaa, Jack Sterling Klusmann). De code hier is nieuw
  geschreven in GDScript. piARno is een Quest-app in C++ en kan niet direct op de Frame draaien.
- De liedjes in `songs/` zijn vrije composities (publiek domein) in eigen arrangementen, gemaakt
  met `tools/make_songs.py`. Eigen liedjes worden niet in de app ingebouwd.
- Lettertype: Atkinson Hyperlegible, © 2020 Braille Institute of America, SIL Open Font License
  1.1 (`fonts/OFL.txt`).
- De piano maakt zelf het geluid. Godot heeft geen MIDI-uitgang, dus er is geen begeleiding.
