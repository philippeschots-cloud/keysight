class_name PracticeSession
extends RefCounted
## Oefenlogica, los van het tekenen: liedklok, wachtmodus, raak/fout/gemist,
## timing, aanslag, loslaten, pedaal en het feedbackrapport.

signal finished(report: String)

const TOL_REAL := 0.20        # s: aanslag telt als raak binnen deze marge (echte tijd)
const EARLY_WAIT := 0.35      # s: in wachtmodus mag je zoveel te vroeg zijn
const CHORD_WINDOW := 0.040   # s: noten binnen 40 ms vormen één akkoord
const LEAD_IN := 2.5          # s liedtijd voor de eerste noot
const SECTION_LEN := 8.0      # s liedtijd per stukje in het rapport
const PERFECT_MS := 50.0


var song: MidiSong
var notes: Array[Dictionary] = []
var t := 0.0
var playing := false
var wait_mode := true
var speed := 1.0:
	set(v):
		speed = clampf(snappedf(v, 0.05), 0.30, 1.50)
var practice_hand := -1        # -1 beide, 0 links, 1 rechts
var waiting := false           # wachtmodus: klok staat stil op een akkoord
var done := false
var max_note_len := 0.0

var groups: Array = []         # [{time, idx: [..]}]
var _gi := 0
var _cursor := 0

# Live statistiek
var hits := 0
var wrong := 0
var missed := 0
var streak := 0
var best_streak := 0
var last_feedback := ""
var wrong_events: Array = []   # [t, gespeeld, bedoeld(-1)]
var pedal_user: Array = []     # [t, down]
var _pedal_down := false
var _active_hits := {}         # pitch -> note-index (voor loslaten)
var _session_start_t := 0.0
var _used_wait := false
var _started_real_msec := 0
var summary := {}              # laatste analyse, voor de resultatenkaart


func load_song(s: MidiSong) -> void:
	song = s
	notes.clear()
	max_note_len = 0.0
	for n in s.notes:
		var p: int = n["pitch"]
		if p < PianoKeyboard.LOWEST_NOTE or p > PianoKeyboard.HIGHEST_NOTE:
			continue
		var c: Dictionary = n.duplicate()
		notes.append(c)
		max_note_len = maxf(max_note_len, c["end"] - c["start"])
	_build_groups()
	restart()


func _build_groups() -> void:
	groups.clear()
	var i := 0
	while i < notes.size():
		var g := {"time": notes[i]["start"], "idx": [i]}
		var j := i + 1
		while j < notes.size() and notes[j]["start"] - notes[i]["start"] <= CHORD_WINDOW:
			g["idx"].append(j)
			j += 1
		for k in g["idx"]:
			notes[k]["group"] = groups.size()
		groups.append(g)
		i = j


func restart() -> void:
	t = (notes[0]["start"] if not notes.is_empty() else 0.0) - LEAD_IN
	_session_start_t = t
	playing = false
	waiting = false
	done = false
	_gi = 0
	_cursor = 0
	hits = 0
	wrong = 0
	missed = 0
	streak = 0
	best_streak = 0
	last_feedback = ""
	wrong_events.clear()
	pedal_user.clear()
	_active_hits.clear()
	_used_wait = false
	_started_real_msec = Time.get_ticks_msec()
	for n in notes:
		_reset_note(n)


func _reset_note(n: Dictionary) -> void:
	n["state"] = NoteHighway.PENDING if is_practiced(n) else NoteHighway.OTHER_HAND
	n.erase("dt")
	n.erase("pvel")
	n.erase("held")
	n.erase("hit_t")


func is_practiced(n: Dictionary) -> bool:
	return practice_hand < 0 or n["hand"] == practice_hand


func set_practice_hand(h: int) -> void:
	practice_hand = h
	for n in notes:
		if n["state"] == NoteHighway.PENDING or n["state"] == NoteHighway.OTHER_HAND:
			n["state"] = NoteHighway.PENDING if is_practiced(n) else NoteHighway.OTHER_HAND
	_gi = 0


func set_wait_mode(on: bool) -> void:
	wait_mode = on
	waiting = false


func toggle_play() -> void:
	if done:
		restart()
	playing = not playing


## Spring `seconds` liedtijd terug (of vooruit) en zet de noten vanaf daar
## weer open.
func seek(seconds: float) -> void:
	var first: float = (notes[0]["start"] if not notes.is_empty() else 0.0) - LEAD_IN
	t = clampf(t + seconds, first, song.duration if song else 0.0)
	done = false
	for n in notes:
		if n["start"] >= t - 0.001:
			_reset_note(n)
	wrong_events = wrong_events.filter(func(w): return w[0] < t)
	_gi = 0
	_cursor = 0
	_recount()


