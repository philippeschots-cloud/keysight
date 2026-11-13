class_name AppUI
extends Control
## De gebruikersinterface van KeySight: menu, les-balk, resultatenkaart,
## kalibratie en diagnose. Gewone Control-nodes; VrScreen zet ze in de 3D-wereld.

signal action(id: String, arg: Variant)

const W := 1800
const H := 720

const BG := Color(0.07, 0.08, 0.11, 0.86)
const TILE := Color(1, 1, 1, 0.06)
const TEXT := Color(0.95, 0.96, 0.98)
const MUTED := Color(0.66, 0.70, 0.78)
const ACCENT := Color("3ddc97")
const ACCENT_DARK := Color("0e2a20")
const AMBER := Color("ffc145")
const BAD := Color("ff5a5a")
const RIGHT := Color(1.0, 0.55, 0.10)   # rechterhand oranje (zelfde als de noten)
const LEFT := Color(0.15, 0.55, 1.0)    # linkerhand blauw

var font_regular: FontFile
var font_bold: FontFile

var _states := {}
var _song_box: VBoxContainer
var _song_scroll: ScrollContainer
var _song_group := ButtonGroup.new()
var _song_title: Label
var _song_info: Label
var _seg := {}             # naam -> {waarde: Button}
var _tempo_label: Button
var _keys_btn: Button
var _pass_btn: Button
var _hud := {}
var _res := {}
var _cal := {}
var _diag_label: Label
var _updating := false


func _init() -> void:
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font_regular = load("res://fonts/AtkinsonHyperlegible-Regular.ttf")
	font_bold = load("res://fonts/AtkinsonHyperlegible-Bold.ttf")
	for f in [font_regular, font_bold]:
		f.multichannel_signed_distance_field = true
		f.msdf_pixel_range = 12
	theme = _make_theme()
	_build_menu()
	_build_hud()
	_build_results()
	_build_calib()
	_build_diag()
	show_state("menu")


# ---------------------------------------------------------------- thema

func _box(bg: Color, radius: int, pad: int, border := Color(0, 0, 0, 0), bw := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	s.anti_aliasing = true
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	return s


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font_regular
	t.default_font_size = 32
	t.set_stylebox("panel", "PanelContainer", _box(BG, 28, 30))
	t.set_color("font_color", "Label", TEXT)
	# Knoppen
	t.set_stylebox("normal", "Button", _box(TILE, 16, 14))
	t.set_stylebox("hover", "Button", _box(Color(1, 1, 1, 0.14), 16, 14, ACCENT, 3))
	t.set_stylebox("pressed", "Button", _box(ACCENT, 16, 14))
	t.set_stylebox("hover_pressed", "Button", _box(ACCENT.lightened(0.15), 16, 14, Color.WHITE, 3))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_stylebox("disabled", "Button", _box(Color(1, 1, 1, 0.03), 16, 14))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", ACCENT_DARK)
	t.set_color("font_hover_pressed_color", "Button", ACCENT_DARK)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.3))
	t.set_font_size("font_size", "Button", 30)
	# Grote hoofdknop
	t.set_type_variation("Primary", "Button")
	t.set_stylebox("normal", "Primary", _box(ACCENT, 22, 18))
	t.set_stylebox("hover", "Primary", _box(ACCENT.lightened(0.18), 22, 18, Color.WHITE, 4))
	t.set_stylebox("pressed", "Primary", _box(ACCENT.darkened(0.2), 22, 18))
	t.set_color("font_color", "Primary", ACCENT_DARK)
	t.set_color("font_hover_color", "Primary", ACCENT_DARK)
	t.set_font("font", "Primary", font_bold)
	t.set_font_size("font_size", "Primary", 46)
	# Liedrij
	t.set_type_variation("SongRow", "Button")
	t.set_stylebox("normal", "SongRow", _box(Color(0, 0, 0, 0), 14, 12))
	t.set_stylebox("hover", "SongRow", _box(Color(1, 1, 1, 0.10), 14, 12, ACCENT, 2))
	t.set_stylebox("pressed", "SongRow", _box(Color(ACCENT, 0.22), 14, 12, ACCENT, 2))
	t.set_stylebox("hover_pressed", "SongRow", _box(Color(ACCENT, 0.30), 14, 12, ACCENT, 3))
	# Labels
	t.set_type_variation("Logo", "Label")
	t.set_font("font", "Logo", font_bold)
	t.set_font_size("font_size", "Logo", 50)
	t.set_color("font_color", "Logo", ACCENT)
	t.set_type_variation("H2", "Label")
	t.set_font("font", "H2", font_bold)
	t.set_font_size("font_size", "H2", 42)
	t.set_type_variation("Muted", "Label")
	t.set_font_size("font_size", "Muted", 28)
	t.set_color("font_color", "Muted", MUTED)
	t.set_type_variation("Caption", "Label")
	t.set_font("font", "Caption", font_bold)
	t.set_font_size("font_size", "Caption", 26)
	t.set_color("font_color", "Caption", MUTED)
	t.set_type_variation("Big", "Label")
	t.set_font("font", "Big", font_bold)
	t.set_font_size("font_size", "Big", 40)
	t.set_type_variation("Tile", "PanelContainer")
	t.set_stylebox("panel", "Tile", _box(TILE, 18, 18))
	t.set_type_variation("Hud", "PanelContainer")
	t.set_stylebox("panel", "Hud", _box(BG, 24, 18))
	# Voortgangsbalk
	t.set_stylebox("background", "ProgressBar", _box(Color(1, 1, 1, 0.10), 8, 0))
	t.set_stylebox("fill", "ProgressBar", _box(ACCENT, 8, 0))
	# Schuifbalk smal en rustig
	var grab := _box(Color(1, 1, 1, 0.25), 6, 0)
	grab.content_margin_left = 6
	grab.content_margin_right = 6
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color(1, 1, 1, 0.4), 6, 0))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(ACCENT, 6, 0))
	t.set_stylebox("scroll", "VScrollBar", _box(Color(1, 1, 1, 0.04), 6, 0))
	return t


