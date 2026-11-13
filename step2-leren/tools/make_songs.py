"""Generates the bundled practice songs as Standard MIDI Files (format 1).

All pieces are public-domain compositions; the arrangements below are written
for KeySight and released under the project's MIT licence.
Track 1 = tempo, track 2 = right hand, track 3 = left hand.

Usage: python make_songs.py   (writes into ../songs)
"""
import os
import struct

TPQ = 480
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "songs")
NAMES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def pitch(n):
    """'C4' -> 60, 'D#5' -> 75, 'Bb3' -> 58."""
    base = NAMES[n[0]]
    i = 1
    if n[i] == "#":
        base += 1
        i += 1
    elif n[i] == "b":
        base -= 1
        i += 1
    return 12 * (int(n[i:]) + 1) + base


def voice(spec, beat=1.0):
    """'C4:1 D4:0.5 r:0.5 C4+E4+G4:2' -> [(start, dur, [pitches])] in quarter notes."""
    t = 0.0
    out = []
    for tok in spec.split():
        name, d = tok.split(":")
        d = float(d) * beat
        if name != "r":
            out.append((t, d, [pitch(p) for p in name.split("+")]))
        t += d
    return out


def vlq(v):
    b = [v & 0x7F]
    v >>= 7
    while v:
        b.insert(0, (v & 0x7F) | 0x80)
        v >>= 7
    return bytes(b)


def track(events, name):
    """events: [(tick, bytes)]"""
    data = b"\x00\xff\x03" + vlq(len(name)) + name.encode()
    last = 0
    for tick, msg in sorted(events, key=lambda e: (e[0], e[1][0] & 0xF0 != 0x80)):
        data += vlq(tick - last) + msg
        last = tick
    data += b"\x00\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(data)) + data


def notes_track(notes, name, vel, ch):
    ev = []
    for start, dur, ps in notes:
        on = int(round(start * TPQ))
        off = int(round((start + dur * 0.95) * TPQ))
        for p in ps:
            ev.append((on, bytes([0x90 | ch, p, vel])))
            ev.append((off, bytes([0x80 | ch, p, 0])))
    return track(ev, name)


def write(fname, title, bpm, right, left, num=4, den=4):
    us = int(60_000_000 / bpm)
    tempo = b"\x00\xff\x03" + vlq(len(title)) + title.encode()
    tempo += b"\x00\xff\x51\x03" + us.to_bytes(3, "big")
    tempo += b"\x00\xff\x58\x04" + bytes([num, {2: 1, 4: 2, 8: 3}[den], 24, 8])
    tempo += b"\x00\xff\x2f\x00"
    head = b"MThd" + struct.pack(">IHHH", 6, 1, 3, TPQ)
    body = (b"MTrk" + struct.pack(">I", len(tempo)) + tempo
            + notes_track(right, "Right hand", 84, 0) + notes_track(left, "Left hand", 64, 1))
    with open(os.path.join(OUT, fname), "wb") as f:
        f.write(head + body)
    print(fname, len(right), "+", len(left), "notes")


def c_scale():
    """C major scale, up and down: first right hand, then left hand, then together."""
    up = ["C", "D", "E", "F", "G", "A", "B"]
    def run(octave):
        names = [f"{n}{octave}" for n in up] + [f"C{octave + 1}"] + [f"{n}{octave}" for n in reversed(up)]
        return " ".join(f"{n}:1" for n in names) + " r:1"
    rest = "r:16"
    rh = voice(" ".join([run(4), rest, run(4)]))
    lh = voice(" ".join([rest, run(3), run(3)]))
    write("00 C major scale (exercise).mid", "C major scale", 80, rh, lh)


def twinkle():
    a = "C4:1 C4:1 G4:1 G4:1 A4:1 A4:1 G4:2 F4:1 F4:1 E4:1 E4:1 D4:1 D4:1 C4:2"
    b = "G4:1 G4:1 F4:1 F4:1 E4:1 E4:1 D4:2"
    rh = voice(" ".join([a, b, b, a]))
    la = "C3:4 F3:2 C3:2 F3:2 C3:2 G2:2 C3:2"
    lb = "C3:2 G2:2 C3:2 G2:2"
    lh = voice(" ".join([la, lb, lb, la]))
    write("01 Twinkle Twinkle Little Star (traditional).mid", "Twinkle Twinkle Little Star", 100, rh, lh)