func _recount() -> void:
	hits = 0
	missed = 0
	for n in notes:
		if n["state"] == NoteHighway.HIT:
			hits += 1
		elif n["state"] == NoteHighway.MISSED:
			missed += 1
	wrong = wrong_events.size()


## Index van de eerste noot die nog zichtbaar kan zijn.
func cursor() -> int:
	while _cursor < notes.size() and notes[_cursor]["start"] < t - max_note_len - 0.5:
		_cursor += 1
	while _cursor > 0 and notes[_cursor - 1]["start"] >= t - max_note_len - 0.5:
		_cursor -= 1
	return _cursor


func update(dt: float) -> void:
	if notes.is_empty() or done:
		return
	if not playing:
		return
	var new_t := t + dt * speed
	if wait_mode:
		_used_wait = true
	waiting = false
	if wait_mode:
		while _gi < groups.size() and _group_complete(_gi):
			_gi += 1
		if _gi < groups.size() and new_t >= groups[_gi]["time"]:
			new_t = maxf(t, groups[_gi]["time"])
			waiting = true
	else:
		var tol := TOL_REAL * speed
		var i := cursor()
		while i < notes.size() and notes[i]["start"] < new_t - tol:
			var n: Dictionary = notes[i]
			if n["state"] == NoteHighway.PENDING:
				n["state"] = NoteHighway.MISSED
				missed += 1
				streak = 0
				last_feedback = "Gemist: " + MidiMonitor.note_name(n["pitch"])
			i += 1
	t = new_t
	if t > song.duration + 1.0:
		_finish()


func _group_complete(gi: int) -> bool:
	for k in groups[gi]["idx"]:
		if notes[k]["state"] == NoteHighway.PENDING:
			return false
	return true


## Verwerkt een aanslag. Geeft {kind: "hit"|"wrong"|"other"|"free", dt_ms}.
func note_on(pitch: int, vel: int) -> Dictionary:
	if notes.is_empty() or done:
		return {"kind": "free"}
	if not playing:
		# Wachtmodus: de klok start bij de eerste juiste toets.
		if wait_mode and _matches_pending(pitch):
			playing = true
		else:
			return {"kind": "free"}
	var late := TOL_REAL * speed
	var early := (EARLY_WAIT if wait_mode else TOL_REAL) * speed
	var best := -1
	var best_d := INF
	var other := false
	var i := cursor()
	while i < notes.size():
		var n: Dictionary = notes[i]
		var start: float = n["start"]
		if start > t + early:
			break
		i += 1
		if n["pitch"] != pitch or start < t - late:
			continue
		if n["state"] == NoteHighway.OTHER_HAND:
			other = true
			continue
		if n["state"] != NoteHighway.PENDING:
			continue
		var d := absf(start - t)
		if d < best_d:
			best_d = d
			best = i - 1
	if best < 0:
		if other:
			return {"kind": "other"}
		# Dezelfde toets nog eens aanslaan voor een noot die al raak was: niet als fout tellen.
		var j := cursor()
		while j < notes.size() and notes[j]["start"] <= t + early:
			if notes[j]["pitch"] == pitch and notes[j]["state"] == NoteHighway.HIT and notes[j]["start"] >= t - late - 0.5 * speed:
				return {"kind": "repeat"}
			j += 1
		wrong += 1
		streak = 0
		var meant := _nearest_pending_pitch()
		wrong_events.append([t, pitch, meant])
		last_feedback = "Fout: %s" % MidiMonitor.note_name(pitch)
		if meant >= 0:
			last_feedback += " (bedoeld %s)" % MidiMonitor.note_name(meant)
		return {"kind": "wrong"}
	var n: Dictionary = notes[best]
	n["state"] = NoteHighway.HIT
	n["pvel"] = vel
	n["hit_t"] = t
	hits += 1
	streak += 1
	best_streak = maxi(best_streak, streak)
	_active_hits[pitch] = best
	var res := {"kind": "hit", "dt_ms": NAN}
	if not wait_mode:
		var dt_ms := (t - float(n["start"])) / speed * 1000.0
		n["dt"] = dt_ms
		res["dt_ms"] = dt_ms
		if absf(dt_ms) <= PERFECT_MS:
			last_feedback = "Perfect"
		elif dt_ms < 0:
			last_feedback = "Raak, %d ms te vroeg" % roundi(-dt_ms)
		else:
			last_feedback = "Raak, %d ms te laat" % roundi(dt_ms)
	else:
		last_feedback = "Raak"
	return res


