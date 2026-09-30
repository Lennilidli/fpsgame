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
@export var combat_move_factor := 0.55 ## Speed multiplier while winding up or blocking.

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


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for mesh in combat.weapon.find_children("*", "MeshInstance3D"):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	combat.defended.connect(_on_defended)


func _unhandled_input(event: InputEvent) -> void:
	if is_dead or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))
		_aim += event.relative
		_update_intended_dir()
	elif event.is_action_pressed("attack"):
		combat.start_windup(intended_dir)
	elif event.is_action_released("attack"):
		combat.release_attack()
	elif event.is_action_pressed("block"):
		combat.start_block(intended_dir)
	elif event.is_action_released("block"):
		combat.stop_block()


func _process(delta: float) -> void:
	_aim *= exp(-aim_decay * delta)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	var input_dir := Vector2.ZERO
	if not is_dead:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_velocity

	var speed := walk_speed
	match combat.state:
		MeleeCombat.State.WINDUP, MeleeCombat.State.BLOCK:
			speed *= combat_move_factor
		MeleeCombat.State.STAGGER:
			speed *= 0.3
		_:
			if Input.is_action_pressed("sprint") and input_dir.y < 0.0:
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


func _on_defended(result: MeleeCombat.Result, _attacker: MeleeCombat) -> void:
	if result == MeleeCombat.Result.HIT or result == MeleeCombat.Result.GUARD_BREAK:
		_shake_camera(0.08)
	elif result == MeleeCombat.Result.BLOCKED:
		_shake_camera(0.03)


func _shake_camera(strength: float) -> void:
	var tween := create_tween()
	for i in 4:
		tween.tween_property(camera, "h_offset", randf_range(-strength, strength), 0.03)
		tween.parallel().tween_property(camera, "v_offset", randf_range(-strength, strength), 0.03)
	tween.tween_property(camera, "h_offset", 0.0, 0.05)
	tween.parallel().tween_property(camera, "v_offset", 0.0, 0.05)