# ---------------------------------------------------------------- helpers

func _label(text: String, variation := "", size := 0) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, id: String, arg: Variant = null, variation := "") -> Button:
	var b := Button.new()
	b.text = text
	if variation != "":
		b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void:
		if not _updating:
			action.emit(id, arg))
	return b


func _full_panel(variation := "") -> PanelContainer:
	var p := PanelContainer.new()
	if variation != "":
		p.theme_type_variation = variation
	p.position = Vector2.ZERO
	p.size = Vector2(W, H)
	add_child(p)
	return p


## Segment-knoppen (één tegelijk aan).
func _segmented(name: String, options: Array, colors := {}) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	_seg[name] = {}
	for o in options:
		var b := _button(o[1], name, o[0])
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(170, 64)
		if colors.has(o[0]):
			b.add_theme_color_override("font_color", colors[o[0]])
		box.add_child(b)
		_seg[name][o[0]] = b
	return box


func _row(caption: String, content: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 18)
	var c := _label(caption, "Caption")
	c.custom_minimum_size = Vector2(150, 0)
	c.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(c)
	r.add_child(content)
	return r


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ---------------------------------------------------------------- menu

func _build_menu() -> void:
	var p := _full_panel()
	_states["menu"] = p
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 36)
	p.add_child(h)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(720, 0)
	left.add_theme_constant_override("separation", 10)
	h.add_child(left)
	var brand := HBoxContainer.new()
	brand.add_theme_constant_override("separation", 16)
	brand.add_child(_label("KeySight", "Logo"))
	var tag := _label("leer spelen op je eigen piano", "Muted")
	tag.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	tag.size_flags_vertical = Control.SIZE_SHRINK_END
	brand.add_child(tag)
	left.add_child(brand)
	left.add_child(_spacer(4))
	left.add_child(_label("LIEDJES", "Caption"))
	_song_scroll = ScrollContainer.new()
	_song_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_song_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(_song_scroll)
	_song_box = VBoxContainer.new()
	_song_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_song_box.add_theme_constant_override("separation", 4)
	_song_scroll.add_child(_song_box)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 14)
	h.add_child(right)
	_song_title = _label("-", "H2")
	_song_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_song_title.clip_text = true
	right.add_child(_song_title)
	_song_info = _label("", "Muted")
	right.add_child(_song_info)
	right.add_child(_spacer(6))
	right.add_child(_row("MODUS", _segmented("mode", [[true, "Wachten"], [false, "Meespelen"]])))
	right.add_child(_row("HANDEN", _segmented("hand", [[-1, "Beide"], [0, "Links"], [1, "Rechts"]], {0: LEFT.lightened(0.25), 1: RIGHT.lightened(0.1)})))
	var tempo := HBoxContainer.new()
	tempo.add_theme_constant_override("separation", 8)
	var minus := _button("-", "slower")
	minus.custom_minimum_size = Vector2(90, 64)
	_tempo_label = _button("100%", "tempo_reset")
	_tempo_label.custom_minimum_size = Vector2(170, 64)
	var plus := _button("+", "faster")
	plus.custom_minimum_size = Vector2(90, 64)
	tempo.add_child(minus)
	tempo.add_child(_tempo_label)
	tempo.add_child(plus)
	right.add_child(_row("TEMPO", tempo))
	var grow := _spacer(0)
	grow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(grow)
	var start := _button("Start", "start", null, "Primary")
	start.custom_minimum_size = Vector2(0, 104)
	right.add_child(start)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 8)
	for spec in [["Kalibreren", "calib"], ["Bijstellen", "tune"], ["Passthrough", "pass"], ["Toetsen", "keys"], ["Diagnose", "diag"]]:
		var b := _button(spec[0], spec[1])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 58)
		b.add_theme_font_size_override("font_size", 27)
		tools.add_child(b)
		if spec[1] == "keys":
			_keys_btn = b
		elif spec[1] == "pass":
			_pass_btn = b
			b.toggle_mode = true
	right.add_child(tools)


