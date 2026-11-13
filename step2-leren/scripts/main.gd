extends Node3D
## KeySight: leer piano spelen op je eigen piano, met de Steam Frame.
##
## Vallende noten op de echte toetsen (passthrough), wachtmodus, tempo,
## oefenen per hand, MIDI-bestanden, feedback per noot, een resultatenkaart
## en automatische kalibratie door echte toetsen in te drukken.
##
## Bediening
##   Controller: wijs naar het scherm en druk op de trekker. Stick = scrollen.
##     A/X = start/pauze, B/Y = opnieuw.
##   Zonder controller (handen op de piano):
##     middelste pedaal (sostenuto)     = start / pauze / opnieuw
##     laagste A (A0) / laagste B (B0)  = vorig / volgend lied (in het menu)
##     In de wachtmodus start de klok bij de eerste juiste toets.
##   Pc: muis op het scherm, spatie start/pauze, links/rechts lied, op/neer
##     tempo, W wacht, H hand, R opnieuw, B -5 s, K kalibreren, P passthrough.

const SONG_DIRS := ["res://songs"]
const CALIB_FILE := "user://kalibratie.cfg"
const SETTINGS_FILE := "user://instellingen.cfg"
const SCORES_FILE := "user://scores.cfg"
const DIAG_FILE := "user://keysight_diagnose.txt"
const KEY_ALPHAS := [0.10, 0.35, 1.0]
const KEY_ALPHA_NAMES := ["dun", "zwak", "vol"]
const COLOR_OK := Color(0.24, 0.86, 0.59, 0.95)
const COLOR_BAD := Color(1.0, 0.25, 0.25, 0.95)
const SCREEN_W := 0.90
const SCREEN_H := 0.36

var xr: XRInterface
var xr_active := false
var passthrough_on := false

var origin: XROrigin3D
var camera: XRCamera3D
var hands := {}            # &"left"/&"right" -> XRController3D
var rays := {}             # hand -> MeshInstance3D
var cursor: MeshInstance3D
var keyboard: PianoKeyboard
var highway: NoteHighway
var screen: VrScreen
var ui: AppUI
var midi: MidiMonitor
var session := PracticeSession.new()
var calibrator := AutoCalibrator.new()
var world_env: WorldEnvironment

var songs: Array[String] = []
var song_meta: Array = []        # [{title, dur, notes, error}]
var song_index := 0
var key_alpha_i := 0
var ui_state := "menu"
var calibrating := false
var fine_tune := false
var _calib_base := Transform3D.IDENTITY
var _calib_before := Transform3D.IDENTITY
var _offset := Vector4.ZERO      # x, y (hoogte), z, yaw (graden)
var _has_calib := false
var _placed := false
var _start_msec := 0
var _hint_notes := {}
var _trigger_msec := {}
var _hand_hist := {}             # hand -> [[msec, pos], ...]
var _pointer_hand: StringName = &""
var _pointer_px := Vector2(-1, -1)
var _sostenuto_down := false
var _diag_text := ""
var _calib_msg := ""
var _hud_timer := 0.0
var _demo := false
var _song_info := ""


func _ready() -> void:
	_start_msec = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	if "--selftest" in args:
		set_process(false)
		var st: Node = load("res://scripts/selftest.gd").new()
		add_child(st)
		return
	_setup_xr()
	_build_scene()
	midi = MidiMonitor.new()
	midi.name = "MidiMonitor"
	midi.note_on.connect(_on_note_on)
	midi.note_off.connect(_on_note_off)
	midi.control_change.connect(_on_cc)
	midi.raw_event.connect(_on_raw_midi)
	midi.devices_changed.connect(func(_d: PackedStringArray) -> void: _refresh_diagnostics())
	add_child(midi)
	session.finished.connect(_on_finished)
	_scan_songs()
	_load_settings()
	_load_calibration()
	# Testopties: -- --song <nr> --nowait --state <naam>
	var si := args.find("--song")
	if si >= 0 and si + 1 < args.size():
		song_index = int(args[si + 1]) - 1
	if "--nowait" in args:
		session.set_wait_mode(false)
	_select_song(song_index)
	_refresh_options()
	_refresh_diagnostics()
	_save_diagnostics()
	_set_state("menu")
	if "--demo" in args:
		_demo = true
		_log("[demo] speelt het lied automatisch, met kleine foutjes")
		_start_lesson()
	var st_i := args.find("--state")
	if st_i >= 0 and st_i + 1 < args.size():
		_test_state(args[st_i + 1])
	var shot := args.find("--shot")
	if shot >= 0 and shot + 2 < args.size():
		# --shot <pad.png> <seconden>: schermafbeelding maken en stoppen (voor tests).
		var path := args[shot + 1]
		get_tree().create_timer(float(args[shot + 2])).timeout.connect(func() -> void:
			get_viewport().get_texture().get_image().save_png(path)
			_log("[shot] " + path)
			get_tree().quit())


