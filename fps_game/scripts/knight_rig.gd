class_name KnightRig
extends Node3D
## Procedurally animated armoured knight made of rigid plate pieces.
##
## Purely visual: the combat system still owns the sword, its poses and its hitbox. This
## rig follows it: both hands grip the sword via two-bone IK, the torso twists and leans
## into the weapon, the head follows the aim pitch, and the legs step when the body moves.
## Place it at the character's origin (feet at y = 0, facing -Z).

const STEEL := preload("res://assets/materials/steel.tres")
const MAIL := preload("res://assets/materials/chainmail.tres")
const LEATHER := preload("res://assets/materials/leather.tres")

## The sword to hold (a sword.tscn instance). Grip positions are read from it every frame.
@export var weapon: Node3D
## Optional node whose X rotation is the aim pitch (a player's Head).
@export var look_node: Node3D
@export var tabard_color := Color(0.55, 0.1, 0.08)

@export_group("Proportions")
@export var pelvis_height := 0.95
@export var shoulder_height := 1.45
@export var shoulder_width := 0.2
@export var hip_width := 0.11
@export var upper_arm := 0.32
@export var forearm := 0.3
@export var thigh := 0.46
@export var shin := 0.44

@export_group("Motion")
@export var step_length := 0.35
@export var step_time := 0.22
@export var step_height := 0.09
@export var max_twist := 40.0 ## Degrees the torso may twist toward the weapon.

var _pelvis: Node3D
var _torso: Node3D
var _head: Node3D
var _tabard_material: StandardMaterial3D
var _arms := {} ## side (-1 left, 1 right) -> [upper, fore, hand]
var _legs := {} ## side -> [thigh, shin, foot]
var _feet := {} ## side -> {planted: Vector3, from: Vector3, to: Vector3, t: float}
var _last_position := Vector3.ZERO
var _velocity := Vector3.ZERO
var _twist := 0.0
var _lean := 0.0
var _flinch := Vector3.ZERO
var _dead := false


func _ready() -> void:
	_build()
	_last_position = global_position
	for side in [-1, 1]:
		var foot := _foot_rest(side)
		_feet[side] = {"planted": foot, "from": foot, "to": foot, "t": 1.0}


func set_team_color(color: Color) -> void:
	tabard_color = color
	if _tabard_material:
		_tabard_material.albedo_color = color


## Short flinch away from a hit from `dir` (MeleeCombat.Dir), scaled by `strength`.
func hit_react(dir: int, strength: float) -> void:
	match dir:
		MeleeCombat.Dir.OVERHEAD:
			_flinch = Vector3(deg_to_rad(-14.0), 0.0, 0.0) * strength
		MeleeCombat.Dir.THRUST:
			_flinch = Vector3(deg_to_rad(16.0), 0.0, 0.0) * strength
		MeleeCombat.Dir.LEFT:
			_flinch = Vector3(0.0, deg_to_rad(-12.0), deg_to_rad(14.0)) * strength
		MeleeCombat.Dir.RIGHT:
			_flinch = Vector3(0.0, deg_to_rad(12.0), deg_to_rad(-14.0)) * strength


## Collapses the body (death). `revive()` stands it back up.
func collapse() -> void:
	if _dead:
		return
	_dead = true
	var tween := create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "rotation:x", deg_to_rad(80.0), 0.55)
	tween.tween_property(self, "position:y", 0.25, 0.55)


func revive() -> void:
	_dead = false
	rotation.x = 0.0
	position.y = 0.0


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	var moved := global_position - _last_position
	moved.y = 0.0
	_last_position = global_position
	_velocity = _velocity.lerp(moved / delta, clampf(10.0 * delta, 0.0, 1.0))
	_flinch = _flinch.lerp(Vector3.ZERO, clampf(8.0 * delta, 0.0, 1.0))
	_update_body(delta)
	if not _dead:
		_update_legs(delta)
	_update_arms()


# --- Body --------------------------------------------------------------------

