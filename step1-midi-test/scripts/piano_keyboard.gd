class_name PianoKeyboard
extends Node3D
## Virtueel 88-toetsenklavier op ware grootte (A0 = MIDI 21 t/m C8 = MIDI 108).
##
## Lokale assen: +X loopt van laag naar hoog, -Z wijst van de voorrand van de
## toetsen naar achteren (weg van de speler), +Y is omhoog.
## Oorsprong = voorrand van de toetsen, midden tussen de linkerrand van A0 en
## de rechterrand van C8. Zo kan een kalibratie met twee punten (linker- en
## rechtervoorhoek) het klavier exact plaatsen.

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
## toetsen waar hij tussen ligt (in meter). Op een echte piano staan C#/D# en
## F#/G#/A# niet precies op de naden maar zijn ze iets naar buiten geschoven.
const BLACK_SHIFT := {1: -0.0020, 3: 0.0020, 6: -0.0028, 8: 0.0, 10: 0.0028}

const COLOR_WHITE := Color(0.95, 0.95, 0.95, 0.45)
const COLOR_BLACK := Color(0.25, 0.25, 0.30, 0.85)
const COLOR_HIT_LOW := Color(0.2, 0.6, 1.0, 0.9)
const COLOR_HIT_HIGH := Color(1.0, 0.35, 0.15, 0.95)

var _keys := {}            # midi-noot -> MeshInstance3D
var _materials := {}       # midi-noot -> StandardMaterial3D
var _base_y := {}          # midi-noot -> rust-hoogte
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
	# Zwarte toets: naad tussen vorige witte en volgende witte + kleine shift.
	return whites_before * WHITE_WIDTH + BLACK_SHIFT[note % 12]


static func white_key_count() -> int:
	var c := 0
	for n in range(LOWEST_NOTE, HIGHEST_NOTE + 1):
		if not is_black(n):
			c += 1
	return c


func _build() -> void:
	total_width = white_key_count() * WHITE_WIDTH
	var half := total_width / 2.0
	for note in range(LOWEST_NOTE, HIGHEST_NOTE + 1):
		var black := is_black(note)
		var mesh := BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = COLOR_BLACK if black else COLOR_WHITE
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


## Licht een toets op; kleur loopt van blauw (zacht) naar oranje (hard).
func set_key(note: int, pressed: bool, velocity: int = 64) -> void:
	if not _keys.has(note):
		return
	var mat: StandardMaterial3D = _materials[note]
	var mi: MeshInstance3D = _keys[note]
	if pressed:
		var t := clampf(velocity / 127.0, 0.0, 1.0)
		mat.albedo_color = COLOR_HIT_LOW.lerp(COLOR_HIT_HIGH, t)
		mi.position.y = _base_y[note] - 0.004
	else:
		mat.albedo_color = COLOR_BLACK if is_black(note) else COLOR_WHITE
		mi.position.y = _base_y[note]


func release_all() -> void:
	for note in _keys.keys():
		set_key(note, false)


## Plaatst het klavier zodat de linkervoorhoek van A0 op `left` ligt en de
## rechtervoorhoek van C8 op `right`. `up` is de wereld-verticaal.
## Geeft de gemeten breedte terug (ter controle t.o.v. total_width).
func place_by_corners(left: Vector3, right: Vector3, up: Vector3 = Vector3.UP) -> float:
	var x_axis := right - left
	x_axis -= up * x_axis.dot(up)   # horizontaal houden
	var measured := x_axis.length()
	if measured < 0.1:
		return measured
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(up).normalized()   # wijst naar de speler toe
	var y_axis := z_axis.cross(x_axis).normalized()
	var mid := (left + right) / 2.0
	global_transform = Transform3D(Basis(x_axis, y_axis, z_axis), mid)
	return measured