# ---------------------------------------------------------------- XR / scene

func _setup_xr() -> void:
	xr = XRServer.find_interface("OpenXR")
	if xr and xr.is_initialized():
		xr_active = true
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_set_passthrough(true)
	else:
		print("[KeySight] Geen OpenXR, desktopmodus.")


func _set_passthrough(on: bool) -> void:
	if not xr_active:
		passthrough_on = false
		return
	var modes: Array = xr.get_supported_environment_blend_modes()
	if on and XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
		xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		get_viewport().transparent_bg = true
		passthrough_on = true
	else:
		xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		get_viewport().transparent_bg = false
		passthrough_on = false
	if world_env:
		world_env.environment.background_mode = Environment.BG_CLEAR_COLOR if passthrough_on else Environment.BG_COLOR


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR if passthrough_on else Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.8)
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))

	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	origin.add_child(camera)
	for h in [&"left", &"right"]:
		var c := XRController3D.new()
		c.tracker = StringName(String(h) + "_hand")
		c.pose = &"aim"
		origin.add_child(c)
		c.button_pressed.connect(_on_button.bind(h))
		_add_pointer(c, h)
		hands[h] = c
		_hand_hist[h] = []
	cursor = _sphere(0.007, Color(0.24, 0.86, 0.59))
	cursor.visible = false
	add_child(cursor)

	keyboard = PianoKeyboard.new()
	keyboard.name = "PianoKeyboard"
	add_child(keyboard)
	keyboard.base_alpha = KEY_ALPHAS[key_alpha_i]
	highway = NoteHighway.new(keyboard)
	highway.name = "NoteHighway"
	keyboard.add_child(highway)

	# Scherm boven de muziekstandaard, licht naar de ogen gekanteld.
	screen = VrScreen.new(SCREEN_W, SCREEN_H)
	screen.name = "Screen"
	screen.position = Vector3(0, NoteHighway.MAX_HEIGHT + 0.03 + SCREEN_H / 2.0, -0.24)
	screen.rotation_degrees = Vector3(12, 0, 0)
	keyboard.add_child(screen)
	ui = AppUI.new()
	screen.add_ui(ui)
	ui.action.connect(_on_ui)

	if not xr_active:
		keyboard.position = Vector3(0, 0.75, -0.55)
		camera.position = Vector3(0, 1.32, 0.12)
		camera.look_at(Vector3(0, 1.08, -0.75))
		camera.fov = 78
		_placed = true


func _sphere(r: float, color: Color) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.no_depth_test = true
	m.render_priority = 8
	s.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = s
	return mi


func _add_pointer(ctrl: XRController3D, hand: StringName) -> void:
	# Geel bolletje = meetpunt bij kalibratie.
	ctrl.add_child(_sphere(0.006, Color(1, 0.9, 0.1)))
	var box := BoxMesh.new()
	box.size = Vector3(0.0018, 0.0018, 1.0)
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = Color(0.24, 0.86, 0.59, 0.55)
	box.material = rm
	var ray := MeshInstance3D.new()
	ray.mesh = box
	ray.visible = false
	ctrl.add_child(ray)
	rays[hand] = ray


func _place_in_front_of_head() -> void:
	var head := camera.global_transform
	var fwd := -head.basis.z
	fwd.y = 0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()
	var pos := head.origin + fwd * 0.45 + Vector3.DOWN * 0.45
	keyboard.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	_placed = true


# ---------------------------------------------------------------- liedjes

