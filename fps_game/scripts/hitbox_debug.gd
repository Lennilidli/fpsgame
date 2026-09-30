extends MeshInstance3D
## Draws every fighter's blade hitbox and body hurtbox as lines (training debug view).
## Blade colors: yellow = striking, blue = blocking, grey = inactive.

const COLOR_STRIKE := Color(1.0, 0.85, 0.2)
const COLOR_BLOCK := Color(0.35, 0.65, 1.0)
const COLOR_IDLE := Color(0.7, 0.7, 0.7, 0.6)
const COLOR_BODY := Color(0.3, 1.0, 0.4, 0.6)
const CIRCLE_SEGMENTS := 16

var _lines := ImmediateMesh.new()


func _ready() -> void:
	mesh = _lines
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = material


func _process(_delta: float) -> void:
	_lines.clear_surfaces()
	if not visible:
		return
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for node in get_tree().get_nodes_in_group("combatants"):
		var combat := node as MeleeCombat
		if combat == null or combat.is_dead() or combat.weapon == null:
			continue
		var blade := combat.hitbox_segment()
		var color := COLOR_IDLE
		if combat.state == MeleeCombat.State.SWING:
			color = COLOR_STRIKE
		elif combat.state == MeleeCombat.State.BLOCK:
			color = COLOR_BLOCK
		_line(blade[0], blade[1], color)
		var hurt := combat.hurtbox()
		if not hurt.is_empty():
			_capsule(hurt[0], hurt[1], hurt[2])
	_lines.surface_end()


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(a)
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(b)


func _capsule(bottom: Vector3, top: Vector3, radius: float) -> void:
	for center in [bottom, (bottom + top) * 0.5, top]:
		for i in CIRCLE_SEGMENTS:
			var a := TAU * i / CIRCLE_SEGMENTS
			var b := TAU * (i + 1) / CIRCLE_SEGMENTS
			_line(center + Vector3(cos(a), 0.0, sin(a)) * radius, center + Vector3(cos(b), 0.0, sin(b)) * radius, COLOR_BODY)
	for offset in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		_line(bottom + offset * radius, top + offset * radius, COLOR_BODY)
