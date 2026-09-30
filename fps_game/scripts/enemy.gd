extends CharacterBody3D
## Melee duelist AI. Closes distance, circles at sword range, reads the player's
## windups to block or parry, attacks around the player's block, and sometimes feints.

signal died(enemy: Node)

@export var move_speed := 3.2
@export var engage_distance := 2.1
@export var max_simultaneous_attackers := 2

@export_group("Skill")
@export_range(0, 1) var block_chance := 0.3 ## Chance to block the right direction.
@export_range(0, 1) var parry_chance := 0.08 ## Chance a correct block is timed as a parry.
@export_range(0, 1) var read_block_chance := 0.3 ## Chance to attack around the player's block.
@export_range(0, 1) var feint_chance := 0.05
@export var reaction_time := 0.35
@export var attack_cooldown := Vector2(0.8, 1.8) ## Random pause between attacks.

## Set by the spawner before the enemy enters the tree.
var target: Node3D

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var body_mesh: MeshInstance3D = $Body
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var combat: MeleeCombat = $MeleeCombat

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _target_combat: MeleeCombat
var _material: StandardMaterial3D
var _base_color: Color
var _repath_timer := 0.0
var _strafe_sign := 1.0
var _strafe_timer := 0.0
var _attack_timer := 0.0
var _hold_time := 0.0
var _feint_next := false
var _reacting := false
var _reaction_timer := 0.0
var _block_choice := MeleeCombat.Dir.OVERHEAD
var _will_block := false
var _parry_attempted := false
var _block_release_timer := 0.0


func _ready() -> void:
	add_to_group("enemies")
	_material = body_mesh.get_active_material(0).duplicate()
	body_mesh.material_override = _material
	_base_color = _material.albedo_color
	_target_combat = target.get_node("MeleeCombat")
	_attack_timer = randf_range(1.0, 2.0)
	combat.defended.connect(_on_defended)
	combat.died.connect(_on_died)


func apply_difficulty(wave: int) -> void:
	var w := float(wave - 1)
	block_chance = minf(0.3 + 0.07 * w, 0.8)
	parry_chance = minf(0.08 + 0.04 * w, 0.4)
	read_block_chance = minf(0.3 + 0.06 * w, 0.75)
	feint_chance = minf(0.05 + 0.03 * w, 0.3)
	reaction_time = maxf(0.35 - 0.02 * w, 0.18)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	if combat.is_dead():
		return

	var horizontal := Vector3.ZERO
	if is_instance_valid(_target_combat) and not _target_combat.is_dead():
		var to_target := target.global_position - global_position
		to_target.y = 0.0
		var distance := to_target.length()
		_face(to_target, delta)
		_think(delta, distance)
		horizontal = _movement(delta, to_target, distance)
	else:
		combat.stop_block()

	var bonus := combat.movement_bonus()
	velocity.x = horizontal.x + bonus.x
	velocity.z = horizontal.z + bonus.z
	move_and_slide()


# --- Decision making -------------------------------------------------------

func _think(delta: float, distance: float) -> void:
	_attack_timer -= delta
	_defend(delta, distance)
	_attack(delta, distance)


func _defend(delta: float, distance: float) -> void:
	var threatened := _target_combat.is_attacking() and distance < 4.0
	if threatened:
		if not _reacting:
			# New incoming attack: decide now, act after the reaction delay.
			_reacting = true
			_parry_attempted = false
			_reaction_timer = reaction_time * randf_range(0.8, 1.3)
			# Either block correctly, guess a random direction, or don't block at all.
			_will_block = randf() < block_chance or randf() < 0.5
			if randf() < block_chance:
				_block_choice = MeleeCombat.required_block(_target_combat.attack_dir)
			else:
				_block_choice = _random_dir()
		_reaction_timer -= delta
		if _reaction_timer <= 0.0 and _will_block:
			if combat.state == MeleeCombat.State.BLOCK:
				combat.set_block_dir(_block_choice)
			elif combat.state != MeleeCombat.State.SWING:
				combat.start_block(_block_choice) # Feints our own windup if needed.
		# Time a parry by re-raising the block right before the hit lands.
		if not _parry_attempted and _target_combat.time_to_impact() < 0.12:
			_parry_attempted = true
			if combat.state == MeleeCombat.State.BLOCK and randf() < parry_chance:
				combat.refresh_block()
	elif _reacting:
		_reacting = false
		_block_release_timer = randf_range(0.1, 0.3)

	if _block_release_timer > 0.0 and not _reacting:
		_block_release_timer -= delta
		if _block_release_timer <= 0.0:
			combat.stop_block()