func set_songs(list: Array) -> void:
	for c in _song_box.get_children():
		c.queue_free()
	for i in list.size():
		var s: Dictionary = list[i]
		var b := _button("", "song", i, "SongRow")
		b.toggle_mode = true
		b.button_group = _song_group
		b.custom_minimum_size = Vector2(0, 66)
		var row := HBoxContainer.new()
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 16
		row.offset_right = -16
		row.add_theme_constant_override("separation", 14)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := _label(s["title"], "", 30)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.clip_text = true
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(t)
		var d := _label(s["dur"], "Muted", 26)
		d.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(d)
		var best := _label(s["best"], "", 26)
		best.custom_minimum_size = Vector2(80, 0)
		best.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		best.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		best.add_theme_color_override("font_color", ACCENT if s["best"] != "" else MUTED)
		row.add_child(best)
		b.add_child(row)
		_song_box.add_child(b)


func set_selected(i: int, title: String, info: String) -> void:
	_updating = true
	if i >= 0 and i < _song_box.get_child_count():
		var b: Button = _song_box.get_child(i)
		b.button_pressed = true
		_ensure_visible.call_deferred(b)
	_song_title.text = title
	_song_info.text = info
	_updating = false


func _ensure_visible(b: Control) -> void:
	if is_instance_valid(b):
		_song_scroll.ensure_control_visible(b)


func scroll_songs(pixels: float) -> void:
	_song_scroll.scroll_vertical += int(pixels)


func set_options(o: Dictionary) -> void:
	_updating = true
	if _seg["mode"].has(o["wait"]):
		_seg["mode"][o["wait"]].button_pressed = true
	if _seg["hand"].has(o["hand"]):
		_seg["hand"][o["hand"]].button_pressed = true
	_tempo_label.text = "%d%%" % roundi(o["speed"] * 100)
	_keys_btn.text = "Toetsen: %s" % o["keys"]
	_pass_btn.button_pressed = o["passthrough"]
	_updating = false


# ---------------------------------------------------------------- les-balk

