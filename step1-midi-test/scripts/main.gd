extends Node3D
## Piano VR, stap 1: MIDI-test.
##
## Toont een virtueel 88-toetsenklavier dat oplicht bij elke aanslag op de
## Clavinova, een live MIDI-log, pedaalstanden en een diagnosepaneel
## (OpenXR, passthrough, ALSA, USB). Werkt op de Steam Frame (OpenXR) en
## valt terug op een gewoon venster op een pc, zodat je ook daar kunt testen.
##
## Bediening (headset)
##   Rechter trekker   : klavier kalibreren, 1e keer linkervoorhoek A0,
##                       2e keer rechtervoorhoek C8
##   A / X             : passthrough aan/uit
##   B / Y             : MIDI opnieuw scannen
##   Linker trekker    : statistieken resetten + diagnose opslaan
## Bediening (pc)
##   R = MIDI scannen, P = passthrough, C = statistieken resetten, S = opslaan

const LOG_LINES := 14
const DIAG_FILE := "user://piano_vr_diagnose.txt"

var xr: XRInterface
var xr_active := false
var passthrough_on := false

var origin: XROrigin3D
var camera: XRCamera3D
var left_hand: XRController3D
var right_hand: XRController3D
var keyboard: PianoKeyboard
var midi: MidiMonitor
var world_env: WorldEnvironment

var status_label: Label3D
var log_label: Label3D
var diag_label: Label3D

var _log := PackedStringArray()
var _diag_text := ""
var _calib_left := Vector3.ZERO
var _calib_step := 0
var _calib_msg := "Niet gekalibreerd (rechter trekker op linkervoorhoek van A0)"
var _placed := false
var _start_msec := 0


func _ready() -> void:
	_start_msec = Time.get_ticks_msec()
	_setup_xr()
	_build_scene()
	midi = MidiMonitor.new()
	midi.name = "MidiMonitor"
	midi.note_on.connect(func(n: int, v: int, _c: int) -> void: keyboard.set_key(n, true, v))
	midi.note_off.connect(func(n: int, _c: int) -> void: keyboard.set_key(n, false))
	midi.raw_event.connect(_on_raw_event)
	midi.devices_changed.connect(func(_d: PackedStringArray) -> void: _refresh_diagnostics())
	add_child(midi)
	_refresh_diagnostics()
	_save_diagnostics()
	if "--demo" in OS.get_cmdline_user_args():
		_start_demo()


# ---------------------------------------------------------------- XR / scene

func _setup_xr() -> void:
	xr = XRServer.find_interface("OpenXR")
	if xr and xr.is_initialized():
		xr_active = true
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# Standaard passthrough aan als de runtime het aanbiedt.
		_set_passthrough(true)
	else:
		print("[PianoVR] Geen OpenXR, desktopmodus.")


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
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.8)
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
	if passthrough_on:
		env.background_mode = Environment.BG_CLEAR_COLOR

	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	origin.add_child(camera)
	left_hand = XRController3D.new()
	left_hand.tracker = &"left_hand"
	left_hand.pose = &"aim"
	origin.add_child(left_hand)
	right_hand = XRController3D.new()
	right_hand.tracker = &"right_hand"
	right_hand.pose = &"aim"
	origin.add_child(right_hand)
	left_hand.button_pressed.connect(_on_button.bind(&"left"))
	right_hand.button_pressed.connect(_on_button.bind(&"right"))
	_add_pointer(right_hand)
	_add_pointer(left_hand)

	keyboard = PianoKeyboard.new()
	keyboard.name = "PianoKeyboard"
	add_child(keyboard)

	# Panelen hangen aan het klavier, zodat ze mee verhuizen bij kalibratie.
	status_label = _make_label(Vector3(-0.60, 0.50, -0.32), 24)
	log_label = _make_label(Vector3(-0.60, 0.30, -0.30), 20)
	diag_label = _make_label(Vector3(0.14, 0.50, -0.32), 16)

	if not xr_active:
		# Desktop: vaste camera die op het klavier kijkt.
		keyboard.position = Vector3(0, 0.75, -0.55)
		camera.position = Vector3(0, 1.30, 0.05)
		camera.look_at(Vector3(0, 0.88, -0.75))
		camera.fov = 75
		_placed = true


func _add_pointer(ctrl: XRController3D) -> void:
	# Klein bolletje op het punt dat bij kalibratie telt.
	var s := SphereMesh.new()
	s.radius = 0.006
	s.height = 0.012
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1, 0.9, 0.1)
	s.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = s
	ctrl.add_child(mi)


func _make_label(pos: Vector3, size: int) -> Label3D:
	var l := Label3D.new()
	l.pixel_size = 0.0007
	l.font_size = size
	l.outline_size = 6
	l.double_sided = true
	l.no_depth_test = true
	l.modulate = Color(1, 1, 1)
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.position = pos
	l.rotation_degrees = Vector3(-20, 0, 0)
	keyboard.add_child(l)
	return l


## Zet het klavier ongeveer 45 cm voor en 45 cm onder het hoofd.
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


# ---------------------------------------------------------------- input

func _on_button(button: StringName, hand: StringName) -> void:
	var b := String(button)
	if b == "trigger_click" and hand == &"right":
		_calibrate_point(right_hand.global_position)
	elif b == "trigger_click" and hand == &"left":
		midi.reset_stats()
		_save_diagnostics()
	elif b == "ax_button":
		_set_passthrough(not passthrough_on)
		_refresh_diagnostics()
	elif b == "by_button":
		midi.rescan()
		_refresh_diagnostics()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_R:
			midi.rescan()
			_refresh_diagnostics()
		KEY_P:
			_set_passthrough(not passthrough_on)
			_refresh_diagnostics()
		KEY_C:
			midi.reset_stats()
		KEY_S:
			_save_diagnostics()


