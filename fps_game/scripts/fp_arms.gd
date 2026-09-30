extends Node3D
## First-person arms: armoured forearms and gauntlets gripping the view-model sword.
## Lives under the Camera3D; shoulders sit just below and behind the view, and two-bone
## IK reaches both hands to the sword's grip every frame.

const STEEL := preload("res://assets/materials/steel.tres")
const MAIL := preload("res://assets/materials/chainmail.tres")
const LEATHER := preload("res://assets/materials/leather.tres")

@export var weapon: Node3D
@export var upper_arm := 0.3
@export var forearm := 0.28
## Shoulder positions relative to the camera (x = right, -z = forward).
@export var shoulder_offset := Vector3(0.2, -0.3, 0.08)

var _arms := {} ## side -> [upper, fore, hand]


func _ready() -> void:
	for side in [-1, 1]:
		var up := _part()
		_mesh(up, _cylinder(0.06, 0.055, upper_arm), MAIL, Vector3(0.0, -upper_arm * 0.5, 0.0))
		var fore := _part()
		_mesh(fore, _sphere(0.055), STEEL, Vector3.ZERO)
		_mesh(fore, _cylinder(0.05, 0.042, forearm * 0.85), STEEL, Vector3(0.0, -forearm * 0.5, 0.0))
		var hand := _part()
		_mesh(hand, _box(Vector3(0.07, 0.095, 0.065)), STEEL, Vector3.ZERO)
		_mesh(hand, _cylinder(0.048, 0.043, 0.06), LEATHER, Vector3(0.0, -0.068, 0.0))
		_arms[side] = [up, fore, hand]


func _process(_delta: float) -> void:
	var visible_now: bool = weapon != null and weapon.is_visible_in_tree()
	for side in _arms:
		for part in _arms[side]:
			part.visible = visible_now
	if not visible_now:
		return
	var view := get_parent() as Node3D
	var up_axis: Vector3 = weapon.global_basis.y.normalized()
	for side in [-1, 1]:
		var shoulder := view.global_transform * Vector3(shoulder_offset.x * side, shoulder_offset.y, shoulder_offset.z)
		# Right hand just under the guard, left hand near the pommel.
		var target := weapon.global_transform * Vector3(0.0, 0.035 if side == 1 else -0.085, 0.0)
		var pole := view.global_basis * Vector3(side * 0.8, -0.8, 0.3)
		var parts: Array = _arms[side]
		KnightRig.solve_limb(parts[0], parts[1], shoulder, target, upper_arm, forearm, pole)
		var wrist: Vector3 = parts[1].global_transform * Vector3(0.0, -forearm, 0.0)
		parts[2].global_transform = Transform3D(KnightRig.basis_along(up_axis, -view.global_basis.z), wrist)


func _part() -> Node3D:
	var node := Node3D.new()
	node.top_level = true
	add_child(node)
	return node


func _mesh(parent: Node3D, mesh: Mesh, material: Material, position_: Vector3) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position_
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)


func _cylinder(top: float, bottom: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = 16
	return m


func _sphere(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 1.6
	return m


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m
