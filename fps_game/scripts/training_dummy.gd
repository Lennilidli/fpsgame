extends CharacterBody3D
## Stationary training dummy. It never dies, turns to face the player, drifts back to
## its spot after knockback, and shows floating feedback for every exchange.
## Behaviour settings are read live from `settings` (the training controller).

enum Mode { PASSIVE, BLOCKER, ATTACKER }

@export var mode := Mode.PASSIVE
## How close the player must be before an attacker dummy swings.
@export var attack_trigger_range := 3.5

## Set by the training controller.
var settings: Node
var target: Node3D

@onready var combat: MeleeCombat = $MeleeCombat
@onready var body_mesh: MeshInstance3D = $Body
@onready var feedback: Label3D = $Feedback

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _home: Vector3
var _material: StandardMaterial3D
var _base_color: Color
var _feedback_tween: Tween
var _timer := 0.0
var _hold := 0.0
var _feinted := false
var _reacting := false
var _react_timer := 0.0
var _react_dir := MeleeCombat.Dir.OVERHEAD
var _parry_attempted := false
var _pattern_index := 0


func _ready() -> void:
	add_to_group("enemies")
	add_to_group("dummies")
	_home = global_position
	combat.immortal = true
	_material = body_mesh.get_active_material(0).duplicate()
	body_mesh.material_override = _material
	_base_color = _material.albedo_color
	feedback.modulate.a = 0.0
	combat.defended.connect(_on_defended)
	combat.attack_resolved.connect(_on_attack_resolved)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	if not is_instance_valid(target) or settings == null:
		return

	var to_target := target.global_position - global_position
	to_target.y = 0.0
	if to_target.length() > 0.05:
		var cap := combat.turn_cap()
		rotation.y = rotate_toward(rotation.y, atan2(-to_target.x, -to_target.z), (cap if cap > 0.0 else 6.0) * delta)

	match mode:
		Mode.BLOCKER:
			_update_blocker(delta, to_target.length())
		Mode.ATTACKER:
			_update_attacker(delta, to_target.length())

	# Knockback and lunges move the dummy; it then walks back to its spot.
	var home_pull := (_home - global_position) * 2.0
	home_pull.y = 0.0
	var bonus := combat.movement_bonus()
	velocity.x = home_pull.x + bonus.x
	velocity.z = home_pull.z + bonus.z
	move_and_slide()


# --- Blocker ---------------------------------------------------------------

func _update_blocker(delta: float, distance: float) -> void:
	var player_combat: MeleeCombat = target.combat
	match settings.block_mode:
		0: # Hold one direction
			_raise_block(settings.block_direction)
		1: # Cycle through directions
			_timer -= delta
			if _timer <= 0.0:
				_timer = settings.block_cycle_time
				_pattern_index = (_pattern_index + 1) % 4
			_raise_block(_pattern_index)
		2: # React to the player's windup
			if player_combat.is_attacking() and distance < 4.5:
				if not _reacting:
					_reacting = true
					_parry_attempted = false
					_react_timer = settings.block_reaction
					var correct := MeleeCombat.required_block(player_combat.attack_dir)
					_react_dir = correct if randf() < settings.block_skill else MeleeCombat.Dir.values().pick_random()
				_react_timer -= delta
				if _react_timer <= 0.0:
					_raise_block(_react_dir)
				if not _parry_attempted and player_combat.time_to_impact() < 0.12:
					_parry_attempted = true
					if randf() < settings.block_parry_chance:
						combat.refresh_block()
			elif _reacting:
				_reacting = false
				_timer = 0.3
			else:
				_timer -= delta
				if _timer <= 0.0:
					combat.stop_block()


func _raise_block(dir: int) -> void:
	if combat.state == MeleeCombat.State.BLOCK:
		combat.set_block_dir(dir as MeleeCombat.Dir)
	elif combat.state == MeleeCombat.State.IDLE:
		combat.start_block(dir as MeleeCombat.Dir)


# --- Attacker --------------------------------------------------------------

func _update_attacker(delta: float, distance: float) -> void:
	if combat.state == MeleeCombat.State.WINDUP:
		_hold -= delta
		if settings.attacker_feints and not _feinted and _hold <= settings.attack_hold * 0.5:
			_feinted = true
			var others := MeleeCombat.Dir.values().filter(func(d): return d != combat.attack_dir)
			combat.feint_to(others.pick_random())
			_hold = settings.attack_hold
		elif _hold <= 0.0:
			combat.release_attack()
		return

	if combat.state != MeleeCombat.State.IDLE:
		return
	_timer -= delta
	if _timer > 0.0 or distance > attack_trigger_range:
		return
	_timer = settings.attack_interval
	_hold = settings.attack_hold
	_feinted = false
	combat.start_windup(_next_attack_dir())


func _next_attack_dir() -> MeleeCombat.Dir:
	match settings.attack_pattern:
		0: # Random
			return MeleeCombat.Dir.values().pick_random()
		1: # Cycle
			_pattern_index = (_pattern_index + 1) % 4
			return _pattern_index as MeleeCombat.Dir
	return (settings.attack_pattern - 2) as MeleeCombat.Dir # Fixed direction


# --- Feedback --------------------------------------------------------------

func _on_defended(result: MeleeCombat.Result, attacker: MeleeCombat) -> void:
	var damage := attacker.last_swing_damage
	match result:
		MeleeCombat.Result.HIT:
			_flash()
			_show_feedback("%d" % roundi(damage), Color.WHITE)
		MeleeCombat.Result.BLOCKED:
			_show_feedback("BLOCKED", Color(0.5, 0.75, 1.0))
		MeleeCombat.Result.PARRIED:
			_show_feedback("PARRIED", Color(1.0, 0.35, 0.3))
		MeleeCombat.Result.GUARD_BREAK:
			_flash()
			_show_feedback("GUARD BREAK %d" % roundi(damage * 0.5), Color(1.0, 0.8, 0.2))


## Feedback when the dummy's own swing is answered by the player.
func _on_attack_resolved(result: MeleeCombat.Result, _target: MeleeCombat) -> void:
	match result:
		MeleeCombat.Result.BLOCKED:
			_show_feedback("you blocked", Color(0.5, 0.75, 1.0))
		MeleeCombat.Result.PARRIED:
			_show_feedback("you PARRIED!", Color(1.0, 0.85, 0.2))
		MeleeCombat.Result.HIT:
			_show_feedback("hit you", Color(1.0, 0.4, 0.4))


func _flash() -> void:
	_material.albedo_color = Color.WHITE
	create_tween().tween_property(_material, "albedo_color", _base_color, 0.15)


func _show_feedback(text: String, color: Color) -> void:
	feedback.text = text
	feedback.modulate = color
	feedback.position.y = 2.2
	if _feedback_tween:
		_feedback_tween.kill()
	_feedback_tween = create_tween().set_parallel()
	_feedback_tween.tween_property(feedback, "position:y", 2.6, 0.9)
	_feedback_tween.tween_property(feedback, "modulate:a", 0.0, 0.9).set_delay(0.3)