func _build_hud() -> void:
	var p := PanelContainer.new()
	p.theme_type_variation = "Hud"
	p.position = Vector2(0, H - 128)
	p.size = Vector2(W, 128)
	add_child(p)
	_states["lesson"] = p
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 26)
	p.add_child(h)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(480, 0)
	left.add_theme_constant_override("separation", 0)
	_hud["title"] = _label("-", "", 32)
	_hud["title"].add_theme_font_override("font", font_bold)
	_hud["title"].clip_text = true
	_hud["title"].text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hud["sub"] = _label("", "Muted", 26)
	left.add_child(_hud["title"])
	left.add_child(_hud["sub"])
	h.add_child(left)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	mid.add_theme_constant_override("separation", 10)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	bar.max_value = 1.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud["bar"] = bar
	mid.add_child(bar)
	_hud["feedback"] = _label("", "", 28)
	mid.add_child(_hud["feedback"])
	h.add_child(mid)
	var acc := VBoxContainer.new()
	acc.custom_minimum_size = Vector2(150, 0)
	acc.alignment = BoxContainer.ALIGNMENT_CENTER
	acc.add_theme_constant_override("separation", -6)
	_hud["acc"] = _label("-", "Big")
	_hud["acc"].horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	acc.add_child(_hud["acc"])
	var cap := _label("RAAK", "Caption", 22)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	acc.add_child(cap)
	h.add_child(acc)
	for spec in [["Pauze", "pause"], ["Opnieuw", "restart"], ["Menu", "menu"]]:
		var b := _button(spec[0], spec[1])
		b.custom_minimum_size = Vector2(160, 0)
		h.add_child(b)
		_hud[spec[1]] = b


func update_hud(d: Dictionary) -> void:
	_hud["title"].text = d["title"]
	_hud["sub"].text = d["sub"]
	_hud["bar"].value = d["progress"]
	_hud["acc"].text = d["acc"]
	_hud["feedback"].text = d["feedback"]
	_hud["feedback"].add_theme_color_override("font_color", d.get("feedback_color", MUTED))
	_hud["pause"].text = "Pauze" if d["playing"] else "Verder"


# ---------------------------------------------------------------- resultaten

class AccRing:
	extends Control
	var value := 0.0
	var font: Font
	var color := Color.WHITE

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 16.0
		draw_arc(c, r, 0, TAU, 96, Color(1, 1, 1, 0.10), 22, true)
		if value > 0.0:
			draw_arc(c, r, -PI / 2.0, -PI / 2.0 + TAU * clampf(value / 100.0, 0.0, 1.0), 96, color, 22, true)
		var txt := "%d%%" % roundi(value)
		var fs := 76
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, c + Vector2(-w / 2.0, 22), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		var sub := "raak"
		var w2 := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
		draw_string(font, c + Vector2(-w2 / 2.0, 62), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color(1, 1, 1, 0.6))


func _build_results() -> void:
	var p := _full_panel()
	_states["results"] = p
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 44)
	p.add_child(h)
	var ring := AccRing.new()
	ring.font = font_bold
	ring.custom_minimum_size = Vector2(380, 380)
	ring.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(ring)
	_res["ring"] = ring
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 14)
	h.add_child(v)
	_res["head"] = _label("Klaar!", "Logo")
	v.add_child(_res["head"])
	_res["song"] = _label("", "Muted")
	v.add_child(_res["song"])
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 12)
	for spec in [["hits", "RAAK"], ["wrong", "FOUT"], ["missed", "GEMIST"], ["streak", "REEKS"]]:
		var tile := PanelContainer.new()
		tile.theme_type_variation = "Tile"
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tv := VBoxContainer.new()
		tv.add_theme_constant_override("separation", -4)
		var val := _label("0", "Big")
		tv.add_child(val)
		tv.add_child(_label(spec[1], "Caption", 22))
		tile.add_child(tv)
		tiles.add_child(tile)
		_res[spec[0]] = val
	v.add_child(tiles)
	_res["timing"] = _label("", "", 28)
	v.add_child(_res["timing"])
	_res["hardest"] = _label("", "", 28)
	v.add_child(_res["hardest"])
	var tip := PanelContainer.new()
	var tip_box := _box(Color(ACCENT, 0.10), 16, 18)
	tip_box.border_color = ACCENT
	tip_box.border_width_left = 6
	tip.add_theme_stylebox_override("panel", tip_box)
	tip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_res["tip"] = _label("", "", 30)
	_res["tip"].autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_child(_res["tip"])
	v.add_child(tip)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 12)
	var again := _button("Opnieuw", "restart", null, "Primary")
	again.add_theme_font_size_override("font_size", 36)
	again.custom_minimum_size = Vector2(300, 76)
	btns.add_child(again)
	for spec in [["Volgend lied", "next"], ["Menu", "menu"]]:
		var b := _button(spec[0], spec[1])
		b.custom_minimum_size = Vector2(240, 76)
		btns.add_child(b)
	v.add_child(btns)