func _scan_songs() -> void:
	songs.clear()
	song_meta.clear()
	var dirs: Array[String] = []
	dirs.append_array(SONG_DIRS)
	dirs.append(OS.get_executable_path().get_base_dir().path_join("songs"))
	dirs.append("user://songs")
	DirAccess.make_dir_recursive_absolute("user://songs")
	for d in dirs:
		if not DirAccess.dir_exists_absolute(d):
			continue
		var sorted := Array(DirAccess.get_files_at(d))
		sorted.sort()
		for f in sorted:
			var ext: String = f.get_extension().to_lower()
			if ext == "mid" or ext == "midi":
				var path := d.path_join(f)
				var s := MidiSong.load_file(path)
				songs.append(path)
				song_meta.append({"title": s.title, "dur": s.duration, "notes": s.notes.size(), "error": s.error})
	_log("[liedjes] %d gevonden; eigen .mid in %s" % [songs.size(), OS.get_executable_path().get_base_dir().path_join("songs")])
	_refresh_song_list()


func _refresh_song_list() -> void:
	var scores := ConfigFile.new()
	scores.load(SCORES_FILE)
	var list := []
	for i in songs.size():
		var m: Dictionary = song_meta[i]
		var best: float = scores.get_value("beste", songs[i].get_file(), -1.0)
		list.append({"title": m["title"], "dur": PracticeSession._mmss(m["dur"]),
			"best": ("%d%%" % roundi(best)) if best >= 0 else ""})
	ui.set_songs(list)


func _select_song(i: int) -> void:
	if songs.is_empty():
		ui.set_selected(-1, "Geen liedjes gevonden", "Zet .mid-bestanden in ~/pianovr/songs")
		return
	song_index = posmod(i, songs.size())
	var s := MidiSong.load_file(songs[song_index])
	if s.error != "":
		_log("[lied] %s: %s" % [songs[song_index].get_file(), s.error])
	session.load_song(s)
	highway.set_notes(session.notes)
	keyboard.release_all()
	var left := 0
	for n in session.notes:
		if n["hand"] == 0:
			left += 1
	var info := "%s  ·  %d noten  ·  links %d / rechts %d" % [
		PracticeSession._mmss(s.duration), session.notes.size(), left, session.notes.size() - left]
	if s.pedal.size() > 0:
		info += "  ·  met pedaal"
	if s.error != "":
		info = "Kan niet lezen: " + s.error
	_song_info = info
	ui.set_selected(song_index, s.title, info)
	_log("[lied] %s: %d noten, %s, handen %s, pedaal %d wissels" % [
		s.title, session.notes.size(), PracticeSession._mmss(s.duration), s.hand_rule, s.pedal.size()])
	_save_settings()


# ---------------------------------------------------------------- toestanden

func _set_state(st: String) -> void:
	ui_state = st
	ui.show_state(st)
	highway.visible = st == "lesson"


func _start_lesson() -> void:
	if session.notes.is_empty():
		return
	session.restart()
	keyboard.release_all()
	_set_state("lesson")
	# In de wachtmodus start de klok bij de eerste juiste toets.
	session.playing = not session.wait_mode
	_update_hud(true)


func _to_menu() -> void:
	if ui_state == "lesson":
		_maybe_report_partial()
	session.playing = false
	keyboard.release_all()
	keyboard.clear_hints()
	_set_state("menu")


func _toggle_play() -> void:
	match ui_state:
		"menu":
			_start_lesson()
		"results":
			_start_lesson()
		"lesson":
			if session.done:
				_start_lesson()
			else:
				session.toggle_play()
	_update_hud(true)


func _maybe_report_partial() -> void:
	if session.done or session.hits + session.wrong + session.missed < 10:
		return
	var rep := session.build_report()
	_save_report(rep, true)


# ---------------------------------------------------------------- invoer

func _on_note_on(note: int, vel: int, _ch: int) -> void:
	if calibrating:
		keyboard.set_key(note, true, vel)
		_calibration_sample(note)
		return
	if ui_state == "menu":
		# Liedkeuze met de laagste toetsen.
		if note == 21:
			_select_song(song_index - 1)
			keyboard.flash(note, COLOR_OK)
			return
		if note == 23:
			_select_song(song_index + 1)
			keyboard.flash(note, COLOR_OK)
			return
		keyboard.set_key(note, true, vel)
		return
	if ui_state != "lesson":
		keyboard.set_key(note, true, vel)
		return
	var r := session.note_on(note, vel)
	match r["kind"]:
		"hit":
			keyboard.set_key(note, true, vel, COLOR_OK)
		"wrong":
			keyboard.set_key(note, true, vel, COLOR_BAD)
		_:
			keyboard.set_key(note, true, vel)


