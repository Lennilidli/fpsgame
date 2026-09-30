extends CharacterBody3D
## First-person player: movement, mouse look, and directional melee input.
## The last direction the mouse moved picks the attack/block direction.
##
## In a network match every peer has a copy of each fighter. The owner (multiplayer
## authority) plays it in first person and sends its movement and combat inputs to the
## other peer, whose copy is a "remote" fighter: a visible body whose sword is sized to
## match the owner's hitbox exactly, driven by those inputs.

signal intended_dir_changed(dir: MeleeCombat.Dir)

@export_group("Movement")
@export var walk_speed := 5.0
@export var sprint_speed := 7.5
@export var ground_acceleration := 10.0
@export var air_acceleration := 3.0
@export var jump_velocity := 4.8
@export var mouse_sensitivity := 0.0025

@export_group("Direction input")
@export var aim_threshold := 6.0 ## Mouse travel (pixels) needed to change direction.
@export var aim_decay := 10.0 ## How fast old mouse movement is forgotten.

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var combat: MeleeCombat = $MeleeCombat

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var intended_dir := MeleeCombat.Dir.RIGHT
var is_dead: bool:
	get:
		return combat.is_dead()
## This copy belongs to the other player (network match).
var is_remote := false
## Blocks movement and combat input (round countdown).
var input_locked := false
## Send inputs and transform to the other peer (set once both are in the match).
var net_sync := false

var _aim := Vector2.ZERO
var _look := Vector2.ZERO ## Mouse look waiting to be applied (radians).
var _camera_tween: Tween
var _shake_tween: Tween
var _net_position := Vector3.ZERO
var _net_yaw := 0.0
var _net_pitch := 0.0


func _ready() -> void:
	is_remote = not is_multiplayer_authority()
	_net_position = global_position
	_net_yaw = rotation.y
	if is_remote:
		_setup_remote()
		return
	$Body.hide()
	$Head/WorldSword.hide()
	$Head/Visor.hide()
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for mesh in combat.weapon.find_children("*", "MeshInstance3D"):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	combat.swing_started.connect(_on_swing_started)
	combat.attack_resolved.connect(_on_attack_resolved)
	combat.world_hit.connect(func(_point): _shake_camera(combat.profile.block_camera_shake))
	combat.defended.connect(_on_defended)


func _unhandled_input(event: InputEvent) -> void:
	if is_remote or is_dead or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		_look += event.relative * mouse_sensitivity
		_aim += event.relative
		_update_intended_dir()
	elif input_locked:
		return
	# Inputs go through the combat buffer, so pressing during a swing queues the next action.
	elif event.is_action_pressed("attack"):
		_combat_input("windup", intended_dir)
	elif event.is_action_released("attack"):
		_combat_input("release", 0)
	elif event.is_action_pressed("feint"):
		# Redirect toward the mouse's direction, or the next one clockwise if unchanged.
		var dir := intended_dir
		if dir == combat.feint_base_dir():
			dir = MeleeCombat.next_dir(dir)
		_combat_input("feint", dir)
	elif event.is_action_pressed("block"):
		_combat_input("block", intended_dir)
	elif event.is_action_released("block"):
		_combat_input("unblock", 0)


## Applies a combat input locally and, in a network match, on the other peer's copy.
func _combat_input(action: String, dir: int) -> void:
	_apply_combat_input(action, dir)
	if net_sync:
		_net_combat_input.rpc(action, dir)


@rpc("authority", "call_remote", "reliable")
func _net_combat_input(action: String, dir: int) -> void:
	_apply_combat_input(action, dir)


func _apply_combat_input(action: String, dir: int) -> void:
	var d := dir as MeleeCombat.Dir
	match action:
		"windup":
			combat.queue_windup(d)
		"release":
			combat.queue_release()
		"feint":
			combat.feint_or_redirect(d)
		"block":
			combat.queue_block(d)
		"unblock":
			combat.queue_block_release()
		"aim":
			combat.set_block_dir(d)
			combat.update_queued_dir(d)


func _process(delta: float) -> void:
	if is_remote:
		_follow_network_state(delta)
		return
	_aim *= exp(-aim_decay * delta)
	_apply_look(delta)


## Applies mouse look, limited by the combat turn cap while attacking.
## Mouse movement beyond the cap is dropped, as in MO2.
func _apply_look(delta: float) -> void:
	var look := _look
	_look = Vector2.ZERO
	var cap := combat.turn_cap()
	if cap > 0.0:
		var max_step := cap * delta
		look = Vector2(clampf(look.x, -max_step, max_step), clampf(look.y, -max_step, max_step))
	rotate_y(-look.x)
	head.rotate_x(-look.y)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))


func _physics_process(delta: float) -> void:
	if is_remote:
		return
	if not is_on_floor():
		velocity.y -= gravity * delta

	var input_dir := Vector2.ZERO
	if not is_dead and not input_locked:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_velocity

	var speed := walk_speed * combat.move_multiplier()
	if combat.state == MeleeCombat.State.IDLE and Input.is_action_pressed("sprint") and input_dir.y < 0.0:
		speed = sprint_speed

	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var accel := ground_acceleration if is_on_floor() else air_acceleration
	var weight := clampf(accel * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, direction.x * speed, weight)
	velocity.z = lerpf(velocity.z, direction.z * speed, weight)
	move_and_slide()
	if net_sync:
		_net_transform.rpc(global_position, rotation.y, head.rotation.x)