func show_results(s: Dictionary) -> void:
	var acc: float = s.get("acc", 0.0)
	var ring: AccRing = _res["ring"]
	ring.value = acc
	ring.color = ACCENT if acc >= 90.0 else (AMBER if acc >= 70.0 else BAD)
	ring.queue_redraw()
	_res["head"].text = "Prachtig!" if acc >= 95.0 else ("Goed gedaan!" if acc >= 80.0 else "Klaar, nog even oefenen")
	var mode := "wachtmodus" if s.get("wait", false) else "meespelen"
	var hand: int = s.get("hand", -1)
	_res["song"].text = "%s  ·  %s  ·  tempo %d%%  ·  %s" % [s.get("title", ""), mode, roundi(s.get("speed", 1.0) * 100),
		{-1: "beide handen", 0: "linkerhand", 1: "rechterhand"}[hand]]
	_res["hits"].text = "%d/%d" % [s.get("hits", 0), s.get("total", 0)]
	_res["wrong"].text = str(s.get("wrong", 0))
	_res["missed"].text = str(s.get("missed", 0))
	_res["streak"].text = str(s.get("streak", 0))
	var timing: String = s.get("timing", "")
	_res["timing"].text = "Timing: " + timing if timing != "" else "Timing: in wachtmodus niet gemeten"
	var hardest: String = s.get("hardest", "")
	_res["hardest"].text = "Lastigste stuk: " + hardest if hardest != "" else "Geen lastige stukken: overal 85% of beter"
	var tips: Array = s.get("tips", [])
	_res["tip"].text = tips[0] if not tips.is_empty() else "Speel het nog eens en kijk of je reeks langer wordt."


# ---------------------------------------------------------------- kalibratie

func _build_calib() -> void:
	var p := _full_panel()
	_states["calib"] = p
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	p.add_child(v)
	_cal["title"] = _label("Kalibreren", "Logo")
	v.add_child(_cal["title"])
	_cal["steps"] = _label("", "", 32)
	_cal["steps"].autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_cal["steps"])
	_cal["dots"] = _label("", "Big")
	v.add_child(_cal["dots"])
	_cal["status"] = _label("", "", 30)
	_cal["status"].autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cal["status"].size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_cal["status"])
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 12)
	_cal["done"] = _button("Klaar", "calib_done", null, "Primary")
	_cal["done"].custom_minimum_size = Vector2(320, 84)
	_cal["done"].add_theme_font_size_override("font_size", 38)
	btns.add_child(_cal["done"])
	_cal["cancel"] = _button("Annuleren", "calib_cancel")
	_cal["cancel"].custom_minimum_size = Vector2(260, 84)
	btns.add_child(_cal["cancel"])
	v.add_child(btns)


## n = aantal punten, ok = fit is goed genoeg om op te slaan.
func set_calib(title: String, steps: String, status: String, n: int, ok: bool, show_cancel := true) -> void:
	_cal["title"].text = title
	_cal["steps"].text = steps
	_cal["status"].text = status
	_cal["status"].add_theme_color_override("font_color", ACCENT if ok else TEXT)
	var dots := ""
	if n >= 0:
		dots = "%d %s gemeten" % [n, "punt" if n == 1 else "punten"]
		if ok:
			dots += "  -  klopt"
	_cal["dots"].text = dots
	_cal["dots"].add_theme_color_override("font_color", ACCENT if ok else AMBER)
	_cal["cancel"].visible = show_cancel


# ---------------------------------------------------------------- diagnose

func _build_diag() -> void:
	var p := _full_panel()
	_states["diag"] = p
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	p.add_child(v)
	v.add_child(_label("Diagnose", "H2"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	_diag_label = _label("", "", 24)
	scroll.add_child(_diag_label)
	var back := _button("Terug", "back")
	back.custom_minimum_size = Vector2(240, 70)
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(back)


func set_diag(text: String) -> void:
	_diag_label.text = text


# ---------------------------------------------------------------- toestanden

func show_state(name: String) -> void:
	for k in _states.keys():
		_states[k].visible = k == name