func _attack(delta: float, distance: float) -> void:
	if combat.state == MeleeCombat.State.WINDUP:
		_hold_time -= delta
		if _hold_time <= 0.0:
			if _feint_next:
				_feint_next = false
				combat.feint()
				_attack_timer = randf_range(0.2, 0.5)
			else:
				combat.release_attack()
		return

	if combat.state != MeleeCombat.State.IDLE or _reacting or _attack_timer > 0.0:
		return
	if distance > engage_distance + 0.5 or not _attack_slot_free():
		return
	if combat.start_windup(_choose_attack_dir()):
		var p := combat.profile
		_hold_time = randf_range(p.min_windup, p.full_charge_time) / p.combat_speed
		_feint_next = randf() < feint_chance
		_attack_timer = _hold_time + randf_range(attack_cooldown.x, attack_cooldown.y)


func _choose_attack_dir() -> MeleeCombat.Dir:
	if _target_combat.state == MeleeCombat.State.BLOCK and randf() < read_block_chance:
		# Attack a side the player isn't covering.
		var open := []
		for dir in MeleeCombat.Dir.values():
			if MeleeCombat.required_block(dir) != _target_combat.block_dir:
				open.append(dir)
		return open.pick_random()
	return _random_dir()


func _random_dir() -> MeleeCombat.Dir:
	return MeleeCombat.Dir.values().pick_random()


## Limits how many enemies can attack at once so fights stay readable.
func _attack_slot_free() -> bool:
	var attacking := 0
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if enemy != self and enemy.combat.is_attacking():
			attacking += 1
	return attacking < max_simultaneous_attackers


# --- Movement --------------------------------------------------------------

func _face(to_target: Vector3, delta: float) -> void:
	if to_target.length() < 0.05:
		return
	# Same turn caps as the player, so side-stepping a committed attack works.
	var cap := combat.turn_cap()
	var turn_rate := cap if cap > 0.0 else 8.0
	var target_yaw := atan2(-to_target.x, -to_target.z)
	rotation.y = rotate_toward(rotation.y, target_yaw, turn_rate * delta)


func _movement(delta: float, to_target: Vector3, distance: float) -> Vector3:
	var speed := move_speed * combat.move_multiplier()

	var direction: Vector3
	if distance > engage_distance:
		direction = _chase_direction(delta, to_target)
	elif distance < engage_distance - 0.7:
		direction = -to_target.normalized()
		speed *= 0.6
	else:
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_strafe_timer = randf_range(1.2, 3.0)
			_strafe_sign = [-1.0, 0.0, 1.0].pick_random()
		direction = to_target.normalized().cross(Vector3.UP) * _strafe_sign
		speed *= 0.35

	return (direction + _separation()).normalized() * speed


## Pushes away from nearby enemies so they don't stack on each other.
func _separation() -> Vector3:
	var push := Vector3.ZERO
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if enemy == self:
			continue
		var away: Vector3 = global_position - enemy.global_position
		away.y = 0.0
		var d := away.length()
		if d > 0.01 and d < 1.6:
			push += away / d * (1.6 - d)
	return push


func _chase_direction(delta: float, to_target: Vector3) -> Vector3:
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = 0.25
		agent.target_position = target.global_position

	if agent.is_navigation_finished() or NavigationServer3D.map_get_iteration_id(agent.get_navigation_map()) == 0:
		return to_target.normalized()
	var next := agent.get_next_path_position() - global_position
	next.y = 0.0
	if next.length() < 0.01:
		return to_target.normalized()
	return next.normalized()


# --- Reactions -------------------------------------------------------------

func _on_defended(result: MeleeCombat.Result, _attacker: MeleeCombat) -> void:
	if result == MeleeCombat.Result.HIT or result == MeleeCombat.Result.GUARD_BREAK:
		_material.albedo_color = Color.WHITE
		create_tween().tween_property(_material, "albedo_color", _base_color, 0.15)


func _on_died() -> void:
	velocity = Vector3.ZERO
	collision_shape.set_deferred("disabled", true)
	died.emit(self)
	$WeaponPivot.hide()
	var tween := create_tween().set_parallel()
	tween.tween_property(body_mesh, "scale", Vector3(1.3, 0.05, 1.3), 0.25)
	tween.tween_property(body_mesh, "position:y", 0.05, 0.25)
	tween.chain().tween_interval(0.5)
	tween.chain().tween_callback(queue_free)