func _on_note_off(note: int, _ch: int) -> void:
	keyboard.set_key(note, false)
	session.note_off(note)


func _on_cc(cc: int, value: int, _ch: int) -> void:
	if cc == 64:
		session.pedal(value)
	elif cc == 66:
		var down := value >= 64
		if down and not _sostenuto_down and not calibrating:
			_toggle_play()
		_sostenuto_down = down


func _on_button(button: StringName, hand: StringName) -> void:
	var b := String(button)
	if b == "trigger_click":
		var now := Time.get_ticks_msec()
		if now - int(_trigger_msec.get(hand, 0)) < 400:
			return   # dubbele trekker-events negeren
		_trigger_msec[hand] = now
		var c: XRController3D = hands[hand]
		var hit := screen.ray_hit(c.global_position, -c.global_basis.z)
		if not hit.is_empty() and screen.is_over_ui(hit["px"]):
			_pointer_hand = hand
			screen.click(hit["px"])
		elif calibrating:
			_finish_calibration()
	elif b == "ax_button":
		_toggle_play()
	elif b == "by_button":
		if ui_state == "lesson" or ui_state == "results":
			_start_lesson()


func _unhandled_input(event: InputEvent) -> void:
	if not xr_active:
		var mm := event as InputEventMouseMotion
		if mm:
			var hit := screen.ray_hit(camera.project_ray_origin(mm.position), camera.project_ray_normal(mm.position))
			if hit.is_empty():
				screen.pointer_leave()
			else:
				screen.pointer_move(hit["px"])
			return
		var mb := event as InputEventMouseButton
		if mb:
			var hit := screen.ray_hit(camera.project_ray_origin(mb.position), camera.project_ray_normal(mb.position))
			if not hit.is_empty():
				screen.pointer_button(hit["px"], mb.pressed, mb.button_index)
			return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if fine_tune and k.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		return   # pijltjes zijn dan voor het bijstellen
	match k.keycode:
		KEY_SPACE: _toggle_play()
		KEY_LEFT: _on_ui("song", song_index - 1)
		KEY_RIGHT: _on_ui("song", song_index + 1)
		KEY_UP: _on_ui("faster", null)
		KEY_DOWN: _on_ui("slower", null)
		KEY_W: _on_ui("mode", not session.wait_mode)
		KEY_H: _on_ui("hand", [-1, 1, 0][([-1, 1, 0].find(session.practice_hand) + 1) % 3])
		KEY_R: _on_ui("restart", null)
		KEY_B: session.seek(-5.0)
		KEY_K: _on_ui("calib", null)
		KEY_P: _on_ui("pass", null)
		KEY_ESCAPE: _on_ui("menu", null)


func _on_ui(id: String, arg: Variant) -> void:
	match id:
		"song": _select_song(int(arg))
		"start": _start_lesson()
		"mode": session.set_wait_mode(bool(arg))
		"hand": session.set_practice_hand(int(arg))
		"slower": session.speed -= 0.1
		"faster": session.speed += 0.1
		"tempo_reset": session.speed = 1.0
		"keys":
			key_alpha_i = (key_alpha_i + 1) % KEY_ALPHAS.size()
			keyboard.base_alpha = KEY_ALPHAS[key_alpha_i]
		"pass": _set_passthrough(not passthrough_on)
		"diag":
			_refresh_diagnostics()
			_set_state("diag")
		"back": _set_state("menu")
		"calib": _start_calibration()
		"calib_done":
			if fine_tune:
				_finish_tune()
			else:
				_finish_calibration()
		"calib_cancel": _cancel_calibration()
		"tune": _start_tune()
		"pause": _toggle_play()
		"restart": _start_lesson()
		"menu": _to_menu()
		"next":
			_select_song(song_index + 1)
			_set_state("menu")
	_save_settings()
	_refresh_options()


func _refresh_options() -> void:
	ui.set_options({"wait": session.wait_mode, "hand": session.practice_hand, "speed": session.speed,
		"keys": KEY_ALPHA_NAMES[key_alpha_i], "passthrough": passthrough_on})


# ---------------------------------------------------------------- kalibratie