func _update_body(delta: float) -> void:
	# Twist and lean the torso toward where the sword is held.
	var target_twist := 0.0
	var target_lean := 0.0
	if weapon and weapon.is_visible_in_tree():
		var local := global_transform.affine_inverse() * _grip(0.0)
		target_twist = clampf(atan2(-local.x, -local.z) * 0.5, -deg_to_rad(max_twist), deg_to_rad(max_twist))
		target_lean = clampf((-local.z - 0.4) * 0.35, -0.1, 0.25)
	var weight := clampf(12.0 * delta, 0.0, 1.0)
	_twist = lerpf(_twist, target_twist, weight)
	_lean = lerpf(_lean, target_lean, weight)

	var speed := _velocity.length()
	var bob := sin(Time.get_ticks_msec() * 0.012) * 0.015 * clampf(speed / 3.0, 0.0, 1.0)
	_pelvis.position = Vector3(0.0, pelvis_height - 0.04 * clampf(speed / 3.0, 0.0, 1.0) + bob, 0.0)
	_pelvis.rotation = Vector3(0.0, _twist * 0.35, 0.0)
	_torso.rotation = Vector3(-_lean + _flinch.x, _twist * 0.65 + _flinch.y, _flinch.z)
	var pitch := look_node.rotation.x if look_node else 0.0
	_head.rotation = Vector3(clampf(pitch, -0.6, 0.6) * 0.8, -_twist * 0.5, 0.0)


# --- Arms --------------------------------------------------------------------

func _update_arms() -> void:
	var holding: bool = weapon != null and weapon.is_visible_in_tree()
	for side in [-1, 1]:
		var shoulder := _torso.global_transform * Vector3(side * shoulder_width, shoulder_height - pelvis_height - 0.1, 0.0)
		var target: Vector3
		var hand_up: Vector3
		if holding:
			# Right hand just under the guard, left hand near the pommel.
			target = _grip(0.035 if side == 1 else -0.085)
			hand_up = weapon.global_basis.y.normalized()
		else:
			target = global_transform * Vector3(side * 0.25, 0.9, -0.05)
			hand_up = global_basis.y
		var pole := _torso.global_basis * Vector3(side * 0.6, -0.6, 0.4)
		var parts: Array = _arms[side]
		solve_limb(parts[0], parts[1], shoulder, target, upper_arm, forearm, pole)
		var hand: Node3D = parts[2]
		var wrist: Vector3 = parts[1].global_transform * Vector3(0.0, -forearm, 0.0)
		hand.global_transform = Transform3D(basis_along(hand_up, -_torso.global_basis.z), wrist)


## A point on the sword's grip axis (local Y offset from the grip centre), in world space.
func _grip(offset: float) -> Vector3:
	return weapon.global_transform * Vector3(0.0, offset, 0.0)


# --- Legs --------------------------------------------------------------------

func _update_legs(delta: float) -> void:
	# Faster steps at higher speed; the next foot may lift once the other is half-way
	# through its step, so walking overlaps like a real gait instead of stretching.
	var speed := _velocity.length()
	var duration := clampf(step_time - speed * 0.03, 0.13, step_time)
	var busy := false
	for side in [-1, 1]:
		busy = busy or _feet[side]["t"] < 0.5
	for side in [-1, 1]:
		var foot: Dictionary = _feet[side]
		if foot["t"] < 1.0:
			foot["t"] = minf(foot["t"] + delta / duration, 1.0)
			var p: Vector3 = foot["from"].lerp(foot["to"], smoothstep(0.0, 1.0, foot["t"]))
			p.y += sin(foot["t"] * PI) * step_height
			foot["planted"] = p
		elif not busy:
			# Step when the body has moved away from this foot, landing ahead of it.
			var goal := _foot_rest(side) + _velocity * duration * 1.6
			goal.y = global_position.y
			if foot["planted"].distance_to(goal) > step_length * 0.5:
				foot["from"] = foot["planted"]
				foot["to"] = goal
				foot["t"] = 0.0
				busy = true
	for side in [-1, 1]:
		var hip := _pelvis.global_transform * Vector3(side * hip_width, -0.05, 0.0)
		var ankle: Vector3 = _feet[side]["planted"] + Vector3(0.0, 0.08, 0.0)
		var pole := global_basis * Vector3(side * 0.1, 0.0, -1.0)
		var parts: Array = _legs[side]
		solve_limb(parts[0], parts[1], hip, ankle, thigh, shin, pole)
		var foot_node: Node3D = parts[2]
		var heel: Vector3 = parts[1].global_transform * Vector3(0.0, -shin, 0.0)
		foot_node.global_transform = Transform3D(global_basis, heel)


