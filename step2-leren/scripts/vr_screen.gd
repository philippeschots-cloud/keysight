class_name VrScreen
extends Node3D
## Een 2D-gebruikersinterface (Control-nodes in een SubViewport) op een
## vlak in de 3D-wereld. De straal van een controller (of de muis op de pc)
## wordt omgerekend naar pixelcoördinaten en als muis-event doorgegeven, zodat
## knoppen gewoon hover/ingedrukt-standen krijgen.

const PX_PER_M := 2000.0   # 2 px per mm: scherp genoeg op ~0,7 m afstand

var viewport: SubViewport
var quad: MeshInstance3D
var size_m := Vector2.ZERO
var size_px := Vector2i.ZERO
var _mouse_down := false
var _last_px := Vector2(-1, -1)


func _init(width_m: float, height_m: float) -> void:
	size_m = Vector2(width_m, height_m)
	size_px = Vector2i(roundi(width_m * PX_PER_M), roundi(height_m * PX_PER_M))


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = size_px
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.gui_embed_subwindows = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var mesh := QuadMesh.new()
	mesh.size = size_m
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.albedo_texture = viewport.get_texture()
	mat.render_priority = 6
	mat.no_depth_test = true
	mesh.material = mat
	quad = MeshInstance3D.new()
	quad.mesh = mesh
	add_child(quad)


func add_ui(c: Control) -> void:
	viewport.add_child(c)


## Snijpunt van een straal met het scherm: {px: Vector2, point: Vector3} of {}.
func ray_hit(from: Vector3, dir: Vector3) -> Dictionary:
	if not is_visible_in_tree():
		return {}
	var inv := global_transform.affine_inverse()
	var o := inv * from
	var d := inv.basis * dir
	if absf(d.z) < 1e-6:
		return {}
	var k := -o.z / d.z
	if k <= 0.0:
		return {}
	var hit := o + d * k
	if absf(hit.x) > size_m.x / 2.0 or absf(hit.y) > size_m.y / 2.0:
		return {}
	var px := Vector2((hit.x / size_m.x + 0.5) * size_px.x, (0.5 - hit.y / size_m.y) * size_px.y)
	return {"px": px, "point": global_transform * hit}


## Is er op dit pixel iets aanklikbaars (geen doorzichtige leegte)?
func is_over_ui(px: Vector2) -> bool:
	pointer_move(px)
	return viewport.gui_get_hovered_control() != null


func pointer_move(px: Vector2) -> void:
	if px == _last_px:
		return
	var rel := px - _last_px if _last_px.x >= 0 else Vector2.ZERO
	_last_px = px
	var e := InputEventMouseMotion.new()
	e.position = px
	e.global_position = px
	e.relative = rel
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if _mouse_down else 0
	viewport.push_input(e)


func pointer_leave() -> void:
	if _last_px.x < 0:
		return
	pointer_move(Vector2(-100, -100))
	_last_px = Vector2(-1, -1)


func pointer_button(px: Vector2, pressed: bool, button := MOUSE_BUTTON_LEFT) -> void:
	pointer_move(px)
	var e := InputEventMouseButton.new()
	e.position = px
	e.global_position = px
	e.button_index = button
	e.pressed = pressed
	if button == MOUSE_BUTTON_LEFT:
		_mouse_down = pressed
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(e)


func click(px: Vector2) -> void:
	pointer_button(px, true)
	pointer_button(px, false)
