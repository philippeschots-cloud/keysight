extends Node
## Zelftest zonder headset of piano: `godot --headless --path . -- --selftest`
## Controleert het MIDI-inlezen, de kalibratiewiskunde en de oefenlogica.

var failures := 0


func _ready() -> void:
	print("=== ZELFTEST ===")
	_test_songs()
	_test_calibration()
	_test_session_play()
	_test_session_wait()
	_test_session_hand()
	print("=== ZELFTEST KLAAR: %s ===" % ("OK" if failures == 0 else "%d FOUT(EN)" % failures))
	get_tree().quit(1 if failures > 0 else 0)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    ", what)
	else:
		failures += 1
		print("  FOUT  ", what)


func _test_songs() -> void:
	print("-- liedjes")
	var files := DirAccess.get_files_at("res://songs")
	_check(files.size() >= 4, "%d bestanden in res://songs" % files.size())
	for f in files:
		if f.get_extension() != "mid":
			continue
		var s := MidiSong.load_file("res://songs/" + f)
		var l := 0
		var r := 0
		var lo := 200
		var hi := 0
		for n in s.notes:
			if n["hand"] == 0:
				l += 1
			else:
				r += 1
			lo = mini(lo, n["pitch"])
			hi = maxi(hi, n["pitch"])
		print("  %-42s %4d noten  %5.1f s  L%d/R%d  %s-%s  pedaal %d  %s" % [
			s.title, s.notes.size(), s.duration, l, r, MidiMonitor.note_name(lo), MidiMonitor.note_name(hi), s.pedal.size(), s.hand_rule])
		_check(s.error == "" and s.notes.size() > 10 and s.duration > 5.0, "inlezen " + f)
		var sorted := true
		for i in range(1, s.notes.size()):
			if s.notes[i]["start"] < s.notes[i - 1]["start"]:
				sorted = false
		_check(sorted, "gesorteerd " + f)
	# Kapotte invoer mag niet crashen.
	var bad := MidiSong.new()
	bad.parse(PackedByteArray([1, 2, 3]))
	_check(bad.error != "", "kapot bestand geeft nette fout: " + bad.error)


## Maakt een klavier met bekende plek en schaal, simuleert drukpunten met
## ruis en een uitschieter, en kijkt of de fit de hoeken terugvindt.
func _test_calibration() -> void:
	print("-- kalibratie")
	var yaw := deg_to_rad(23.0)
	var scale := 0.985
	var xdir := Vector3(cos(yaw), 0, -sin(yaw))
	var zdir := xdir.cross(Vector3.UP).normalized()
	var left := Vector3(0.31, 0.72, -0.48)
	var w := PianoKeyboard.nominal_width()
	var right := left + xdir * w * scale
	var cal := AutoCalibrator.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var notes := [21, 108, 60, 40, 83, 66, 97]
	for note in notes:
		var kx := PianoKeyboard.key_center_x(note) * scale
		var depth := AutoCalibrator.DEPTH_BLACK if PianoKeyboard.is_black(note) else AutoCalibrator.DEPTH_WHITE
		depth += rng.randf_range(-0.01, 0.01)   # niet precies op dezelfde diepte gedrukt
		var p := left + xdir * kx - zdir * depth + Vector3.UP * (PianoKeyboard.key_top_y(note) - AutoCalibrator.BALL_BELOW_TOP)
		p += Vector3(rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002))
		cal.samples.append({"note": note, "p": p, "msec": 0})
	# Uitschieter (bv. andere hand gekozen): 6 cm ernaast.
	cal.samples.append({"note": 72, "p": left + xdir * PianoKeyboard.key_center_x(72) + Vector3(0, 0.06, 0.04), "msec": 0})
	var f := cal.fit()
	print("  fit: ok=%s n=%d weggelaten=%d schaal=%.4f breedte=%.1f cm rms=%.1f mm %s" % [
		f.get("ok"), f.get("n", 0), f.get("dropped", 0), f.get("scale", 0), f.get("width", 0) * 100, f.get("rms", 0) * 1000, f.get("why", "")])
	_check(f.get("ok", false), "fit gelukt")
	if f.get("ok", false):
		var el: float = (f["left"] as Vector3).distance_to(left)
		var er: float = (f["right"] as Vector3).distance_to(right)
		print("  hoekfout links %.1f mm, rechts %.1f mm" % [el * 1000, er * 1000])
		_check(el < 0.012 and er < 0.012, "hoeken binnen 12 mm")
		_check(f["dropped"] >= 1, "uitschieter verwijderd")
		_check(absf(f["scale"] - scale) < 0.01, "schaal teruggevonden")
		# Plaatsen op een echt klavier-node en een toets terugrekenen.
		var kb := PianoKeyboard.new()
		add_child(kb)
		kb.place_by_corners(f["left"], f["right"], Vector3.UP, true)
		var c4_world := kb.global_transform * Vector3(kb.local_x(60), 0, 0)
		var c4_true := left + xdir * PianoKeyboard.key_center_x(60) * scale
		print("  C4-midden fout %.1f mm" % (c4_world.distance_to(c4_true) * 1000))
		_check(c4_world.distance_to(c4_true) < 0.012, "C4 ligt op de goede plek")
		kb.queue_free()
	# Te dicht bij elkaar -> geen fit.
	var cal2 := AutoCalibrator.new()
	cal2.samples.append({"note": 60, "p": Vector3(0, 0.7, 0), "msec": 0})
	cal2.samples.append({"note": 62, "p": Vector3(0.0235, 0.7, 0), "msec": 0})
	var f2 := cal2.fit()
	_check(not f2.get("ok", true), "te dicht bij elkaar wordt geweigerd: " + f2.get("why", ""))
	# Verkeerde schaal (bv. step 1-fout: dubbele trekker) -> geweigerd.
	var cal3 := AutoCalibrator.new()
	cal3.samples.append({"note": 21, "p": Vector3(0, 0.7, 0), "msec": 0})
	cal3.samples.append({"note": 108, "p": Vector3(0.9, 0.7, 0), "msec": 0})
	var f3 := cal3.fit()
	_check(not f3.get("ok", true), "verkeerde breedte wordt geweigerd: " + f3.get("why", ""))


