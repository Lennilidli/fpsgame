class_name MeleeCombat
extends Node
## Mortal Online 2 style directional melee, shared by the player and enemies.
##
## Attacks come from four directions. A defender stops an attack by blocking toward the
## side the blade is coming from (see required_block). Raising the block just before
## impact parries and staggers the attacker. Blocking drains stamina; empty stamina
## breaks the guard.

enum Dir { OVERHEAD, THRUST, LEFT, RIGHT }
enum State { IDLE, WINDUP, SWING, RECOVER, BLOCK, STAGGER, DEAD }
enum Result { MISS, HIT, BLOCKED, PARRIED, GUARD_BREAK }

signal health_changed(current: float, maximum: float)
signal stamina_changed(current: float, maximum: float)
signal state_changed(state: State)
## Emitted on the attacker when one of its swings lands (target is null on a miss).
signal attack_resolved(result: Result, target: MeleeCombat)
## Emitted on the defender when it is struck.
signal defended(result: Result, attacker: MeleeCombat)
signal died

const DIR_NAMES := ["overhead", "thrust", "left", "right"]

## Per-direction swing stats. "impact" is the fraction of the swing when the hit lands.
const ATTACKS := {
	Dir.OVERHEAD: {"duration": 0.42, "impact": 0.6, "damage": 1.25, "reach": 0.0, "arc": 40.0, "stamina": 18.0, "cleave": false},
	Dir.THRUST: {"duration": 0.3, "impact": 0.6, "damage": 0.85, "reach": 0.5, "arc": 25.0, "stamina": 12.0, "cleave": false},
	Dir.LEFT: {"duration": 0.36, "impact": 0.55, "damage": 1.0, "reach": 0.0, "arc": 80.0, "stamina": 15.0, "cleave": true},
	Dir.RIGHT: {"duration": 0.36, "impact": 0.55, "damage": 1.0, "reach": 0.0, "arc": 80.0, "stamina": 15.0, "cleave": true},
}

## Weapon poses as [position, rotation in degrees], relative to the weapon's parent.
## The weapon faces -Z with the blade along its local +Y.
const POSES := {
	"idle": [Vector3(0.3, -0.35, -0.5), Vector3(-30, 0, 0)],
	"windup_overhead": [Vector3(0.2, -0.05, -0.5), Vector3(20, 0, 0)],
	"swing_overhead": [Vector3(0.05, -0.45, -0.6), Vector3(-120, 0, 0)],
	"windup_thrust": [Vector3(0.28, -0.32, -0.3), Vector3(-75, 10, 0)],
	"swing_thrust": [Vector3(0.05, -0.2, -0.95), Vector3(-88, 0, 0)],
	"windup_left": [Vector3(-0.35, -0.15, -0.45), Vector3(0, 15, 60)],
	"swing_left": [Vector3(0.4, -0.25, -0.55), Vector3(0, -160, 80)],
	"windup_right": [Vector3(0.45, -0.15, -0.45), Vector3(0, -15, -60)],
	"swing_right": [Vector3(-0.35, -0.25, -0.55), Vector3(0, 160, -80)],
	"block_overhead": [Vector3(0.35, 0.1, -0.5), Vector3(0, -10, 90)],
	"block_thrust": [Vector3(0.3, -0.4, -0.5), Vector3(0, 0, 45)],
	"block_left": [Vector3(-0.35, -0.35, -0.45), Vector3(-10, 0, 0)],
	"block_right": [Vector3(0.4, -0.35, -0.45), Vector3(-10, 0, 0)],
	"stagger": [Vector3(0.45, -0.6, -0.35), Vector3(-10, 0, -40)],
}

@export var team := 0
@export var weapon: Node3D
@export var glow_on_windup := false ## Make the blade glow while attacking (enemy telegraph).

@export_group("Stats")
@export var max_health := 100.0
@export var max_stamina := 100.0
@export var stamina_regen := 25.0
@export var regen_delay := 0.8
@export var base_damage := 30.0
@export var reach := 2.3

@export_group("Timing")
@export var min_windup := 0.3 ## A swing can't be released sooner than this.
@export var full_charge_time := 0.9 ## Holding this long gives full damage.
@export var recover_time := 0.25
@export var parry_window := 0.2 ## A block this fresh when hit counts as a parry.
@export var parry_stagger := 1.0
@export var blocked_recoil := 0.45
@export var flinch_time := 0.3
@export var guard_break_stagger := 0.9

@export_group("Stamina costs")
@export var feint_cost := 8.0
@export var block_cost_ratio := 0.8 ## Stamina lost per point of blocked damage.

