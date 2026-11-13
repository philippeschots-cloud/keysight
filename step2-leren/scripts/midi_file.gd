class_name MidiSong
extends RefCounted
## Leest een Standard MIDI File (.mid, format 0 en 1) en zet hem om naar
## noten in seconden, klaar om te oefenen.
##
## Elke noot is een Dictionary:
##   pitch (int), start (float s), end (float s), vel (int), track (int),
##   channel (int), hand (0 = links, 1 = rechts)
## Pedaal: `pedal` is een lijst [tijd_s, ingedrukt_bool] (CC64, drempel 64).

var title := ""
var path := ""
var notes: Array[Dictionary] = []   # gesorteerd op start, dan toonhoogte
var pedal: Array = []                # [[t, down], ...]
var duration := 0.0
var error := ""
var track_count := 0
var hand_rule := ""                  # hoe linker/rechterhand is bepaald

var _tempo: Array = []               # [[tick, us_per_quarter], ...]
var _division := 480
var _smpte_fps := 0.0
var _smpte_tpf := 0


static func load_file(file_path: String) -> MidiSong:
	var s := MidiSong.new()
	s.path = file_path
	s.title = file_path.get_file().get_basename()
	# Voorvoegsel "01 " (sorteernummer) niet tonen.
	var rx := RegEx.create_from_string("^\\d+\\s+")
	s.title = rx.sub(s.title, "")
	var bytes := FileAccess.get_file_as_bytes(file_path)
	if bytes.is_empty():
		s.error = "kan bestand niet lezen"
		return s
	s.parse(bytes)
	return s


func parse(b: PackedByteArray) -> void:
	if b.size() < 14 or b.slice(0, 4).get_string_from_ascii() != "MThd":
		error = "geen MIDI-bestand (MThd ontbreekt)"
		return
	var hlen := _u32(b, 4)
	var fmt := _u16(b, 8)
	var ntrk := _u16(b, 10)
	var div := _u16(b, 12)
	if fmt > 1:
		error = "MIDI-format %d wordt niet ondersteund" % fmt
		return
	if div & 0x8000:
		var fps_code := 256 - ((div >> 8) & 0xFF)
		_smpte_fps = 29.97 if fps_code == 29 else float(fps_code)
		_smpte_tpf = div & 0xFF
	else:
		_division = maxi(div, 1)

	var pos := 8 + hlen
	var raw_events: Array = []   # [tick, track, status, d1, d2]
	var t_index := 0
	while pos + 8 <= b.size() and t_index < ntrk:
		var id := b.slice(pos, pos + 4).get_string_from_ascii()
		var length := _u32(b, pos + 4)
		pos += 8
		if id != "MTrk":
			pos += length
			continue
		_parse_track(b, pos, mini(pos + length, b.size()), t_index, raw_events)
		pos += length
		t_index += 1
	track_count = t_index
	if _tempo.is_empty():
		_tempo.append([0, 500000])
	_tempo.sort_custom(func(a, c): return a[0] < c[0])
	_build_notes(raw_events)


func _parse_track(b: PackedByteArray, pos: int, end: int, track: int, out: Array) -> void:
	var tick := 0
	var running := 0
	while pos < end:
		var r := _vlq(b, pos)
		tick += r[0]
		pos = r[1]
		if pos >= end:
			break
		var status := b[pos]
		if status == 0xFF:
			var mtype := b[pos + 1]
			var lr := _vlq(b, pos + 2)
			var mlen: int = lr[0]
			var mpos: int = lr[1]
			if mtype == 0x51 and mlen == 3:
				_tempo.append([tick, (b[mpos] << 16) | (b[mpos + 1] << 8) | b[mpos + 2]])
			elif mtype == 0x2F:
				pos = end
				break
			pos = mpos + mlen
			continue
		if status == 0xF0 or status == 0xF7:
			var sr := _vlq(b, pos + 1)
			pos = sr[1] + sr[0]
			continue
		var d_pos := pos
		if status & 0x80:
			running = status
			d_pos = pos + 1
		else:
			status = running
		if status == 0:
			break   # kapot bestand
		var kind := status & 0xF0
		var n_data := 1 if (kind == 0xC0 or kind == 0xD0) else 2
		if d_pos + n_data > end:
			break
		var d1 := b[d_pos]
		var d2 := b[d_pos + 1] if n_data == 2 else 0
		pos = d_pos + n_data
		if kind == 0x80 or kind == 0x90 or (kind == 0xB0 and d1 == 64):
			out.append([tick, track, status, d1, d2])