const CALIB_STEPS := "Houd een controller vast en druk met het gele bolletje echte toetsen in, één per keer, vlak bij de voorrand.\nBegin helemaal links, dan helemaal rechts, dan een paar in het midden. Druk daarna op Klaar."


func _start_calibration() -> void:
	calibrating = true
	fine_tune = false
	session.playing = false
	_calib_before = keyboard.global_transform
	calibrator.reset()
	keyboard.base_alpha = 1.0
	_set_state("calib")
	ui.set_calib("Kalibreren", CALIB_STEPS, calibrator.status_text(), 0, false)
	_log("[kalibratie] gestart")


func _calibration_sample(note: int) -> void:
	var p := _pressing_point(note)
	if p == Vector3.ZERO:
		_log("[kalibratie] %s genegeerd: geen controller gevolgd" % MidiMonitor.note_name(note))
		ui.set_calib("Kalibreren", CALIB_STEPS, "Geen controller gezien. Houd een controller vast (lampje aan) en druk opnieuw.",
			calibrator.samples.size(), calibrator.last_fit.get("ok", false))
		return
	var msg := calibrator.add_sample(note, p)
	if msg == "":
		return
	_log("[kalibratie] %s @ %s: %s" % [MidiMonitor.note_name(note), p, msg])
	var f := calibrator.last_fit
	ui.set_calib("Kalibreren", CALIB_STEPS, msg, calibrator.samples.size(), f.get("ok", false))
	if f.get("ok", false):
		# Live voorbeeld: klavier springt meteen naar de nieuwe plek.
		keyboard.place_by_corners(f["left"], f["right"], Vector3.UP, true)
		_placed = true


## Welke controller drukte de toets in? Met een fit: de controller die het
## dichtst bij de voorspelde plek is. Anders: de controller die net het
## snelst omlaag bewoog.
func _pressing_point(note: int) -> Vector3:
	var f := calibrator.last_fit
	# Alleen controllers die echt gevolgd worden (anders is de positie 0,0,0).
	var tracked: Array = []
	for h in hands.keys():
		var c: XRController3D = hands[h]
		if c.get_has_tracking_data() and c.global_position != Vector3.ZERO:
			tracked.append(h)
	if tracked.is_empty():
		return Vector3.ZERO
	var best: StringName = tracked[0]
	if f.get("ok", false):
		var pred := calibrator.predict(note)
		var d_best := INF
		for h in tracked:
			var d: float = hands[h].global_position.distance_to(pred)
			if d < d_best:
				d_best = d
				best = h
	else:
		var best_v := -INF
		for h in tracked:
			var hist: Array = _hand_hist[h]
			if hist.size() < 2:
				continue
			var drop: float = hist[0][1].y - hist[-1][1].y
			if drop > best_v:
				best_v = drop
				best = h
	return hands[best].global_position


func _finish_calibration() -> void:
	calibrating = false
	keyboard.base_alpha = KEY_ALPHAS[key_alpha_i]
	var f := calibrator.last_fit
	if f.get("ok", false):
		keyboard.place_by_corners(f["left"], f["right"], Vector3.UP, true)
		_calib_base = keyboard.global_transform
		_offset = Vector4.ZERO
		_has_calib = true
		_placed = true
		_save_calibration()
		_calib_msg = "Gekalibreerd met %d punten: breedte %.1f cm (standaard %.1f), passing %.1f mm." % [
			f["n"], f["width"] * 100.0, PianoKeyboard.nominal_width() * 100.0, f["rms"] * 1000.0]
		_log("[kalibratie] " + _calib_msg)
		_set_state("menu")
	else:
		calibrating = true
		keyboard.base_alpha = 1.0
		ui.set_calib("Kalibreren", CALIB_STEPS, "Nog niet goed genoeg: " + str(f.get("why", "druk nog een paar toetsen.")),
			calibrator.samples.size(), false)


func _cancel_calibration() -> void:
	calibrating = false
	fine_tune = false
	keyboard.base_alpha = KEY_ALPHAS[key_alpha_i]
	keyboard.global_transform = _calib_before
	_set_state("menu")


func _start_tune() -> void:
	fine_tune = true
	calibrating = false
	_calib_before = keyboard.global_transform
	if not _has_calib:
		_calib_base = keyboard.global_transform
		_offset = Vector4.ZERO
		_has_calib = true
	_set_state("calib")
	_update_tune_text()


