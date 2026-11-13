class_name PianoKeyboard
extends Node3D
## Virtueel 88-toetsenklavier op ware grootte (A0 = MIDI 21 t/m C8 = MIDI 108).
##
## Lokale assen: +X loopt van laag naar hoog, -Z wijst van de voorrand van de
## toetsen naar achteren (weg van de speler), +Y is omhoog.
## Oorsprong = voorrand van de toetsen, midden tussen de linkerrand van A0 en
## de rechterrand van C8, op de onderkant van de witte toetsen.
##
## Elke toets heeft drie lagen die elk frame samengevoegd worden:
##   1. ingedrukt (echte piano)   -> kleur per aanslag of feedbackkleur
##   2. flits (raak/fout)         -> korte kleur die uitdooft
##   3. hint (vallende noot komt) -> kleur van de noot, sterkte 0..1

const LOWEST_NOTE := 21
const HIGHEST_NOTE := 108

# Standaardmaten van een akoestisch/digitaal klavier, in meter.
const WHITE_WIDTH := 0.0235
const WHITE_LENGTH := 0.150
const WHITE_HEIGHT := 0.012
const BLACK_WIDTH := 0.0137
const BLACK_LENGTH := 0.095
const BLACK_HEIGHT := 0.010
const KEY_GAP := 0.0008

## Verschuiving van elke zwarte toets t.o.v. de naad tussen de twee witte
## toetsen waar hij tussen ligt (in meter).
const BLACK_SHIFT := {1: -0.0020, 3: 0.0020, 6: -0.0028, 8: 0.0, 10: 0.0028}

const COLOR_WHITE := Color(0.95, 0.95, 0.95, 0.45)
const COLOR_BLACK := Color(0.25, 0.25, 0.30, 0.85)
const COLOR_HIT_LOW := Color(0.2, 0.6, 1.0, 0.9)
const COLOR_HIT_HIGH := Color(1.0, 0.35, 0.15, 0.95)

## Zichtbaarheid van de toetsen zelf (hints en aanslagen blijven zichtbaar).
## 1 = vol, 0.35 = zwak, 0 = uit.
var base_alpha := 1.0:
	set(v):
		base_alpha = v
		_dirty_all()

var _keys := {}            # midi-noot -> MeshInstance3D
var _materials := {}       # midi-noot -> StandardMaterial3D
var _base_y := {}          # midi-noot -> rust-hoogte
var _pressed := {}         # noot -> Color (ingedrukt)
var _flash := {}           # noot -> [Color, resterende tijd, totale tijd]
var _hint := {}            # noot -> [Color, sterkte]
var _dirty := {}
var total_width := 0.0


func _ready() -> void:
	_build()


static func is_black(note: int) -> bool:
	return (note % 12) in [1, 3, 6, 8, 10]


## X-positie van het midden van een toets, gemeten vanaf de linkerrand van A0.
static func key_center_x(note: int) -> float:
	var whites_before := 0
	for n in range(LOWEST_NOTE, note):
		if not is_black(n):
			whites_before += 1
	if not is_black(note):
		return (whites_before + 0.5) * WHITE_WIDTH
	return whites_before * WHITE_WIDTH + BLACK_SHIFT[note % 12]


static func white_key_count() -> int:
	var c := 0
	for n in range(LOWEST_NOTE, HIGHEST_NOTE + 1):
		if not is_black(n):
			c += 1
	return c


static func nominal_width() -> float:
	return white_key_count() * WHITE_WIDTH


## Lokale X van het midden van een toets (oorsprong = midden van het klavier).
func local_x(note: int) -> float:
	return key_center_x(note) - total_width / 2.0


## Bovenkant van een toets in lokale Y.
static func key_top_y(note: int) -> float:
	return WHITE_HEIGHT + BLACK_HEIGHT if is_black(note) else WHITE_HEIGHT


static func key_width(note: int) -> float:
	return BLACK_WIDTH if is_black(note) else WHITE_WIDTH