func _load_session(file: String) -> PracticeSession:
	var s := PracticeSession.new()
	s.load_song(MidiSong.load_file("res://songs/" + file))
	return s


## Speelt alle noten met ruis in de timing; 3 gemist, 2 fout.
func _test_session_play() -> void:
	print("-- meespelen (Ode to Joy, 80%)")
	var s := _load_session("03 Ode to Joy (Beethoven).mid")
	s.set_wait_mode(false)
	s.speed = 0.8
	s.playing = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var dt := 1.0 / 72.0
	var queue: Array = []   # [song_t, pitch, vel]
	var skip := [10, 40, 70]
	for i in s.notes.size():
		if i in skip:
			continue
		var n: Dictionary = s.notes[i]
		var off := rng.randfn(0.035, 0.03) * s.speed   # iets te laat
		queue.append([n["start"] + off, n["pitch"], clampi(n["vel"] + rng.randi_range(-10, 10), 1, 127), n["end"] + off * 0.7])
	queue.sort_custom(func(a, b): return a[0] < b[0])
	var qi := 0
	var offs: Array = []
	var wrong_sent := 0
	var guard := 0
	while not s.done and guard < 200000:
		guard += 1
		s.update(dt)
		while qi < queue.size() and queue[qi][0] <= s.t:
			var q: Array = queue[qi]
			s.note_on(q[1], q[2])
			offs.append([q[3], q[1]])
			if qi == 30 or qi == 60:
				s.note_on(q[1] + 1, 60)   # verkeerde toets ernaast
				wrong_sent += 1
			qi += 1
		for o in offs.duplicate():
			if o[0] <= s.t:
				s.note_off(o[1])
				offs.erase(o)
	print("  raak %d  gemist %d  fout %d  (noten %d)" % [s.hits, s.missed, s.wrong, s.notes.size()])
	_check(s.done, "lied eindigt")
	_check(s.missed == 3, "3 gemist gedetecteerd")
	_check(s.wrong == wrong_sent, "%d fout gedetecteerd" % wrong_sent)
	_check(s.hits == s.notes.size() - 3, "rest raak")
	var rep := s.build_report()
	print("  ---\n  " + rep.replace("\n", "\n  "))
	_check(rep.contains("Timing: gemiddeld +"), "rapport ziet te laat spelen")


## Wachtmodus: de klok moet stilstaan tot de goede toetsen zijn ingedrukt.
func _test_session_wait() -> void:
	print("-- wachtmodus (Twinkle)")
	var s := _load_session("01 Twinkle Twinkle Little Star (traditional).mid")
	s.set_wait_mode(true)
	s.speed = 1.0
	# Klok start pas bij de eerste juiste toets.
	var r0 := s.note_on(s.notes[0]["pitch"] + 1, 60)
	_check(not s.playing and r0["kind"] == "free", "verkeerde toets start de klok niet")
	var r1 := s.note_on(s.notes[0]["pitch"], 60)
	_check(s.playing and r1["kind"] == "hit", "juiste eerste toets start de klok")
	# Rest van het eerste akkoord (bv. de linkerhand) ook spelen.
	for k in s.groups[0]["idx"]:
		if s.notes[k]["state"] == NoteHighway.PENDING:
			s.note_on(s.notes[k]["pitch"], 60)
	var dt := 1.0 / 72.0
	for i in 400:
		s.update(dt)
	var g1: float = s.groups[1]["time"]
	_check(absf(s.t - g1) < 0.001 and s.waiting, "klok wacht op akkoord 2 (t=%.2f, akkoord %.2f)" % [s.t, g1])
	var r2 := s.note_on(40, 60)
	_check(r2["kind"] == "wrong" or r2["kind"] == "other", "andere toets telt als fout")
	# Speel alle akkoorden.
	var guard := 0
	while not s.done and guard < 100000:
		guard += 1
		if s.waiting:
			for k in s.groups[s._gi]["idx"]:
				if s.notes[k]["state"] == NoteHighway.PENDING:
					s.note_on(s.notes[k]["pitch"], 70)
		s.update(dt)
	_check(s.done and s.missed == 0 and s.hits == s.notes.size(), "alle %d noten raak in wachtmodus" % s.notes.size())


func _test_session_hand() -> void:
	print("-- per hand (Frere Jacques, alleen rechts)")
	var s := _load_session("02 Frere Jacques - round (traditional).mid")
	s.set_wait_mode(true)
	s.set_practice_hand(1)
	var right := 0
	for n in s.notes:
		if n["hand"] == 1:
			right += 1
	var guard := 0
	s.playing = true
	while not s.done and guard < 200000:
		guard += 1
		if s.waiting:
			for k in s.groups[s._gi]["idx"]:
				if s.notes[k]["state"] == NoteHighway.PENDING:
					s.note_on(s.notes[k]["pitch"], 70)
		s.update(1.0 / 72.0)
	_check(s.done and s.hits == right, "alleen rechterhand-noten nodig (%d van %d)" % [s.hits, s.notes.size()])