## Neutral stance: left foot slightly forward (fighting stance).
func _foot_rest(side: int) -> Vector3:
	return global_transform * Vector3(side * 0.16, 0.0, 0.12 * side)


# --- IK ----------------------------------------------------------------------

## Points `upper` from `root` to the knee/elbow and `lower` from there to `target`.
## Both segments hang along their local -Y. Unreachable targets are clamped to full reach.
static func solve_limb(upper: Node3D, lower: Node3D, root: Vector3, target: Vector3, a: float, b: float, pole: Vector3) -> void:
	var to_target := target - root
	var distance := clampf(to_target.length(), 0.01, (a + b) * 0.999)
	var dir := to_target.normalized() if to_target.length() > 0.001 else Vector3.DOWN
	# Law of cosines: angle at the root between the limb axis and the upper segment.
	var cos_a := clampf((a * a + distance * distance - b * b) / (2.0 * a * distance), -1.0, 1.0)
	var bend_axis := dir.cross(pole).normalized()
	if bend_axis.length() < 0.001:
		bend_axis = dir.cross(Vector3.RIGHT).normalized()
	var upper_dir := dir.rotated(bend_axis, acos(cos_a))
	var joint := root + upper_dir * a
	var end := root + dir * distance
	upper.global_transform = Transform3D(basis_along(-upper_dir, pole), root)
	lower.global_transform = Transform3D(basis_along(-(end - joint).normalized(), pole), joint)


## Basis whose +Y is `up` and whose -Z faces `forward` as closely as possible.
static func basis_along(up: Vector3, forward: Vector3) -> Basis:
	var y := up.normalized()
	var x := y.cross(-forward).normalized()
	if x.length() < 0.001:
		x = y.cross(Vector3.FORWARD).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


# --- Construction --------------------------------------------------------------