func _build() -> void:
	total_width = nominal_width()
	var half := total_width / 2.0
	for note in range(LOWEST_NOTE, HIGHEST_NOTE + 1):
		var black := is_black(note)
		var mesh := BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = COLOR_BLACK if black else COLOR_WHITE
		# Zwarte toetsen altijd boven de witte tekenen (doorzichtig sorteren).
		mat.render_priority = 1 if black else 0
		var mi := MeshInstance3D.new()
		mi.name = "Key%d" % note
		var x := key_center_x(note) - half
		var y: float
		var z: float
		if black:
			mesh.size = Vector3(BLACK_WIDTH - KEY_GAP, BLACK_HEIGHT, BLACK_LENGTH)
			y = WHITE_HEIGHT + BLACK_HEIGHT / 2.0
			z = -(WHITE_LENGTH - BLACK_LENGTH / 2.0)
		else:
			mesh.size = Vector3(WHITE_WIDTH - KEY_GAP, WHITE_HEIGHT, WHITE_LENGTH)
			y = WHITE_HEIGHT / 2.0
			z = -WHITE_LENGTH / 2.0
		mesh.material = mat
		mi.mesh = mesh
		mi.position = Vector3(x, y, z)
		add_child(mi)
		_keys[note] = mi
		_materials[note] = mat
		_base_y[note] = y


## Echte toets ingedrukt/losgelaten. Zonder kleur: blauw (zacht) tot oranje (hard).
func set_key(note: int, pressed: bool, velocity: int = 64, color = null) -> void:
	if not _keys.has(note):
		return
	if pressed:
		if color == null:
			var t := clampf(velocity / 127.0, 0.0, 1.0)
			color = COLOR_HIT_LOW.lerp(COLOR_HIT_HIGH, t)
		_pressed[note] = color
	else:
		_pressed.erase(note)
	_dirty[note] = true


## Korte gekleurde flits (bv. groen = raak, rood = fout).
func flash(note: int, color: Color, seconds: float = 0.35) -> void:
	if not _keys.has(note):
		return
	_flash[note] = [color, seconds, seconds]
	_dirty[note] = true


## Vooraankondiging van een noot: kleur en sterkte 0..1. Sterkte 0 = weg.
func set_hint(note: int, color: Color, strength: float) -> void:
	if not _keys.has(note):
		return
	if strength <= 0.001:
		if _hint.has(note):
			_hint.erase(note)
			_dirty[note] = true
		return
	_hint[note] = [color, strength]
	_dirty[note] = true


func clear_hints() -> void:
	for n in _hint.keys():
		_dirty[n] = true
	_hint.clear()


func release_all() -> void:
	for n in _pressed.keys():
		_dirty[n] = true
	_pressed.clear()


func _dirty_all() -> void:
	for n in _keys.keys():
		_dirty[n] = true


func _process(delta: float) -> void:
	for n in _flash.keys():
		_flash[n][1] -= delta
		_dirty[n] = true
		if _flash[n][1] <= 0.0:
			_flash.erase(n)
	if _dirty.is_empty():
		return
	for n in _dirty.keys():
		_apply(n)
	_dirty.clear()


func _apply(note: int) -> void:
	var black := is_black(note)
	var base: Color = COLOR_BLACK if black else COLOR_WHITE
	base.a *= base_alpha
	var c := base
	var down := 0.0
	if _hint.has(note):
		var h: Color = _hint[note][0]
		var s: float = _hint[note][1]
		var target := Color(h.r, h.g, h.b, maxf(0.75, base.a))
		c = base.lerp(target, clampf(s, 0.0, 1.0))
		down = 0.002 * s
	if _pressed.has(note):
		c = _pressed[note]
		down = 0.004
	if _flash.has(note):
		var f: Color = _flash[note][0]
		var k: float = _flash[note][1] / _flash[note][2]
		c = c.lerp(Color(f.r, f.g, f.b, 0.95), clampf(k, 0.0, 1.0))
	_materials[note].albedo_color = c
	_keys[note].visible = c.a > 0.01
	_keys[note].position.y = _base_y[note] - down


## Plaatst het klavier zodat de linkervoorhoek van A0 op `left` ligt en de
## rechtervoorhoek van C8 op `right`. `up` is de wereld-verticaal.
## Met `stretch` wordt het klavier in de breedte geschaald naar de gemeten
## breedte (echte piano's wijken een paar mm af van de standaardmaat).
## Geeft de gemeten breedte terug.
func place_by_corners(left: Vector3, right: Vector3, up: Vector3 = Vector3.UP, stretch: bool = false) -> float:
	var x_axis := right - left
	x_axis -= up * x_axis.dot(up)   # horizontaal houden
	var measured := x_axis.length()
	if measured < 0.1:
		return measured
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(up).normalized()   # wijst naar de speler toe
	var y_axis := z_axis.cross(x_axis).normalized()
	var mid := (left + right) / 2.0
	var sx := measured / total_width if stretch else 1.0
	global_transform = Transform3D(Basis(x_axis * sx, y_axis, z_axis), mid)
	return measured