def frere_jacques():
    """Round in two voices: the left hand enters two bars later, an octave lower."""
    tune = ("C4:1 D4:1 E4:1 C4:1 C4:1 D4:1 E4:1 C4:1 E4:1 F4:1 G4:2 E4:1 F4:1 G4:2 "
            "G4:0.5 A4:0.5 G4:0.5 F4:0.5 E4:1 C4:1 G4:0.5 A4:0.5 G4:0.5 F4:0.5 E4:1 C4:1 "
            "C4:1 G3:1 C4:2 C4:1 G3:1 C4:2")
    rh = voice(tune + " " + tune)
    low = [(s + 8.0, d, [p - 12 for p in ps]) for s, d, ps in voice(tune + " " + tune)]
    lh = [n for n in low if n[0] < 64.0]
    write("02 Frere Jacques - round (traditional).mid", "Frere Jacques (round)", 110, rh, lh)


def ode_to_joy():
    """Beethoven, Symphony no. 9, 4th movement theme."""
    a = "E4:1 E4:1 F4:1 G4:1 G4:1 F4:1 E4:1 D4:1 C4:1 C4:1 D4:1 E4:1"
    end1 = "E4:1.5 D4:0.5 D4:2"
    end2 = "D4:1.5 C4:0.5 C4:2"
    b = ("D4:1 D4:1 E4:1 C4:1 D4:1 E4:0.5 F4:0.5 E4:1 C4:1 "
         "D4:1 E4:0.5 F4:0.5 E4:1 D4:1 C4:1 D4:1 G3:2")
    rh = voice(" ".join([a, end1, a, end2, b, a, end2]))
    l1 = "C3:4 G2:4 C3:4 G2:4"
    l2 = "C3:4 G2:4 C3:4 G2:2 C3:2"
    lb = "G2:2 C3:2 G2:2 C3:2 G2:2 C3:2 C3:2 G2:2"
    lh = voice(" ".join([l1, l2, lb, l2]))
    write("03 Ode to Joy (Beethoven).mid", "Ode to Joy", 104, rh, lh)


def fur_elise():
    """Beethoven, Bagatelle WoO 59, opening section (3/8). Unit = sixteenth note."""
    s = 0.25   # a sixteenth note in quarter notes
    rh_spec = ("E5:1 D#5:1 "
               "E5:1 D#5:1 E5:1 B4:1 D5:1 C5:1 "
               "A4:2 r:1 C4:1 E4:1 A4:1 "
               "B4:2 r:1 E4:1 G#4:1 B4:1 "
               "C5:2 r:1 E4:1 E5:1 D#5:1 "
               "E5:1 D#5:1 E5:1 B4:1 D5:1 C5:1 "
               "A4:2 r:1 C4:1 E4:1 A4:1 "
               "B4:2 r:1 E4:1 C5:1 B4:1 "
               "A4:6")
    rh = voice(rh_spec, s)
    bar = 6.0 * s
    start = 2 * s + bar   # pickup + first bar of sixteenths
    lh = []
    for i, chord in enumerate([("A2", "E3", "A3"), ("E2", "E3", "G#3"), ("A2", "E3", "A3"),
                               None, ("A2", "E3", "A3"), ("E2", "E3", "G#3"), ("A2", "E3", "A3")]):
        if chord is None:
            continue
        t0 = start + i * bar
        for k, n in enumerate(chord):
            lh.append((t0 + k * s, s, [pitch(n)]))
    write("04 Fur Elise - opening (Beethoven).mid", "Fur Elise (opening)", 66, rh, lh, 3, 8)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    c_scale()
    twinkle()
    frere_jacques()
    ode_to_joy()
    fur_elise()