func _matches_pending(pitch: int) -> bool:
	var i := cursor()
	while i < notes.size():
		var n: Dictionary = notes[i]
		if n["start"] > t + 60.0:
			break
		if n["state"] == NoteHighway.PENDING:
			# Eerste openstaande akkoord: zit deze toon erin?
			for k in groups[n["group"]]["idx"]:
				if notes[k]["pitch"] == pitch and notes[k]["state"] == NoteHighway.PENDING:
					t = maxf(t, float(n["start"]) - EARLY_WAIT * speed)
					return true
			return false
		i += 1
	return false


func _nearest_pending_pitch() -> int:
	var i := cursor()
	var best := -1
	var best_d := INF
	while i < notes.size():
		var n: Dictionary = notes[i]
		if n["start"] > t + 1.0 * speed:
			break
		if n["state"] == NoteHighway.PENDING or (n["state"] == NoteHighway.HIT and absf(n["start"] - t) < 0.3):
			var d := absf(float(n["start"]) - t)
			if d < best_d:
				best_d = d
				best = n["pitch"]
		i += 1
	return best


func note_off(pitch: int) -> void:
	if not _active_hits.has(pitch):
		return
	var n: Dictionary = notes[_active_hits[pitch]]
	_active_hits.erase(pitch)
	if wait_mode or not playing:
		return
	var length: float = n["end"] - n["start"]
	if length >= 0.4:
		n["held"] = clampf((t - float(n["hit_t"])) / length, 0.0, 2.0)


func pedal(value: int) -> void:
	var down := value >= 64
	if down == _pedal_down:
		return
	_pedal_down = down
	if playing and not wait_mode:
		pedal_user.append([t, down])


func stop_and_report() -> String:
	if hits + missed + wrong < 5:
		return ""
	return _finish()


func _finish() -> String:
	if done:
		return ""
	done = true
	playing = false
	var rep := build_report()
	finished.emit(rep)
	return rep


# ---------------------------------------------------------------- rapport

static func _mmss(sec: float) -> String:
	sec = maxf(sec, 0.0)
	return "%d:%02d" % [floori(sec / 60.0), floori(fmod(sec, 60.0))]