func _update_tune_text() -> void:
	ui.set_calib("Bijstellen",
		"Rechter stick: naar links/rechts en naar voren/achteren.\nLinker stick: omhoog/omlaag en draaien.\nLeg het klavier precies over de echte toetsen en druk op Klaar.",
		"Verschuiving %+.1f cm opzij, %+.1f cm diepte, %+.1f cm hoogte, %+.1f graden" % [
			_offset.x * 100, _offset.z * 100, _offset.y * 100, _offset.w], -1, true)


func _finish_tune() -> void:
	fine_tune = false
	_save_calibration()
	_set_state("menu")


func _apply_calibration() -> void:
	if not _has_calib:
		return
	var local := Transform3D(Basis(Vector3.UP, deg_to_rad(_offset.w)), Vector3(_offset.x, _offset.y, _offset.z))
	keyboard.global_transform = _calib_base * local


func _fine_tune(delta: float) -> void:
	var r := Vector2.ZERO
	var l := Vector2.ZERO
	if xr_active:
		r = hands[&"right"].get_vector2("primary")
		l = hands[&"left"].get_vector2("primary")
	else:
		r = Vector2(Input.get_axis("ui_left", "ui_right"), Input.get_axis("ui_down", "ui_up"))
	r = r if r.length() > 0.2 else Vector2.ZERO
	l = l if l.length() > 0.2 else Vector2.ZERO
	if r == Vector2.ZERO and l == Vector2.ZERO:
		return
	_offset.x += r.x * 0.02 * delta
	_offset.z -= r.y * 0.02 * delta
	_offset.y += l.y * 0.01 * delta
	_offset.w -= l.x * 2.0 * delta
	_apply_calibration()
	_update_tune_text()


func _save_calibration() -> void:
	if not _has_calib:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("klavier", "basis", _calib_base)
	cfg.set_value("klavier", "bijstelling", _offset)
	cfg.save(CALIB_FILE)


func _load_calibration() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CALIB_FILE) != OK:
		_calib_msg = "Nog niet gekalibreerd"
		return
	_calib_base = cfg.get_value("klavier", "basis", Transform3D.IDENTITY)
	_offset = cfg.get_value("klavier", "bijstelling", Vector4.ZERO)
	_has_calib = true
	if xr_active:
		_apply_calibration()
		_placed = true
	_calib_msg = "Kalibratie hersteld"


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if xr_active and not _placed and Time.get_ticks_msec() - _start_msec > 1500:
		_place_in_front_of_head()
	_track_hands()
	_update_pointer(delta)
	if fine_tune:
		_fine_tune(delta)
	if _demo:
		_demo_step()
	if ui_state == "lesson":
		session.update(delta)
		var hints := highway.update_view(session.t, session.cursor())
		for n in _hint_notes.keys():
			if not hints.has(n):
				keyboard.set_hint(n, Color.WHITE, 0.0)
		for n in hints.keys():
			keyboard.set_hint(n, hints[n][0], hints[n][1])
		_hint_notes = hints
		_hud_timer -= delta
		if _hud_timer <= 0.0:
			_update_hud()
	elif not _hint_notes.is_empty():
		keyboard.clear_hints()
		_hint_notes = {}
		highway.clear()


func _track_hands() -> void:
	var now := Time.get_ticks_msec()
	for h in hands.keys():
		var hist: Array = _hand_hist[h]
		hist.append([now, hands[h].global_position])
		while hist.size() > 2 and now - hist[0][0] > 200:
			hist.pop_front()


## Straal + cursor tekenen en de muis in het scherm bewegen.
func _update_pointer(delta: float) -> void:
	if not xr_active:
		return
	var active: StringName = &""
	var active_hit := {}
	for h in [&"right", &"left"]:
		var c: XRController3D = hands[h]
		var ray: MeshInstance3D = rays[h]
		var hit := {}
		if c.get_has_tracking_data():
			hit = screen.ray_hit(c.global_position, -c.global_basis.z)
		ray.visible = not hit.is_empty()
		if hit.is_empty():
			continue
		var dist := c.global_position.distance_to(hit["point"])
		ray.scale = Vector3(1, 1, dist)
		ray.position = Vector3(0, 0, -dist / 2.0)
		if active == &"" or h == _pointer_hand:
			active = h
			active_hit = hit
	if active == &"":
		cursor.visible = false
		screen.pointer_leave()
		return
	cursor.visible = true
	cursor.global_position = active_hit["point"]
	screen.pointer_move(active_hit["px"])
	# Stick = lijst scrollen.
	var stick: Vector2 = hands[active].get_vector2("primary")
	if absf(stick.y) > 0.25 and ui_state == "menu":
		ui.scroll_songs(-stick.y * 900.0 * delta)