func ticks_to_seconds(tick: int) -> float:
	if _smpte_tpf > 0:
		return tick / (_smpte_fps * _smpte_tpf)
	var sec := 0.0
	var last_tick := 0
	var us := 500000
	for t in _tempo:
		if t[0] >= tick:
			break
		sec += (t[0] - last_tick) * us / 1000000.0 / _division
		last_tick = t[0]
		us = t[1]
	sec += (tick - last_tick) * us / 1000000.0 / _division
	return sec


func _build_notes(events: Array) -> void:
	events.sort_custom(func(a, c): return a[0] < c[0] if a[0] != c[0] else a[1] < c[1])
	var open := {}   # "track:chan:pitch" -> Array van open noten
	var last_tick := 0
	var pedal_down := false
	var track_notes := {}   # track -> aantal
	var chan_set := {}
	for e in events:
		var tick: int = e[0]
		var track: int = e[1]
		var status: int = e[2]
		var kind := status & 0xF0
		var ch := status & 0x0F
		last_tick = maxi(last_tick, tick)
		if kind == 0xB0:
			var down: bool = e[4] >= 64
			if down != pedal_down:
				pedal_down = down
				pedal.append([ticks_to_seconds(tick), down])
			continue
		if ch == 9:
			continue   # drumkanaal (10) overslaan
		var pitch: int = e[3]
		var vel: int = e[4]
		var key := "%d:%d:%d" % [track, ch, pitch]
		if kind == 0x90 and vel > 0:
			var n := {"pitch": pitch, "start_tick": tick, "end_tick": -1, "vel": vel,
				"track": track, "channel": ch, "hand": 1}
			if not open.has(key):
				open[key] = []
			open[key].append(n)
			notes.append(n)
			track_notes[track] = int(track_notes.get(track, 0)) + 1
			chan_set[ch] = true
		else:
			if open.has(key) and not open[key].is_empty():
				var n: Dictionary = open[key].pop_front()
				n["end_tick"] = tick
	for n in notes:
		if n["end_tick"] < 0:
			n["end_tick"] = last_tick
		n["start"] = ticks_to_seconds(n["start_tick"])
		n["end"] = maxf(ticks_to_seconds(n["end_tick"]), n["start"] + 0.05)
		n.erase("start_tick")
		n.erase("end_tick")
	notes.sort_custom(func(a, c): return a["start"] < c["start"] if not is_equal_approx(a["start"], c["start"]) else a["pitch"] < c["pitch"])
	_assign_hands(track_notes)
	for n in notes:
		duration = maxf(duration, n["end"])
	if notes.is_empty():
		error = "geen noten gevonden"


## Linker- of rechterhand bepalen. Twee of meer sporen met noten: het spoor
## met de hoogste gemiddelde toonhoogte is de rechterhand. Eén spoor: per
## akkoord splitsen rond de centrale C (noot < 60 = links).
func _assign_hands(track_notes: Dictionary) -> void:
	if track_notes.size() >= 2:
		var avg := {}
		for t in track_notes.keys():
			avg[t] = 0.0
		for n in notes:
			avg[n["track"]] += n["pitch"]
		for t in avg.keys():
			avg[t] /= float(track_notes[t])
		var best_t = avg.keys()[0]
		for t in avg.keys():
			if avg[t] > avg[best_t]:
				best_t = t
		for n in notes:
			if n["track"] == best_t:
				n["hand"] = 1
			else:
				n["hand"] = 1 if avg[n["track"]] >= 64.0 else 0
		hand_rule = "per spoor (%d sporen)" % track_notes.size()
	else:
		for n in notes:
			n["hand"] = 0 if n["pitch"] < 60 else 1
		hand_rule = "split op centrale C"


static func _u16(b: PackedByteArray, p: int) -> int:
	return (b[p] << 8) | b[p + 1]


static func _u32(b: PackedByteArray, p: int) -> int:
	return (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]


static func _vlq(b: PackedByteArray, p: int) -> Array:
	var v := 0
	for i in 4:
		if p >= b.size():
			break
		var c := b[p]
		p += 1
		v = (v << 7) | (c & 0x7F)
		if c & 0x80 == 0:
			break
	return [v, p]