func _update_intended_dir() -> void:
	if _aim.length() < aim_threshold:
		return
	var dir: MeleeCombat.Dir
	if absf(_aim.x) > absf(_aim.y):
		dir = MeleeCombat.Dir.RIGHT if _aim.x > 0.0 else MeleeCombat.Dir.LEFT
	else:
		dir = MeleeCombat.Dir.OVERHEAD if _aim.y < 0.0 else MeleeCombat.Dir.THRUST
	if dir == intended_dir:
		return
	intended_dir = dir
	intended_dir_changed.emit(dir)
	_combat_input("aim", dir)


# --- Network ---------------------------------------------------------------

## The other player's copy: third-person body, world-scale sword, no camera or input.
func _setup_remote() -> void:
	camera.current = false
	$Head/Camera3D/Sword.hide()
	$KnightRig.show()
	$Head/Visor.hide()
	$Head/WorldSword.show()
	$Head/Camera3D/FPArms.hide()
	combat.died.connect($KnightRig.collapse)
	combat.defended.connect(func(result, attacker) -> void:
		if result == MeleeCombat.Result.HIT or result == MeleeCombat.Result.GUARD_BREAK:
			$KnightRig.hit_react(attacker.attack_dir, clampf(attacker.last_swing_damage / 30.0, 0.6, 1.5)))
	# The world sword is stretched along the blade by the same factor as the owner's
	# first-person hitbox, so the blade you see is exactly the blade that can hit you.
	combat.set_weapon($Head/WorldSword, 1.0)
	add_to_group("enemies")


@rpc("authority", "call_remote", "unreliable_ordered")
func _net_transform(position_: Vector3, yaw: float, pitch: float) -> void:
	_net_position = position_
	_net_yaw = yaw
	_net_pitch = pitch


func _follow_network_state(delta: float) -> void:
	var weight := 1.0 - exp(-25.0 * delta)
	global_position = global_position.lerp(_net_position, weight)
	rotation.y = lerp_angle(rotation.y, _net_yaw, weight)
	head.rotation.x = lerpf(head.rotation.x, _net_pitch, weight)


## Puts the fighter back at a spawn point with full health (new round).
func reset_for_round(spawn: Transform3D) -> void:
	combat.reset()
	$KnightRig.revive()
	global_transform = spawn
	velocity = Vector3.ZERO
	head.rotation.x = 0.0
	_look = Vector2.ZERO
	_net_position = spawn.origin
	_net_yaw = rotation.y
	_net_pitch = 0.0


func set_body_color(color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.6
	$Body.material_override = material
	$KnightRig.set_team_color(color)


# --- Camera feel -----------------------------------------------------------

## Leans the camera with the swing so it feels like the body is behind it.
func _on_swing_started(dir: MeleeCombat.Dir) -> void:
	var amount := deg_to_rad(combat.profile.swing_camera_roll)
	var target := Vector3.ZERO
	match dir:
		MeleeCombat.Dir.LEFT:
			target.z = -amount
		MeleeCombat.Dir.RIGHT:
			target.z = amount
		MeleeCombat.Dir.OVERHEAD:
			target.x = -amount
		MeleeCombat.Dir.THRUST:
			target.x = -amount * 0.4
	var duration: float = combat.time_to_impact()
	if _camera_tween:
		_camera_tween.kill()
	_camera_tween = create_tween()
	_camera_tween.tween_property(camera, "rotation", target, maxf(duration, 0.05)).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	_camera_tween.tween_property(camera, "rotation", Vector3.ZERO, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)


func _on_attack_resolved(result: MeleeCombat.Result, _target: MeleeCombat) -> void:
	match result:
		MeleeCombat.Result.HIT, MeleeCombat.Result.GUARD_BREAK:
			_shake_camera(combat.profile.hit_camera_shake)
			_kick_camera(combat.attack_dir)
		MeleeCombat.Result.BLOCKED, MeleeCombat.Result.PARRIED:
			_shake_camera(combat.profile.block_camera_shake)


## Jolts the view in the swing's direction when a hit lands, on top of the swing lean.
func _kick_camera(dir: MeleeCombat.Dir) -> void:
	var kick := deg_to_rad(combat.profile.hit_camera_kick)
	var offset := Vector3.ZERO
	match dir:
		MeleeCombat.Dir.LEFT:
			offset.z = -kick
		MeleeCombat.Dir.RIGHT:
			offset.z = kick
		MeleeCombat.Dir.OVERHEAD:
			offset.x = -kick
		MeleeCombat.Dir.THRUST:
			offset.x = -kick * 0.4
	if _camera_tween:
		_camera_tween.kill()
	_camera_tween = create_tween()
	_camera_tween.tween_property(camera, "rotation", camera.rotation + offset, 0.04).set_ease(Tween.EASE_OUT)
	_camera_tween.tween_interval(combat.current_hit_stop())
	_camera_tween.tween_property(camera, "rotation", Vector3.ZERO, 0.4).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)


func _on_defended(result: MeleeCombat.Result, _attacker: MeleeCombat) -> void:
	if result == MeleeCombat.Result.HIT or result == MeleeCombat.Result.GUARD_BREAK:
		_shake_camera(combat.profile.hit_camera_shake * 1.5)
	elif result == MeleeCombat.Result.BLOCKED:
		_shake_camera(combat.profile.block_camera_shake)


func _shake_camera(strength: float) -> void:
	if strength <= 0.0:
		return
	if _shake_tween:
		_shake_tween.kill()
	_shake_tween = create_tween()
	for i in 4:
		_shake_tween.tween_property(camera, "h_offset", randf_range(-strength, strength), 0.03)
		_shake_tween.parallel().tween_property(camera, "v_offset", randf_range(-strength, strength), 0.03)
	_shake_tween.tween_property(camera, "h_offset", 0.0, 0.05)
	_shake_tween.parallel().tween_property(camera, "v_offset", 0.0, 0.05)
