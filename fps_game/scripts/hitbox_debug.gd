extends MeshInstance3D
## Draws every fighter's weapon zones and body zones as lines (training debug view).
## Weapon: handle grey, forte blue, middle yellow, tip (sweet spot) red; brighter while
## striking. Body: head red, torso green, legs cyan.

const WEAPON_COLORS := {
	"handle": Color(0.6, 0.6, 0.6),
	"forte": Color(0.35, 0.6, 1.0),
	"middle": Color(1.0, 0.85, 0.2),
	"tip": Color(1.0, 0.25, 0.2),
}
const BODY_COLORS := {
	"head": Color(1.0, 0.35, 0.3, 0.7),
	"torso": Color(0.3, 1.0, 0.4, 0.6),
	"legs": Color(0.3, 0.9, 1.0, 0.6),
}
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
		var alpha := 1.0 if combat.state == MeleeCombat.State.SWING else 0.45
		for zone in combat.weapon_zones():
			var from: Vector3 = blade[0] + (blade[1] - blade[0]) * float(zone[1])
			var to: Vector3 = blade[0] + (blade[1] - blade[0]) * float(zone[2])
			var color: Color = WEAPON_COLORS[zone[0]]
			color.a = alpha
			_line(from, to, color)
		for zone in combat.body_zones():
			_capsule(zone[1], zone[2], zone[3], BODY_COLORS[zone[0]])
	_lines.surface_end()


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(a)
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(b)


func _capsule(bottom: Vector3, top: Vector3, radius: float, color: Color) -> void:
	for center in [bottom, top]:
		for i in CIRCLE_SEGMENTS:
			var a := TAU * i / CIRCLE_SEGMENTS
			var b := TAU * (i + 1) / CIRCLE_SEGMENTS
			_line(center + Vector3(cos(a), 0.0, sin(a)) * radius, center + Vector3(cos(b), 0.0, sin(b)) * radius, color)
	for offset in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		_line(bottom + offset * radius, top + offset * radius, color)
	# Caps: a vertical ring through the top and bottom so the rounded ends are visible.
	_line(top + Vector3.UP * radius, top + Vector3.RIGHT * radius, color)
	_line(top + Vector3.UP * radius, top + Vector3.LEFT * radius, color)
	_line(bottom + Vector3.DOWN * radius, bottom + Vector3.RIGHT * radius, color)
	_line(bottom + Vector3.DOWN * radius, bottom + Vector3.LEFT * radius, color)