func build_report() -> String:
	var L := PackedStringArray()
	var title := song.title if song else "?"
	L.append("RAPPORT  %s" % title)
	L.append("%s  |  tempo %d%%  |  %s  |  hand: %s" % [
		Time.get_datetime_string_from_system(false, true), roundi(speed * 100),
		"wachtmodus" if _used_wait else "meespelen", ["links", "rechts"][practice_hand] if practice_hand >= 0 else "beide"])
	# Alleen noten tot waar je gekomen bent.
	var reached: Array[Dictionary] = []
	for n in notes:
		if n["start"] <= t and n["state"] != NoteHighway.OTHER_HAND:
			reached.append(n)
	var total := reached.size()
	summary = {"title": title, "total": total, "hits": hits, "wrong": wrong, "missed": missed,
		"acc": 0.0, "speed": speed, "wait": _used_wait, "hand": practice_hand,
		"streak": best_streak, "timing": "", "hardest": "", "tips": [], "hands": {}}
	if total == 0:
		L.append("Nog geen noten gespeeld.")
		return "\n".join(L)
	var acc := 100.0 * hits / total
	var prec := 100.0 * hits / maxf(1.0, hits + wrong)
	summary["acc"] = acc
	L.append("")
	L.append("Noten raak: %d van %d (%.0f%%)   gemist: %d   verkeerde toetsen: %d" % [hits, total, acc, missed, wrong])
	L.append("Nauwkeurigheid (raak / alle aanslagen): %.0f%%   langste reeks: %d" % [prec, best_streak])

	var tips := PackedStringArray()

	# Per hand en wit/zwart
	var by := {"h0": [0, 0], "h1": [0, 0], "w": [0, 0], "b": [0, 0]}
	for n in reached:
		var hk := "h%d" % n["hand"]
		var ck := "b" if PianoKeyboard.is_black(n["pitch"]) else "w"
		by[hk][1] += 1
		by[ck][1] += 1
		if n["state"] == NoteHighway.HIT:
			by[hk][0] += 1
			by[ck][0] += 1
	var pct := func(a: Array) -> float: return 100.0 * a[0] / maxf(1.0, a[1])
	var parts := PackedStringArray()
	if by["h0"][1] > 0:
		parts.append("linkerhand %.0f%%" % pct.call(by["h0"]))
	if by["h1"][1] > 0:
		parts.append("rechterhand %.0f%%" % pct.call(by["h1"]))
	if by["w"][1] > 0:
		parts.append("witte toetsen %.0f%%" % pct.call(by["w"]))
	if by["b"][1] > 0:
		parts.append("zwarte toetsen %.0f%%" % pct.call(by["b"]))
	L.append("Per onderdeel: " + ", ".join(parts))
	if by["h0"][1] > 0:
		summary["hands"][0] = pct.call(by["h0"])
	if by["h1"][1] > 0:
		summary["hands"][1] = pct.call(by["h1"])
	if by["h0"][1] >= 8 and by["h1"][1] >= 8:
		var dl: float = pct.call(by["h0"])
		var dr: float = pct.call(by["h1"])
		if absf(dl - dr) >= 15.0:
			var weak := "linkerhand" if dl < dr else "rechterhand"
			tips.append("De %s gaat minder goed (%.0f%% tegen %.0f%%). Oefen die hand apart met de knop Hand, in wachtmodus." % [weak, minf(dl, dr), maxf(dl, dr)])
	if by["b"][1] >= 6 and pct.call(by["b"]) < pct.call(by["w"]) - 15.0:
		tips.append("Zwarte toetsen (kruizen en mollen) gaan minder goed dan witte. Kijk vooraf welke voortekens het stuk heeft.")

	# Verwisselingen
	var conf := {}
	for w in wrong_events:
		if w[2] >= 0:
			var k := "%s in plaats van %s" % [MidiMonitor.note_name(w[1]), MidiMonitor.note_name(w[2])]
			conf[k] = int(conf.get(k, 0)) + 1
	var conf_keys := conf.keys()
	conf_keys.sort_custom(func(a, b): return conf[a] > conf[b])
	if not conf_keys.is_empty():
		var top := PackedStringArray()
		for k in conf_keys.slice(0, 3):
			top.append("%s (%dx)" % [k, conf[k]])
		L.append("Meest verwisseld: " + ", ".join(top))
		if conf[conf_keys[0]] >= 3:
			tips.append("Je speelt vaak %s. Oefen die plek langzaam." % conf_keys[0])
	if wrong > 0.15 * total:
		tips.append("Veel verkeerde toetsen (%d). Zet de wachtmodus aan en verlaag het tempo; snelheid komt later." % wrong)

	# Timing (alleen bij meespelen)
	var dts: Array[float] = []
	for n in reached:
		if n.has("dt"):
			dts.append(n["dt"])
	if dts.size() >= 5:
		var mean := 0.0
		for d in dts:
			mean += d
		mean /= dts.size()
		var sd := 0.0
		var perfect := 0
		for d in dts:
			sd += (d - mean) * (d - mean)
			if absf(d) <= PERFECT_MS:
				perfect += 1
		sd = sqrt(sd / dts.size())
		L.append("Timing: gemiddeld %+d ms (%s), spreiding %d ms, %.0f%% binnen %d ms" % [
			roundi(mean), "te laat" if mean > 0 else "te vroeg", roundi(sd), 100.0 * perfect / dts.size(), PERFECT_MS])
		summary["timing"] = "%+d ms gemiddeld, spreiding %d ms" % [roundi(mean), roundi(sd)]
		if mean > 60:
			tips.append("Je speelt gemiddeld %d ms te laat. Kijk iets verder vooruit naar de vallende noten." % roundi(mean))
		elif mean < -60:
			tips.append("Je speelt gemiddeld %d ms te vroeg. Wacht tot de balk de toets echt raakt." % roundi(-mean))
		if sd > 90:
			tips.append("Je timing is onregelmatig (spreiding %d ms). Probeer een lager tempo." % roundi(sd))

	# Loslaten van lange noten
	var helds: Array[float] = []
	for n in reached:
		if n.has("held"):
			helds.append(n["held"])
	if helds.size() >= 4:
		var m := 0.0
		for h in helds:
			m += h
		m /= helds.size()
		L.append("Lange noten aangehouden: gemiddeld %.0f%% van de lengte (%d noten)" % [m * 100.0, helds.size()])
		if m < 0.7:
			tips.append("Lange noten laat je te vroeg los (gemiddeld %.0f%% van de lengte). Houd ze aan tot de balk weg is." % (m * 100.0))

	# Aanslag (dynamiek)
	var ev: Array[float] = []
	var pv: Array[float] = []
	for n in reached:
		if n.has("pvel"):
			ev.append(float(n["vel"]))
			pv.append(float(n["pvel"]))
	if ev.size() >= 10:
		var me := _mean(ev)
		var mp := _mean(pv)
		var se := _sd(ev, me)
		L.append("Aanslag: gemiddeld %d (in het bestand %d)" % [roundi(mp), roundi(me)])
		if se > 8.0:
			var r := _corr(ev, pv)
			L.append("Dynamiek volgen (correlatie hard/zacht met het bestand): %.2f" % r)
			if r < 0.3:
				tips.append("Je volgt de dynamiek nog weinig: speel de lichte balken zachter en de felle harder.")
		if mp - me > 20:
			tips.append("Je speelt flink harder dan het stuk aangeeft.")
		elif me - mp > 20:
			tips.append("Je speelt flink zachter dan het stuk aangeeft.")

	# Pedaal
	if song and not _used_wait:
		var file_pedal: Array = []
		for p in song.pedal:
			if p[0] <= t:
				file_pedal.append(p)
		if not file_pedal.is_empty():
			var ok := 0
			for p in file_pedal:
				for u in pedal_user:
					if u[1] == p[1] and absf(u[0] - p[0]) <= 0.5 * speed:
						ok += 1
						break
			L.append("Pedaal: %d van %d wissels op tijd (binnen 0,5 s)" % [ok, file_pedal.size()])
			if ok < 0.6 * file_pedal.size():
				tips.append("Het pedaal wisselt in dit stuk %d keer; jij deed er %d op tijd. Til het pedaal op als een nieuw akkoord begint." % [file_pedal.size(), ok])
		elif pedal_user.size() >= 6:
			L.append("Pedaal: %d keer gebruikt; het bestand geeft geen pedaal aan" % (int(pedal_user.size() / 2.0)))
			tips.append("Dit bestand geeft geen pedaal aan, maar je gebruikte het vaak. Probeer het eens zonder voor een helderder geluid.")

	# Moeilijkste stukjes
	var sec := {}
	for n in reached:
		var s := floori((float(n["start"]) - float(notes[0]["start"])) / SECTION_LEN)
		if not sec.has(s):
			sec[s] = [0, 0]
		sec[s][1] += 1
		if n["state"] == NoteHighway.HIT:
			sec[s][0] += 1
	for w in wrong_events:
		var s := floori((float(w[0]) - float(notes[0]["start"])) / SECTION_LEN)
		if sec.has(s):
			sec[s][1] += 1
	var weak_secs: Array = []
	for s in sec.keys():
		if sec[s][1] >= 4:
			weak_secs.append([s, 100.0 * sec[s][0] / sec[s][1]])
	weak_secs.sort_custom(func(a, b): return a[1] < b[1])
	var hard := PackedStringArray()
	for w in weak_secs.slice(0, 2):
		if w[1] < 85.0:
			var from: float = float(notes[0]["start"]) + w[0] * SECTION_LEN
			hard.append("%s-%s (%.0f%%)" % [_mmss(from), _mmss(from + SECTION_LEN), w[1]])
	if not hard.is_empty():
		L.append("Moeilijkste stukjes: " + ", ".join(hard))
		summary["hardest"] = hard[0]
		tips.append("Oefen apart: %s. Spoel terug met de knop -5 s." % hard[0])

	if acc >= 95.0 and wrong <= 0.05 * total:
		if _used_wait:
			tips.append("Uitstekend! Zet de wachtmodus uit en speel mee in tempo.")
		elif speed < 1.0:
			tips.append("Uitstekend! Verhoog het tempo een stap.")
		else:
			tips.append("Uitstekend gespeeld op vol tempo!")
	L.append("")
	L.append("TIPS")
	if tips.is_empty():
		tips.append("Goed bezig. Speel het nog eens en kijk of je reeks langer wordt.")
	for tip in tips:
		L.append("- " + tip)
	summary["tips"] = Array(tips)
	return "\n".join(L)


static func _mean(a: Array[float]) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, a.size())


static func _sd(a: Array[float], m: float) -> float:
	var s := 0.0
	for v in a:
		s += (v - m) * (v - m)
	return sqrt(s / maxf(1.0, a.size()))


static func _corr(a: Array[float], b: Array[float]) -> float:
	var ma := _mean(a)
	var mb := _mean(b)
	var num := 0.0
	var da := 0.0
	var db := 0.0
	for i in a.size():
		num += (a[i] - ma) * (b[i] - mb)
		da += (a[i] - ma) * (a[i] - ma)
		db += (b[i] - mb) * (b[i] - mb)
	if da <= 0.0 or db <= 0.0:
		return 0.0
	return num / sqrt(da * db)