func _update_hud(force := false) -> void:
	_hud_timer = 0.1
	var s := session
	var first: float = s.notes[0]["start"] if not s.notes.is_empty() else 0.0
	var dur := s.song.duration if s.song else 1.0
	var counted := s.hits + s.missed + s.wrong
	var fb := s.last_feedback
	var col := AppUI.MUTED
	if s.waiting:
		var names := PackedStringArray()
		if s._gi < s.groups.size():
			for k in s.groups[s._gi]["idx"]:
				if s.notes[k]["state"] == NoteHighway.PENDING:
					names.append(MidiMonitor.note_name(s.notes[k]["pitch"]))
		fb = "Wacht op jou: " + " ".join(names)
		col = AppUI.AMBER
	elif not s.playing and not s.done:
		fb = "Speel de eerste noot om te beginnen" if s.wait_mode and counted == 0 else "Gepauzeerd: middelste pedaal of Verder"
	elif fb.begins_with("Perfect") or fb.begins_with("Raak"):
		col = AppUI.ACCENT
	elif fb.begins_with("Fout"):
		col = AppUI.BAD
	elif fb.begins_with("Gemist"):
		col = AppUI.AMBER
	ui.update_hud({
		"title": s.song.title if s.song else "-",
		"sub": "%s / %s  ·  tempo %d%%  ·  %s  ·  %s" % [
			PracticeSession._mmss(maxf(0.0, s.t - first)),
			PracticeSession._mmss(dur - first), roundi(s.speed * 100),
			"wachten" if s.wait_mode else "meespelen",
			{-1: "beide handen", 0: "linkerhand", 1: "rechterhand"}[s.practice_hand]],
		"progress": clampf((s.t - first) / maxf(0.1, dur - first), 0.0, 1.0),
		"acc": ("%d%%" % roundi(100.0 * s.hits / counted)) if counted > 0 else "-",
		"feedback": fb,
		"feedback_color": col,
		"playing": s.playing,
	})


# ---------------------------------------------------------------- rapport

func _on_finished(rep: String) -> void:
	print("\n[RAPPORT]\n", rep, "\n")
	_save_report(rep, false)
	# Beste score bewaren.
	var acc: float = session.summary.get("acc", 0.0)
	var scores := ConfigFile.new()
	scores.load(SCORES_FILE)
	var key := songs[song_index].get_file()
	if acc > float(scores.get_value("beste", key, -1.0)):
		scores.set_value("beste", key, acc)
		scores.save(SCORES_FILE)
		_refresh_song_list()
		ui.set_selected(song_index, session.song.title, _song_info)
	ui.show_results(session.summary)
	keyboard.clear_hints()
	_set_state("results")


func _save_report(rep: String, partial: bool) -> void:
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "-").replace("T", "_")
	var fname := "%s_%s%s.txt" % [stamp, session.song.title.validate_filename() if session.song else "lied", "_tussentijds" if partial else ""]
	for dir in ["user://rapporten", OS.get_executable_path().get_base_dir().path_join("rapporten")]:
		DirAccess.make_dir_recursive_absolute(dir)
		var f := FileAccess.open(dir.path_join(fname), FileAccess.WRITE)
		if f:
			f.store_string(rep + "\n")
			f.close()
			_log("[rapport] opgeslagen: " + ProjectSettings.globalize_path(dir.path_join(fname)))