var health: float
var stamina: float
var state := State.IDLE
var attack_dir := Dir.OVERHEAD
var block_dir := Dir.OVERHEAD
var body: Node3D

var _timer := 0.0
var _state_duration := 0.0
var _release_requested := false
var _impact_done := false
var _swing_damage := 0.0
var _block_time := 0.0
var _regen_timer := 0.0
var _pose_tween: Tween
var _blade: MeshInstance3D
var _glow_material: StandardMaterial3D


func _ready() -> void:
	body = get_parent()
	health = max_health
	stamina = max_stamina
	add_to_group("combatants")
	if weapon:
		_apply_pose("idle", 0.0)
		_blade = weapon.get_node_or_null("Blade")
	if glow_on_windup:
		_glow_material = StandardMaterial3D.new()
		_glow_material.albedo_color = Color(1.0, 0.55, 0.2)
		_glow_material.emission_enabled = true
		_glow_material.emission = Color(1.0, 0.4, 0.1)
		_glow_material.emission_energy_multiplier = 2.5


## Which way a defender must block to stop an attack from `dir`.
## Side attacks arrive on the defender's opposite side.
static func required_block(dir: Dir) -> Dir:
	match dir:
		Dir.LEFT:
			return Dir.RIGHT
		Dir.RIGHT:
			return Dir.LEFT
	return dir


func emit_state() -> void:
	health_changed.emit(health, max_health)
	stamina_changed.emit(stamina, max_stamina)


func is_dead() -> bool:
	return state == State.DEAD


func is_attacking() -> bool:
	return state == State.WINDUP or state == State.SWING


## 0..1 charge of the current windup.
func charge() -> float:
	if state != State.WINDUP:
		return 0.0
	return clampf(_timer / full_charge_time, 0.0, 1.0)


## Seconds until the current swing lands, or INF if not swinging.
func time_to_impact() -> float:
	if state != State.SWING or _impact_done:
		return INF
	var atk: Dictionary = ATTACKS[attack_dir]
	return atk["duration"] * atk["impact"] - _timer


func start_windup(dir: Dir) -> bool:
	if not (state == State.IDLE or state == State.BLOCK) or stamina <= 0.0:
		return false
	attack_dir = dir
	_release_requested = false
	_set_state(State.WINDUP)
	_apply_pose("windup_" + DIR_NAMES[dir], min_windup, Tween.EASE_OUT)
	return true


func release_attack() -> void:
	if state == State.WINDUP:
		_release_requested = true


## Cancels a windup without swinging.
func feint() -> bool:
	if state != State.WINDUP:
		return false
	_spend(feint_cost)
	_set_state(State.IDLE)
	_apply_pose("idle", 0.2)
	return true


## Raises (or re-aims) the block. Blocking during a windup feints it.
func start_block(dir: Dir) -> bool:
	if state == State.WINDUP:
		feint()
	if not (state == State.IDLE or state == State.BLOCK):
		return false
	block_dir = dir
	_block_time = 0.0
	_set_state(State.BLOCK)
	_apply_pose("block_" + DIR_NAMES[dir], 0.12)
	return true


func set_block_dir(dir: Dir) -> void:
	if state == State.BLOCK and dir != block_dir:
		start_block(dir)


## Restarts the parry window of an already raised block.
func refresh_block() -> void:
	if state == State.BLOCK:
		_block_time = 0.0


func stop_block() -> void:
	if state == State.BLOCK:
		_set_state(State.IDLE)
		_apply_pose("idle", 0.15)


func stagger(duration: float) -> void:
	if is_dead():
		return
	_set_state(State.STAGGER, duration)
	_apply_pose("stagger", 0.15)


func heal(amount: float) -> void:
	if is_dead():
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


## Called on the defender by an attacker's swing. Returns what happened.
func receive_attack(attacker: MeleeCombat, dir: Dir, damage: float) -> Result:
	if is_dead():
		return Result.MISS

	var to_attacker := attacker.body.global_position - body.global_position
	to_attacker.y = 0.0
	var forward := -body.global_basis.z
	forward.y = 0.0
	var facing := to_attacker.length() < 0.01 or forward.angle_to(to_attacker) < deg_to_rad(80.0)

	var result: Result
	if state == State.BLOCK and facing and block_dir == required_block(dir):
		if _block_time <= parry_window:
			result = Result.PARRIED
		else:
			_spend(damage * block_cost_ratio)
			if stamina <= 0.0:
				result = Result.GUARD_BREAK
				_take_damage(damage * 0.5)
				stagger(guard_break_stagger)
			else:
				result = Result.BLOCKED
	else:
		result = Result.HIT
		_take_damage(damage)
		if state != State.SWING:
			stagger(flinch_time)

	defended.emit(result, attacker)
	return result


