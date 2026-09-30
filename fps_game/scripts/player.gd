extends CharacterBody3D
## First-person player: movement, mouse look, and a hitscan rifle.

signal health_changed(current: int, maximum: int)
signal ammo_changed(in_mag: int, reserve: int)
signal reloading_changed(is_reloading: bool)
signal damaged
signal hit_confirmed(killed: bool)
signal died

@export_group("Movement")
@export var walk_speed := 6.0
@export var sprint_speed := 9.5
@export var ground_acceleration := 12.0
@export var air_acceleration := 3.0
@export var jump_velocity := 5.2
@export var mouse_sensitivity := 0.0025

@export_group("Health")
@export var max_health := 100

@export_group("Weapon")
@export var damage := 25
@export var fire_rate := 8.0 ## Shots per second.
@export var mag_size := 20
@export var reserve_ammo := 100
@export var reload_time := 1.4
@export var weapon_range := 100.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var ray: RayCast3D = $Head/Camera3D/RayCast3D
@onready var gun: Node3D = $Head/Camera3D/Gun
@onready var muzzle_flash: OmniLight3D = $Head/Camera3D/Gun/MuzzleFlash

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var health: int
var ammo_in_mag: int
var is_reloading := false
var is_dead := false

var _fire_cooldown := 0.0
var _gun_rest_position: Vector3
var _bob_time := 0.0
var _impact_mesh: SphereMesh
var _impact_world_material: StandardMaterial3D
var _impact_enemy_material: StandardMaterial3D


func _ready() -> void:
	health = max_health
	ammo_in_mag = mag_size
	_gun_rest_position = gun.position
	muzzle_flash.visible = false
	ray.target_position = Vector3(0, 0, -weapon_range)
	ray.add_exception(self)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_impact_mesh = SphereMesh.new()
	_impact_mesh.radius = 0.05
	_impact_mesh.height = 0.1
	_impact_world_material = _make_unshaded(Color(1.0, 0.85, 0.4))
	_impact_enemy_material = _make_unshaded(Color(1.0, 0.2, 0.1))


## Re-sends all state signals so a freshly connected HUD can sync up.
func emit_state() -> void:
	health_changed.emit(health, max_health)
	ammo_changed.emit(ammo_in_mag, reserve_ammo)
	reloading_changed.emit(is_reloading)


func _unhandled_input(event: InputEvent) -> void:
	if is_dead:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))
	elif event.is_action_pressed("reload"):
		start_reload()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if is_dead:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		move_and_slide()
		return

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var sprinting := Input.is_action_pressed("sprint") and input_dir.y < 0.0
	var target_velocity := direction * (sprint_speed if sprinting else walk_speed)
	var accel := ground_acceleration if is_on_floor() else air_acceleration
	var weight := clampf(accel * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, target_velocity.x, weight)
	velocity.z = lerpf(velocity.z, target_velocity.z, weight)

	move_and_slide()
	_update_weapon(delta)


func _process(delta: float) -> void:
	# Weapon bob while moving on the ground, then ease the gun back to rest (undoes recoil).
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var bob := Vector3.ZERO
	if is_on_floor() and horizontal_speed > 0.5:
		_bob_time += delta * horizontal_speed * 1.6
		bob = Vector3(cos(_bob_time * 0.5) * 0.012, absf(sin(_bob_time * 0.5)) * 0.015, 0.0)
	gun.position = gun.position.lerp(_gun_rest_position + bob, clampf(12.0 * delta, 0.0, 1.0))


func _update_weapon(delta: float) -> void:
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or is_reloading:
		return
	if Input.is_action_pressed("shoot") and _fire_cooldown == 0.0:
		if ammo_in_mag > 0:
			_shoot()
		else:
			start_reload()


func _shoot() -> void:
	_fire_cooldown = 1.0 / fire_rate
	ammo_in_mag -= 1
	ammo_changed.emit(ammo_in_mag, reserve_ammo)

	# Recoil: kick the gun back and the view up a little.
	gun.position.z += 0.08
	head.rotation.x = clampf(head.rotation.x + 0.008, deg_to_rad(-89.0), deg_to_rad(89.0))
	_flash_muzzle()

	ray.force_raycast_update()
	if not ray.is_colliding():
		return
	var collider := ray.get_collider()
	var hit_enemy := collider != null and collider.has_method("take_damage")
	if hit_enemy:
		var killed: bool = collider.take_damage(damage)
		hit_confirmed.emit(killed)
	_spawn_impact(ray.get_collision_point(), ray.get_collision_normal(), hit_enemy)


func start_reload() -> void:
	if is_reloading or is_dead or ammo_in_mag == mag_size or reserve_ammo == 0:
		return
	is_reloading = true
	reloading_changed.emit(true)

	var tween := create_tween()
	tween.tween_property(gun, "rotation:x", deg_to_rad(-35.0), reload_time * 0.3)
	tween.tween_interval(reload_time * 0.4)
	tween.tween_property(gun, "rotation:x", 0.0, reload_time * 0.3)
	await tween.finished
	if is_dead:
		return

	var taken := mini(mag_size - ammo_in_mag, reserve_ammo)
	ammo_in_mag += taken
	reserve_ammo -= taken
	is_reloading = false
	reloading_changed.emit(false)
	ammo_changed.emit(ammo_in_mag, reserve_ammo)


## Returns true if this hit killed the player.
func take_damage(amount: int) -> bool:
	if is_dead:
		return false
	health = maxi(health - amount, 0)
	health_changed.emit(health, max_health)
	damaged.emit()
	if health == 0:
		is_dead = true
		died.emit()
		return true
	return false


func heal(amount: int) -> void:
	if is_dead:
		return
	health = mini(health + amount, max_health)
	health_changed.emit(health, max_health)


func add_ammo(amount: int) -> void:
	reserve_ammo += amount
	ammo_changed.emit(ammo_in_mag, reserve_ammo)


func _flash_muzzle() -> void:
	muzzle_flash.visible = true
	await get_tree().create_timer(0.04).timeout
	muzzle_flash.visible = false


func _spawn_impact(point: Vector3, normal: Vector3, on_enemy: bool) -> void:
	var impact := MeshInstance3D.new()
	impact.mesh = _impact_mesh
	impact.material_override = _impact_enemy_material if on_enemy else _impact_world_material
	impact.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(impact)
	impact.global_position = point + normal * 0.02
	var tween := impact.create_tween()
	tween.tween_property(impact, "scale", Vector3.ZERO, 1.5).set_delay(0.3)
	tween.tween_callback(impact.queue_free)


func _make_unshaded(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material