func _build() -> void:
	_tabard_material = StandardMaterial3D.new()
	_tabard_material.albedo_color = tabard_color
	_tabard_material.roughness = 0.9
	_tabard_material.normal_enabled = true
	_tabard_material.normal_texture = LEATHER.normal_texture
	_tabard_material.uv1_triplanar = true
	_tabard_material.uv1_scale = Vector3(3, 3, 3)

	_pelvis = _node(self, "Pelvis", Vector3(0.0, pelvis_height, 0.0))
	# Faulds (skirt of plates) with a belt, and the tabard front and back.
	_mesh(_pelvis, _cylinder(0.17, 0.21, 0.24), STEEL, Vector3(0.0, -0.08, 0.0))
	_mesh(_pelvis, _torus(0.16, 0.185), LEATHER, Vector3(0.0, 0.03, 0.0))
	_mesh(_pelvis, _box(Vector3(0.26, 0.5, 0.02)), _tabard_material, Vector3(0.0, -0.2, -0.2))
	_mesh(_pelvis, _box(Vector3(0.26, 0.5, 0.02)), _tabard_material, Vector3(0.0, -0.2, 0.2))

	_torso = _node(_pelvis, "Torso", Vector3(0.0, 0.05, 0.0))
	# Chainmail body, breastplate and backplate, tabard over the chest.
	_mesh(_torso, _capsule(0.19, 0.6), MAIL, Vector3(0.0, 0.25, 0.0))
	_mesh(_torso, _sphere(0.21, 0.26), STEEL, Vector3(0.0, 0.3, -0.03), Vector3(1.0, 1.35, 0.85))
	_mesh(_torso, _box(Vector3(0.3, 0.34, 0.02)), _tabard_material, Vector3(0.0, 0.18, -0.215))
	# Pauldrons.
	for side in [-1, 1]:
		_mesh(_torso, _sphere(0.11, 0.14), STEEL, Vector3(side * (shoulder_width + 0.02), shoulder_height - pelvis_height - 0.07, 0.0), Vector3(1.1, 0.8, 1.0))
	# Gorget and great helm with a dark eye slit and breaths.
	_mesh(_torso, _cylinder(0.085, 0.11, 0.1), STEEL, Vector3(0.0, 0.52, 0.0))
	_head = _node(_torso, "Head", Vector3(0.0, 0.6, 0.0))
	_mesh(_head, _cylinder(0.115, 0.12, 0.28), STEEL, Vector3(0.0, 0.1, 0.0))
	_mesh(_head, _sphere(0.115, 0.08), STEEL, Vector3(0.0, 0.24, 0.0), Vector3(1.0, 0.6, 1.0))
	var slit := StandardMaterial3D.new()
	slit.albedo_color = Color(0.02, 0.02, 0.02)
	_mesh(_head, _box(Vector3(0.16, 0.018, 0.02)), slit, Vector3(0.0, 0.14, -0.115))
	_mesh(_head, _box(Vector3(0.012, 0.18, 0.03)), STEEL, Vector3(0.0, 0.06, -0.118))

	for side in [-1, 1]:
		var up := _limb("UpperArm", upper_arm)
		_mesh(up, _capsule(0.055, upper_arm + 0.05), MAIL, Vector3(0.0, -upper_arm * 0.5, 0.0))
		_mesh(up, _cylinder(0.058, 0.052, upper_arm * 0.6), STEEL, Vector3(0.0, -upper_arm * 0.55, 0.0))
		var fore := _limb("Forearm", forearm)
		_mesh(fore, _sphere(0.058, 0.09), STEEL, Vector3.ZERO) # couter (elbow)
		_mesh(fore, _cylinder(0.052, 0.043, forearm * 0.8), STEEL, Vector3(0.0, -forearm * 0.5, 0.0))
		var hand := _node(self, "Hand", Vector3.ZERO)
		hand.top_level = true
		_mesh(hand, _box(Vector3(0.075, 0.1, 0.07)), STEEL, Vector3(0.0, 0.0, 0.0))
		_mesh(hand, _cylinder(0.05, 0.045, 0.06), LEATHER, Vector3(0.0, -0.07, 0.0))
		_arms[side] = [up, fore, hand]

		var th := _limb("Thigh", thigh)
		_mesh(th, _capsule(0.08, thigh + 0.04), MAIL, Vector3(0.0, -thigh * 0.5, 0.0))
		_mesh(th, _cylinder(0.085, 0.07, thigh * 0.7), STEEL, Vector3(0.0, -thigh * 0.45, -0.01))
		var sh := _limb("Shin", shin)
		_mesh(sh, _sphere(0.07, 0.1), STEEL, Vector3(0.0, 0.0, -0.02)) # poleyn (knee)
		_mesh(sh, _cylinder(0.062, 0.05, shin * 0.85), STEEL, Vector3(0.0, -shin * 0.5, 0.0))
		var foot := _node(self, "Foot", Vector3.ZERO)
		foot.top_level = true
		_mesh(foot, _box(Vector3(0.1, 0.07, 0.27)), STEEL, Vector3(0.0, -0.045, -0.06))
		_legs[side] = [th, sh, foot]


func _limb(name_: String, _length: float) -> Node3D:
	var node := _node(self, name_, Vector3.ZERO)
	node.top_level = true
	return node


func _node(parent: Node, name_: String, position_: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = name_
	node.position = position_
	parent.add_child(node)
	return node


func _mesh(parent: Node3D, mesh: Mesh, material: Material, position_: Vector3, scale_ := Vector3.ONE) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position_
	instance.scale = scale_
	parent.add_child(instance)
	return instance


func _cylinder(top: float, bottom: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = 16
	return m


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = maxf(height, radius * 2.0)
	m.radial_segments = 16
	return m


func _sphere(radius: float, height: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = height * 2.0
	m.radial_segments = 16
	m.rings = 8
	return m


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _torus(inner: float, outer: float) -> TorusMesh:
	var m := TorusMesh.new()
	m.inner_radius = inner
	m.outer_radius = outer
	return m