func _physics_process(delta: float) -> void:
	match state:
		State.WINDUP:
			_timer += delta
			if _release_requested and _timer >= min_windup:
				_begin_swing()
		State.SWING:
			_timer += delta
			var atk: Dictionary = ATTACKS[attack_dir]
			if not _impact_done and _timer >= atk["duration"] * atk["impact"]:
				_impact_done = true
				_resolve_impact()
			if state == State.SWING and _timer >= atk["duration"]:
				_set_state(State.RECOVER, recover_time)
				_apply_pose("idle", recover_time)
		State.RECOVER, State.STAGGER:
			_timer += delta
			if _timer >= _state_duration:
				_set_state(State.IDLE)
				_apply_pose("idle", 0.2)
		State.BLOCK:
			_block_time += delta
	_regen_stamina(delta)


func _begin_swing() -> void:
	var atk: Dictionary = ATTACKS[attack_dir]
	_spend(atk["stamina"])
	_swing_damage = base_damage * atk["damage"] * lerpf(0.7, 1.0, charge())
	_impact_done = false
	_set_state(State.SWING)
	_apply_pose("swing_" + DIR_NAMES[attack_dir], atk["duration"], Tween.EASE_IN)


func _resolve_impact() -> void:
	var atk: Dictionary = ATTACKS[attack_dir]
	var forward := -body.global_basis.z
	forward.y = 0.0
	var max_distance: float = reach + atk["reach"] + 0.4 # 0.4 = target body radius

	var targets: Array = []
	for node in get_tree().get_nodes_in_group("combatants"):
		var other := node as MeleeCombat
		if other == null or other == self or other.team == team or other.is_dead():
			continue
		var to_other := other.body.global_position - body.global_position
		if absf(to_other.y) > 2.0:
			continue
		to_other.y = 0.0
		var distance := to_other.length()
		if distance > max_distance:
			continue
		if distance > 0.01 and rad_to_deg(forward.angle_to(to_other)) > atk["arc"] * 0.5:
			continue
		targets.append([distance, other])

	if targets.is_empty():
		attack_resolved.emit(Result.MISS, null)
		return
	targets.sort_custom(func(a, b): return a[0] < b[0])
	if not atk["cleave"]:
		targets.resize(1)

	for entry in targets:
		var target: MeleeCombat = entry[1]
		var result := target.receive_attack(self, attack_dir, _swing_damage)
		attack_resolved.emit(result, target)
		if result == Result.PARRIED:
			stagger(parry_stagger)
			return
		if result == Result.BLOCKED:
			_set_state(State.RECOVER, blocked_recoil)
			_apply_pose("idle", blocked_recoil)
			return


func _take_damage(amount: float) -> void:
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_set_state(State.DEAD)
		if _pose_tween:
			_pose_tween.kill()
		died.emit()


func _spend(amount: float) -> void:
	stamina = maxf(stamina - amount, 0.0)
	_regen_timer = regen_delay
	stamina_changed.emit(stamina, max_stamina)


func _regen_stamina(delta: float) -> void:
	_regen_timer -= delta
	if _regen_timer > 0.0 or stamina >= max_stamina or is_attacking() or is_dead():
		return
	var rate := stamina_regen * (0.5 if state == State.BLOCK else 1.0)
	stamina = minf(stamina + rate * delta, max_stamina)
	stamina_changed.emit(stamina, max_stamina)


func _set_state(new_state: State, duration := 0.0) -> void:
	state = new_state
	_timer = 0.0
	_state_duration = duration
	if _blade and _glow_material:
		_blade.material_override = _glow_material if is_attacking() else null
	state_changed.emit(new_state)


func _apply_pose(pose_name: String, time: float, ease := Tween.EASE_IN_OUT) -> void:
	if weapon == null:
		return
	var pose: Array = POSES[pose_name]
	var target_rotation: Vector3 = pose[1] * (PI / 180.0)
	if _pose_tween:
		_pose_tween.kill()
	if time <= 0.0:
		weapon.position = pose[0]
		weapon.rotation = target_rotation
		return
	_pose_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(ease)
	_pose_tween.tween_property(weapon, "position", pose[0], time)
	_pose_tween.tween_property(weapon, "rotation", target_rotation, time)
