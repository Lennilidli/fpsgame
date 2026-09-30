extends CharacterBody3D
## First-person player: movement, mouse look, and directional melee input.
## The last direction the mouse moved picks the attack/block direction.

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

var _aim := Vector2.ZERO
var _look := Vector2.ZERO ## Mouse look waiting to be applied (radians).
var _camera_tween: Tween
var _shake_tween: Tween


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for mesh in combat.weapon.find_children("*", "MeshInstance3D"):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	combat.swing_started.connect(_on_swing_started)
	combat.attack_resolved.connect(_on_attack_resolved)
	combat.world_hit.connect(func(_point): _shake_camera(combat.profile.block_camera_shake))
	combat.defended.connect(_on_defended)


func _unhandled_input(event: InputEvent) -> void:
	if is_dead or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		_look += event.relative * mouse_sensitivity
		_aim += event.relative
		_update_intended_dir()
	# Inputs go through the combat buffer, so pressing during a swing queues the next action.
	elif event.is_action_pressed("attack"):
		combat.queue_windup(intended_dir)
	elif event.is_action_released("attack"):
		combat.queue_release()
	elif event.is_action_pressed("feint"):
		# Redirect toward the mouse's direction, or the next one clockwise if unchanged.
		var dir := intended_dir
		if dir == combat.feint_base_dir():
			dir = MeleeCombat.next_dir(dir)
		combat.feint_or_redirect(dir)
	elif event.is_action_pressed("block"):
		combat.queue_block(intended_dir)
	elif event.is_action_released("block"):
		combat.queue_block_release()


func _process(delta: float) -> void:
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
	if not is_on_floor():
		velocity.y -= gravity * delta

	var input_dir := Vector2.ZERO
	if not is_dead:
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
	combat.set_block_dir(dir)
	combat.update_queued_dir(dir)


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
		MeleeCombat.Result.BLOCKED, MeleeCombat.Result.PARRIED:
			_shake_camera(combat.profile.block_camera_shake)


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