func _calibrate_point(p: Vector3) -> void:
	if _calib_step == 0:
		_calib_left = p
		_calib_step = 1
		_calib_msg = "Punt 1 OK. Nu rechter trekker op rechtervoorhoek van C8."
	else:
		var measured := keyboard.place_by_corners(_calib_left, p)
		_calib_step = 0
		_placed = true
		var nominal := keyboard.total_width
		_calib_msg = "Gekalibreerd: gemeten %.1f cm, nominaal %.1f cm (afwijking %+.1f cm)" % [
			measured * 100.0, nominal * 100.0, (measured - nominal) * 100.0]
		_on_raw_event("[kalibratie] " + _calib_msg)


# ---------------------------------------------------------------- demo

## Speelt nep-MIDI af (start met: -- --demo) om de app zonder piano te
## controleren. De events gaan via dezelfde Input-weg als echte MIDI.
func _start_demo() -> void:
	var t := Timer.new()
	t.wait_time = 0.25
	t.autostart = true
	add_child(t)
	var chord := [60, 64, 67, 72, 48, 36, 21, 108, 61, 66, 70]
	var step := [0]
	t.timeout.connect(func() -> void:
		var i: int = step[0]
		var n: int = chord[i % chord.size()]
		var prev: int = chord[(i + chord.size() - 3) % chord.size()]
		var on := InputEventMIDI.new()
		on.message = MIDI_MESSAGE_NOTE_ON
		on.pitch = n
		on.velocity = 30 + (i * 23) % 97
		Input.parse_input_event(on)
		var off := InputEventMIDI.new()
		off.message = MIDI_MESSAGE_NOTE_ON   # velocity 0 = note-off
		off.pitch = prev
		off.velocity = 0
		if i >= 3:
			Input.parse_input_event(off)
		var cc := InputEventMIDI.new()
		cc.message = MIDI_MESSAGE_CONTROL_CHANGE
		cc.controller_number = 64
		cc.controller_value = (i * 17) % 128
		Input.parse_input_event(cc)
		step[0] = i + 1)


# ---------------------------------------------------------------- UI

func _on_raw_event(text: String) -> void:
	var t := (Time.get_ticks_msec() - _start_msec) / 1000.0
	var line := "%8.3f  %s" % [t, text]
	print("[MIDI] ", line)
	_log.append(line)
	while _log.size() > LOG_LINES:
		_log.remove_at(0)
	log_label.text = "MIDI-log\n" + "\n".join(_log)


func _process(_delta: float) -> void:
	if xr_active and not _placed and Time.get_ticks_msec() - _start_msec > 1500:
		_place_in_front_of_head()
	_update_status()


func _update_status() -> void:
	var dev_txt := "GEEN MIDI-apparaat (zoekt elke 3 s)" if midi.devices.is_empty() else ", ".join(midi.devices)
	var held_names := PackedStringArray()
	for n in midi.held.keys():
		held_names.append(MidiMonitor.note_name(n))
	var since := "-"
	if midi.last_event_msec > 0:
		since = "%.1f s geleden" % ((Time.get_ticks_msec() - midi.last_event_msec) / 1000.0)
	var vel := "-" if midi.velocity_max < 0 else "%d..%d" % [midi.velocity_min, midi.velocity_max]
	status_label.text = "\n".join(PackedStringArray([
		"MIDI: " + dev_txt,
		"Aanslagen %d  |  Losgelaten %d  |  Ingedrukt nu %d  |  Max tegelijk %d" % [
			midi.total_note_ons, midi.total_note_offs, midi.held.size(), midi.max_polyphony],
		"Velocity %s  |  Wees-note-offs %d  |  Laatste event %s" % [vel, midi.orphan_note_offs, since],
		"Pedalen: sustain %s  sostenuto %s  soft %s" % [
			_bar(midi.sustain), _bar(midi.sostenuto), _bar(midi.soft)],
		"Nu: " + (" ".join(held_names) if held_names.size() > 0 else "-"),
		"Passthrough: %s  |  %s" % ["AAN" if passthrough_on else "uit", _calib_msg],
	]))


static func _bar(v: int) -> String:
	var n := int(round(v / 127.0 * 8))
	return "[" + "#".repeat(n) + ".".repeat(8 - n) + "] %3d" % v


func _refresh_diagnostics() -> void:
	var lines := PackedStringArray(["DIAGNOSE"])
	lines.append_array(Diagnostics.platform_lines())
	lines.append("")
	lines.append_array(Diagnostics.xr_lines(xr))
	lines.append("Passthrough actief: %s" % passthrough_on)
	lines.append("")
	lines.append("MIDI-ingangen (Godot): %s" % (", ".join(midi.devices) if midi and not midi.devices.is_empty() else "geen"))
	lines.append_array(Diagnostics.alsa_lines())
	lines.append("")
	lines.append_array(Diagnostics.usb_lines())
	_diag_text = "\n".join(lines)
	diag_label.text = _diag_text


func _save_diagnostics() -> void:
	_refresh_diagnostics()
	var report := _diag_text + "\n\nSTATUS\n" + status_label.text + "\n\nLOG\n" + "\n".join(_log) + "\n"
	print(report)
	var targets := [DIAG_FILE, OS.get_executable_path().get_base_dir().path_join("piano_vr_diagnose.txt")]
	for path in targets:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(report)
			f.close()
			print("[PianoVR] Diagnose opgeslagen: ", ProjectSettings.globalize_path(path))