# ---------------------------------------------------------------- instellingen

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("oefenen", "lied", songs[song_index].get_file() if not songs.is_empty() else "")
	cfg.set_value("oefenen", "tempo", session.speed)
	cfg.set_value("oefenen", "wachten", session.wait_mode)
	cfg.set_value("oefenen", "hand", session.practice_hand)
	cfg.set_value("oefenen", "toetsen", key_alpha_i)
	cfg.save(SETTINGS_FILE)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return
	var wanted: String = cfg.get_value("oefenen", "lied", "")
	for i in songs.size():
		if songs[i].get_file() == wanted:
			song_index = i
	session.speed = cfg.get_value("oefenen", "tempo", 1.0)
	session.set_wait_mode(cfg.get_value("oefenen", "wachten", true))
	session.practice_hand = cfg.get_value("oefenen", "hand", -1)
	key_alpha_i = clampi(cfg.get_value("oefenen", "toetsen", 0), 0, KEY_ALPHAS.size() - 1)
	keyboard.base_alpha = KEY_ALPHAS[key_alpha_i]


# ---------------------------------------------------------------- log & diagnose

func _on_raw_midi(text: String) -> void:
	# Noten en pedalen niet in het log (dat wordt anders te groot), wel scans en fouten.
	if not text.begins_with("AAN") and not text.begins_with("UIT") and not text.begins_with("CC"):
		_log(text)


func _log(text: String) -> void:
	var t := (Time.get_ticks_msec() - _start_msec) / 1000.0
	print("[KeySight] %8.3f  %s" % [t, text])


func _refresh_diagnostics() -> void:
	var lines := PackedStringArray()
	lines.append_array(Diagnostics.platform_lines())
	lines.append("")
	lines.append_array(Diagnostics.xr_lines(xr))
	lines.append("Passthrough actief: %s" % passthrough_on)
	lines.append("")
	lines.append("MIDI-ingangen (Godot): %s" % (", ".join(midi.devices) if midi and not midi.devices.is_empty() else "geen"))
	lines.append("Liedjes: %d   Kalibratie: %s" % [songs.size(), _calib_msg])
	_diag_text = "\n".join(lines)
	ui.set_diag(_diag_text)


func _save_diagnostics() -> void:
	var f := FileAccess.open(DIAG_FILE, FileAccess.WRITE)
	if f:
		f.store_string(_diag_text + "\n")
		f.close()


# ---------------------------------------------------------------- tests

## Voor schermafbeeldingen: zet de app in een bepaalde toestand.
func _test_state(st: String) -> void:
	match st:
		"results":
			_start_lesson()
			session.set_wait_mode(false)
			session.playing = true
			# Snel een stuk "spelen" met wat foutjes.
			var rng := RandomNumberGenerator.new()
			rng.seed = 5
			for i in 4000:
				session.update(1.0 / 60.0)
				for n in session.notes:
					if n["state"] == NoteHighway.PENDING and absf(n["start"] - session.t) < 0.01 and rng.randf() > 0.08:
						session.note_on(n["pitch"], 70)
				if session.done:
					break
		"calib":
			_start_calibration()
			ui.set_calib("Kalibreren", CALIB_STEPS, "3 punten, passing 2,1 mm, breedte 121,7 cm. Nog een paar toetsen verspreid is nauwkeuriger.", 3, true)
		"diag":
			_on_ui("diag", null)


# ---------------------------------------------------------------- demo

## Speelt het lied zelf via nep-MIDI-events, met kleine timingfouten en af
## en toe een verkeerde of gemiste noot (start met: -- --demo).
func _demo_step() -> void:
	if ui_state != "lesson":
		return
	if not session.playing and not session.done:
		session.playing = true
		return
	var t := session.t
	for n in session.notes:
		if n["start"] > t + 0.02:
			break
		if n.get("demo", false) or n["start"] < t - 0.5:
			continue
		n["demo"] = true
		var r := randf()
		if r < 0.05:
			continue   # gemist
		var pitch: int = n["pitch"]
		if r < 0.09:
			pitch += 1  # verkeerde toets
		_demo_send(pitch, clampi(n["vel"] + randi_range(-15, 15), 1, 127), true)
		var off_after: float = (n["end"] - n["start"]) / session.speed * randf_range(0.6, 1.0)
		get_tree().create_timer(off_after).timeout.connect(_demo_send.bind(pitch, 0, false))


func _demo_send(pitch: int, vel: int, on: bool) -> void:
	var e := InputEventMIDI.new()
	e.message = MIDI_MESSAGE_NOTE_ON if on else MIDI_MESSAGE_NOTE_OFF
	e.pitch = pitch
	e.velocity = vel
	Input.parse_input_event(e)
