extends CharacterBody3D
## Melee enemy that pathfinds to the player and attacks at close range.

signal died(enemy: Node)

@export var max_health := 60
@export var move_speed := 3.5
@export var attack_damage := 10
@export var attack_range := 1.8
@export var attack_cooldown := 1.0

## Set by the spawner before the enemy enters the tree.
var target: Node3D

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var body_mesh: MeshInstance3D = $Body
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var health: int
var _dead := false
var _attack_timer := 0.0
var _repath_timer := 0.0
var _material: StandardMaterial3D
var _base_color: Color


func _ready() -> void:
	health = max_health
	add_to_group("enemies")
	# Per-instance material so the hit flash only affects this enemy.
	_material = body_mesh.get_active_material(0).duplicate()
	body_mesh.material_override = _material
	_base_color = _material.albedo_color


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	if _dead:
		return

	_attack_timer = maxf(_attack_timer - delta, 0.0)
	var horizontal := Vector3.ZERO

	if is_instance_valid(target) and not target.is_dead:
		var to_target := target.global_position - global_position
		to_target.y = 0.0
		var distance := to_target.length()

		if distance > attack_range * 0.8:
			horizontal = _chase_direction(delta, to_target) * move_speed
		if distance > 0.05:
			look_at(global_position + to_target, Vector3.UP)
		if distance <= attack_range and _attack_timer == 0.0:
			_attack()

	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()


func _chase_direction(delta: float, to_target: Vector3) -> Vector3:
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = 0.25
		agent.target_position = target.global_position

	# Fall back to a straight line until the navmesh has a usable path.
	if agent.is_navigation_finished() or NavigationServer3D.map_get_iteration_id(agent.get_navigation_map()) == 0:
		return to_target.normalized()
	var next := agent.get_next_path_position() - global_position
	next.y = 0.0
	if next.length() < 0.01:
		return to_target.normalized()
	return next.normalized()


func _attack() -> void:
	_attack_timer = attack_cooldown
	target.take_damage(attack_damage)
	var tween := create_tween()
	tween.tween_property(body_mesh, "position:z", -0.35, 0.08)
	tween.tween_property(body_mesh, "position:z", 0.0, 0.2)


## Returns true if this hit killed the enemy.
func take_damage(amount: int) -> bool:
	if _dead:
		return false
	health -= amount
	_material.albedo_color = Color.WHITE
	create_tween().tween_property(_material, "albedo_color", _base_color, 0.15)
	if health <= 0:
		_die()
		return true
	return false


func _die() -> void:
	_dead = true
	velocity = Vector3.ZERO
	collision_shape.set_deferred("disabled", true)
	died.emit(self)
	var tween := create_tween().set_parallel()
	tween.tween_property(body_mesh, "scale", Vector3(1.3, 0.05, 1.3), 0.25)
	tween.tween_property(body_mesh, "position:y", 0.05, 0.25)
	tween.chain().tween_interval(0.5)
	tween.chain().tween_callback(queue_free)
