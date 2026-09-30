class_name MeleeCombat
extends Node
## Mortal Online 2 style directional melee, shared by the player and enemies.
##
## Attacks come from four directions. A defender stops an attack by blocking toward the
## side the blade is coming from (see required_block). Raising the block just before
## impact parries and staggers the attacker. Blocking drains stamina; empty stamina
## breaks the guard.
##
## All feel/timing values live in `profile` (a CombatProfile resource).
## The weapon is animated procedurally from POSES through a queue of eased segments,
## which allows backswings, hit-stop, bounces and follow-through.

enum Dir { OVERHEAD, THRUST, LEFT, RIGHT }
enum State { IDLE, WINDUP, SWING, RECOVER, BLOCK, STAGGER, DEAD }
enum Result { MISS, HIT, BLOCKED, PARRIED, GUARD_BREAK }
enum Ease { LINEAR, IN, OUT, IN_OUT }
enum Queued { NONE, WINDUP, BLOCK }

signal health_changed(current: float, maximum: float)
signal stamina_changed(current: float, maximum: float)
signal state_changed(state: State)
signal swing_started(dir: Dir)
## Emitted on the attacker when one of its swings lands (target is null on a miss).
signal attack_resolved(result: Result, target: MeleeCombat)
## Emitted on the attacker when its swing glances off level geometry.
signal world_hit(point: Vector3)
## Emitted on the defender when it is struck.
signal defended(result: Result, attacker: MeleeCombat)
signal died
## Emitted by the fighter that resolved a contact (the network host), with everything
## needed to replay it elsewhere via apply_contact().
signal contact_decided(target: MeleeCombat, result: Result, blade_contact: bool, point: Vector3, damage: float)
## Same for a swing glancing off level geometry (replay with apply_world_hit()).
signal world_contact_decided(point: Vector3)

const DIR_NAMES := ["overhead", "thrust", "left", "right"]

## Weapon poses as [position, rotation in degrees], relative to the weapon's parent.
## The weapon faces -Z with the blade along its local +Y.
const POSES := {
	"idle": [Vector3(0.3, -0.35, -0.45), Vector3(-10, 0, 0)],
	"windup_overhead": [Vector3(0.2, -0.05, -0.5), Vector3(20, 0, 0)],
	"swing_overhead": [Vector3(0.05, -0.45, -0.6), Vector3(-120, 0, 0)],
	"windup_thrust": [Vector3(0.25, -0.3, 0.4), Vector3(-80, 8, 0)],
	"swing_thrust": [Vector3(0.05, -0.2, -0.7), Vector3(-88, 0, 0)],
	"windup_left": [Vector3(-0.35, -0.15, -0.45), Vector3(0, 15, 60)],
	"swing_left": [Vector3(0.4, -0.25, -0.55), Vector3(0, -160, 80)],
	"windup_right": [Vector3(0.45, -0.15, -0.45), Vector3(0, -15, -60)],
	"swing_right": [Vector3(-0.35, -0.25, -0.55), Vector3(0, 160, -80)],
	"block_overhead": [Vector3(0.35, 0.1, -0.5), Vector3(0, -10, 90)],
	"block_thrust": [Vector3(0.3, -0.4, -0.5), Vector3(0, 0, 45)],
	"block_left": [Vector3(-0.35, -0.35, -0.45), Vector3(-10, 0, 0)],
	"block_right": [Vector3(0.4, -0.35, -0.45), Vector3(-10, 0, 0)],
	"stagger": [Vector3(0.45, -0.6, -0.2), Vector3(10, 0, -40)],
	# Blade drawn back close to the body; used after a block so the recovery doesn't
	# sweep through the opponent's guard.
	"retract": [Vector3(0.32, -0.28, -0.32), Vector3(10, 0, 0)],
}

## Blade span along the weapon's local +Y, used for wall collision and sparks.
const BLADE_BASE := 0.12
const BLADE_TIP := 0.95
## Sub-steps per physics frame when sweeping the blade, so fast swings can't skip
## through a thin blade or body.
const HITBOX_SUBSTEPS := 4

@export var profile: CombatProfile
@export var team := 0
@export var weapon: Node3D
@export var glow_on_windup := false ## Make the blade glow while attacking (enemy telegraph).
## Lengthens the blade hitbox beyond the visible blade (the hand stays where it is). The
## first-person sword is small and close to the camera, so the player needs a longer
## hitbox for real reach; it lies on the same line as the blade on screen.
@export var hitbox_scale := 1.0
@export var immortal := false ## Health refills instead of dying (training).
@export var infinite_stamina := false
## Whether this simulation detects hits. Off on a network guest: the host detects them
## and sends the results, which are replayed with apply_contact()/apply_world_hit().
var resolves_contacts := true

@export_group("Stats")
@export var max_health := 100.0
@export var max_stamina := 100.0
@export var base_damage := 30.0

var health: float
var stamina: float
var state := State.IDLE
var attack_dir := Dir.OVERHEAD
var block_dir := Dir.OVERHEAD
var body: Node3D
## Info about the most recent exchange, for training feedback.
var last_swing_damage := 0.0
var last_swing_charge := 0.0
var last_block_age := -1.0 ## How long the block had been up when last hit (-1 if not blocking).
## Action waiting in the input buffer until the current one finishes.
var queued := Queued.NONE
var queued_dir := Dir.OVERHEAD
var last_contact_blade := false ## Whether this fighter's last swing struck a blade (vs a body).

var _timer := 0.0
var _state_duration := 0.0
var _release_requested := false
var _impact_done := false
var _impact_time := 0.0
var _swing_end_time := 0.0
var _swing_damage := 0.0
var _block_time := 0.0
var _regen_timer := 0.0
var _freeze := 0.0
var _last_hitbox: Array = []
var _victims: Array[MeleeCombat] = []
var _stop_hitting := false
var _queued_released := false ## The queued attack was a tap (button already released).
var _queued_age := 0.0
var _guard_distance := {} ## Blade-to-guard distance per defender this swing.
var _hurt_shape: CollisionShape3D
var _anim_queue: Array[Dictionary] = []
var _segment: Dictionary = {}
var _segment_t := 0.0
var _segment_from: Array = []
var _blade: MeshInstance3D
var _glow_material: StandardMaterial3D
var _spark_mesh: SphereMesh


func _ready() -> void:
	if profile == null:
		profile = CombatProfile.new()
	body = get_parent()
	_hurt_shape = body.get_node_or_null("CollisionShape3D")
	health = max_health
	stamina = max_stamina
	add_to_group("combatants")
	if weapon:
		_snap_to(POSES["idle"])
		_blade = weapon.get_node_or_null("Blade")
	if glow_on_windup:
		_glow_material = StandardMaterial3D.new()
		_glow_material.albedo_color = Color(1.0, 0.55, 0.2)
		_glow_material.emission_enabled = true
		_glow_material.emission = Color(1.0, 0.4, 0.1)
		_glow_material.emission_energy_multiplier = 2.5
	_spark_mesh = SphereMesh.new()
	_spark_mesh.radius = 0.05
	_spark_mesh.height = 0.1
	var spark_material := StandardMaterial3D.new()
	spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_material.albedo_color = Color(1.0, 0.85, 0.4)
	_spark_mesh.material = spark_material


## Which way a defender must block to stop an attack from `dir`.
## Side attacks arrive on the defender's opposite side.
static func required_block(dir: Dir) -> Dir:
	match dir:
		Dir.LEFT:
			return Dir.RIGHT
		Dir.RIGHT:
			return Dir.LEFT
	return dir


# --- Queries ---------------------------------------------------------------

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
	return clampf(_timer / _t(profile.full_charge_time), 0.0, 1.0)


## Seconds until the current swing lands, or INF if not swinging.
func time_to_impact() -> float:
	if state != State.SWING or _impact_done:
		return INF
	return _impact_time - _timer


## Hit-stop for the current swing: heavier attacks and fuller charges freeze longer.
func current_hit_stop() -> float:
	var weight: float = profile.attack(attack_dir)["damage"] * lerpf(0.8, 1.2, last_swing_charge)
	return _t(profile.hit_stop * weight)


## Visual flinch for a body mesh struck by an attack from `dir`: squash on overheads,
## rock back on thrusts, tilt away from side hits. Returns the tween (kill it to cancel).
static func play_hit_react(mesh: Node3D, dir: Dir, strength: float) -> Tween:
	var tilt := Vector3.ZERO
	var squash := Vector3.ONE
	match dir:
		Dir.OVERHEAD:
			squash = Vector3(1.0 + 0.08 * strength, 1.0 - 0.14 * strength, 1.0 + 0.08 * strength)
			tilt.x = deg_to_rad(-8.0 * strength)
		Dir.THRUST:
			tilt.x = deg_to_rad(10.0 * strength)
		Dir.LEFT:
			tilt.z = deg_to_rad(10.0 * strength)
		Dir.RIGHT:
			tilt.z = deg_to_rad(-10.0 * strength)
	var tween := mesh.create_tween().set_parallel()
	tween.tween_property(mesh, "rotation", tilt, 0.05).set_ease(Tween.EASE_OUT)
	tween.tween_property(mesh, "scale", squash, 0.05).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(mesh, "rotation", Vector3.ZERO, 0.45).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(mesh, "scale", Vector3.ONE, 0.45).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	return tween


## Max turn speed in radians/s for the current state, or 0 for unlimited.
func turn_cap() -> float:
	match state:
		State.WINDUP:
			return deg_to_rad(profile.windup_turn_cap)
		State.SWING:
			return deg_to_rad(profile.swing_turn_cap)
	return 0.0


## Multiplier for the body's movement speed in the current state.
func move_multiplier() -> float:
	match state:
		State.WINDUP:
			return profile.windup_move
		State.SWING:
			return profile.swing_move
		State.BLOCK:
			return profile.block_move
		State.STAGGER:
			return 0.3
	return 1.0


## World-space blade hitbox as [base, tip].
func hitbox_segment() -> Array:
	var hand := weapon.global_position
	var base := _blade_point(0.0)
	var tip := _blade_point(1.0)
	return [hand + (base - hand) * hitbox_scale, hand + (tip - hand) * hitbox_scale]


## Body hurtbox as [bottom, top, radius] from the body's capsule, or [] if unavailable.
func hurtbox() -> Array:
	if _hurt_shape == null or _hurt_shape.disabled or not _hurt_shape.shape is CapsuleShape3D:
		return []
	var capsule: CapsuleShape3D = _hurt_shape.shape
	var half := capsule.height * 0.5 - capsule.radius
	var t := _hurt_shape.global_transform
	return [t * Vector3(0.0, -half, 0.0), t * Vector3(0.0, half, 0.0), capsule.radius]


## Closest distance between this fighter's blade hitbox and another's.
func blade_distance_to(other: MeleeCombat) -> float:
	var mine := hitbox_segment()
	var theirs := other.hitbox_segment()
	var points := Geometry3D.get_closest_points_between_segments(mine[0], mine[1], theirs[0], theirs[1])
	return points[0].distance_to(points[1])


## True if `other` is roughly in front of this fighter (guards only work to the front).
func is_facing(other: MeleeCombat) -> bool:
	var to_other := other.body.global_position - body.global_position
	to_other.y = 0.0
	return to_other.length() < 0.01 or _flat_forward().angle_to(to_other) < deg_to_rad(80.0)


func _opponents() -> Array[MeleeCombat]:
	var result: Array[MeleeCombat] = []
	for node in get_tree().get_nodes_in_group("combatants"):
		var other := node as MeleeCombat
		if other and other != self and other.team != team and not other.is_dead():
			result.append(other)
	return result


# --- Actions ---------------------------------------------------------------

func start_windup(dir: Dir) -> bool:
	if not (state == State.IDLE or state == State.BLOCK) or stamina <= 0.0:
		return false
	attack_dir = dir
	_release_requested = false
	_set_state(State.WINDUP)
	_play([_seg(_windup_pose(profile.backswing_amount), profile.windup_time, Ease.OUT, profile.windup_ease)])
	return true


func release_attack() -> void:
	if state == State.WINDUP:
		_release_requested = true


## Cancels a windup without swinging.
func feint() -> bool:
	if state != State.WINDUP:
		return false
	_spend(profile.feint_cost)
	_set_state(State.IDLE)
	_play([_seg(POSES["idle"], 0.2, Ease.IN_OUT)])
	return true


## Redirect feint: abandons the current windup and winds up again toward `dir`.
## The charge restarts and it costs feint stamina.
func feint_to(dir: Dir) -> bool:
	if state != State.WINDUP or dir == attack_dir or stamina <= 0.0:
		return false
	_spend(profile.feint_cost)
	attack_dir = dir
	_release_requested = false
	_set_state(State.WINDUP)
	_play([_seg(_windup_pose(profile.backswing_amount), profile.windup_time, Ease.OUT, profile.windup_ease)])
	return true


## The next direction clockwise (overhead, right, thrust, left).
static func next_dir(dir: Dir) -> Dir:
	match dir:
		Dir.OVERHEAD:
			return Dir.RIGHT
		Dir.RIGHT:
			return Dir.THRUST
		Dir.THRUST:
			return Dir.LEFT
	return Dir.OVERHEAD


## Raises (or re-aims) the block. Blocking during a windup feints it.
func start_block(dir: Dir) -> bool:
	if state == State.WINDUP:
		feint()
	if not (state == State.IDLE or state == State.BLOCK):
		return false
	block_dir = dir
	_block_time = 0.0
	_set_state(State.BLOCK)
	_play([_seg(POSES["block_" + DIR_NAMES[dir]], profile.block_raise_time, Ease.OUT, 2.0)])
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
		_play([_seg(POSES["idle"], 0.15, Ease.IN_OUT)])


# --- Input buffer ----------------------------------------------------------
# Inputs made while busy (swinging, recovering, staggered) are queued and fire as soon
# as the fighter can act. The newest input replaces an older queued one.

## Starts a windup now, or queues it.
func queue_windup(dir: Dir) -> void:
	if start_windup(dir):
		_clear_queue()
	elif profile.input_buffer_time > 0.0:
		queued = Queued.WINDUP
		queued_dir = dir
		_queued_released = false
		_queued_age = 0.0


## Attack button released: releases the current windup, or marks a queued one as a tap.
func queue_release() -> void:
	if queued == Queued.WINDUP:
		_queued_released = true
		_queued_age = 0.0
	else:
		release_attack()


## Raises a block now (feinting a windup if needed), or queues it.
func queue_block(dir: Dir) -> void:
	if start_block(dir):
		_clear_queue()
	elif profile.input_buffer_time > 0.0:
		queued = Queued.BLOCK
		queued_dir = dir


## Block button released: lowers the block and drops a queued one.
func queue_block_release() -> void:
	if queued == Queued.BLOCK:
		_clear_queue()
	stop_block()


## Feint key: redirects the current windup, or the queued one.
func feint_or_redirect(dir: Dir) -> bool:
	if state == State.WINDUP:
		return feint_to(dir)
	if queued == Queued.WINDUP and dir != queued_dir:
		queued_dir = dir
		return true
	return false


## The direction a feint would redirect from: current windup, else the queued one.
func feint_base_dir() -> Dir:
	return attack_dir if state == State.WINDUP else queued_dir


## Mouse direction changed: a queued swing follows it only if enabled. Blocks never
## follow the mouse; their direction is fixed when block is pressed.
func update_queued_dir(dir: Dir) -> void:
	if queued == Queued.WINDUP and profile.buffer_follows_mouse:
		queued_dir = dir


func _process_queue(delta: float) -> void:
	if queued == Queued.NONE:
		return
	if is_dead():
		_clear_queue()
		return
	if queued == Queued.WINDUP and _queued_released:
		_queued_age += delta
		if _queued_age > profile.input_buffer_time:
			_clear_queue()
			return
	match queued:
		Queued.WINDUP:
			var tap := _queued_released
			if start_windup(queued_dir):
				_clear_queue()
				if tap:
					release_attack()
		Queued.BLOCK:
			if start_block(queued_dir):
				_clear_queue()


func _clear_queue() -> void:
	queued = Queued.NONE
	_queued_released = false
	_queued_age = 0.0


## Switches which weapon node is animated and used as the hitbox.
func set_weapon(new_weapon: Node3D, new_hitbox_scale: float) -> void:
	weapon = new_weapon
	hitbox_scale = new_hitbox_scale
	_blade = weapon.get_node_or_null("Blade")
	_anim_queue.clear()
	_segment = {}
	_snap_to(POSES["idle"])


## Back to full health and stamina, standing in guard (new round).
func reset() -> void:
	health = max_health
	stamina = max_stamina
	_freeze = 0.0
	_clear_queue()
	_set_state(State.IDLE)
	_anim_queue.clear()
	_segment = {}
	if weapon:
		_snap_to(POSES["idle"])
	emit_state()


func heal(amount: float) -> void:
	if is_dead():
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


## Called on the defender when an attacker's blade makes contact. `blade_contact` means
## the blade struck this fighter's raised weapon, which always counts as a block;
## a body contact is still blocked if the guard faces the right direction.
func receive_attack(attacker: MeleeCombat, dir: Dir, damage: float, blade_contact := false) -> Result:
	var result := decide_defense(attacker, dir, damage, blade_contact)
	if result != Result.MISS:
		apply_defense(attacker, result, damage)
	return result


## Works out what a contact does to this fighter, without changing anything.
func decide_defense(attacker: MeleeCombat, dir: Dir, damage: float, blade_contact := false) -> Result:
	if is_dead():
		return Result.MISS
	var guarded := state == State.BLOCK and is_facing(attacker) \
		and (blade_contact or block_dir == required_block(dir))
	if not guarded:
		return Result.HIT
	if _block_time <= _t(profile.parry_window):
		return Result.PARRIED
	if not infinite_stamina and stamina - damage * profile.block_cost_ratio <= 0.0:
		return Result.GUARD_BREAK
	return Result.BLOCKED


## Applies a decided contact to this fighter: stamina, damage, freeze, stagger.
func apply_defense(attacker: MeleeCombat, result: Result, damage: float) -> void:
	var impact := attacker.profile
	last_block_age = _block_time if state == State.BLOCK else -1.0
	match result:
		Result.BLOCKED:
			_spend(damage * profile.block_cost_ratio)
			_freeze = _t(impact.block_stop)
		Result.GUARD_BREAK:
			_spend(damage * profile.block_cost_ratio)
			_freeze = _t(impact.block_stop)
			_take_damage(damage * 0.5)
			_stagger(profile.guard_break_stagger)
		Result.HIT:
			_freeze = attacker.current_hit_stop() + attacker._t(impact.hit_bite_time)
			_take_damage(damage)
			if state != State.SWING:
				_stagger(profile.flinch_time)
	defended.emit(result, attacker)


# --- State machine ---------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _freeze > 0.0:
		_freeze -= delta
		return
	_update_animation(delta)

	match state:
		State.WINDUP:
			_timer += delta
			if _release_requested and _timer >= _t(profile.min_windup):
				_begin_swing()
		State.SWING:
			_timer += delta
			if _timer >= _t(profile.anticipation_time) and _sweep_hitbox():
				return
			if state == State.SWING and _timer >= _swing_end_time:
				if _victims.is_empty():
					attack_resolved.emit(Result.MISS, null)
				_follow_through()
		State.RECOVER:
			_timer += delta
			if _timer >= _state_duration:
				_set_state(State.IDLE)
		State.STAGGER:
			_timer += delta
			if _timer >= _state_duration:
				_set_state(State.IDLE)
				_play([_seg(POSES["idle"], 0.25, Ease.IN_OUT)])
		State.BLOCK:
			_block_time += delta
	_process_queue(delta)
	_regen_stamina(delta)


func _begin_swing() -> void:
	var atk := profile.attack(attack_dir)
	_spend(atk["stamina"])
	last_swing_charge = charge()
	_swing_damage = base_damage * atk["damage"] * lerpf(profile.charge_min_damage, 1.0, last_swing_charge)
	last_swing_damage = _swing_damage
	_impact_done = false
	_stop_hitting = false
	_victims.clear()
	_guard_distance.clear()
	_last_hitbox = []
	_set_state(State.SWING)

	var anticipation := _t(profile.anticipation_time)
	var duration := _t(atk["duration"])
	# Expected moment the blade faces forward (for AI and camera; hits come from contact).
	# "impact" is a fraction of the visible motion, converted through the swing easing.
	_impact_time = anticipation + duration * pow(atk["impact"], 1.0 / profile.swing_ease)
	_swing_end_time = anticipation + duration
	var cocked := _windup_pose(profile.backswing_amount * (1.0 + profile.anticipation_amount))
	_play([
		_seg(cocked, profile.anticipation_time, Ease.OUT, 1.5),
		_seg(_swing_pose(), atk["duration"], Ease.IN, profile.swing_ease),
	])
	swing_started.emit(attack_dir)


## Moves the blade hitbox from last frame's position to this frame's in small steps and
## reacts to the first thing it touches: a raised guard, a body, or level geometry.
## Returns true if the swing was stopped.
func _sweep_hitbox() -> bool:
	if not resolves_contacts:
		return false
	var now := hitbox_segment()
	var last: Array = _last_hitbox if not _last_hitbox.is_empty() else now
	_last_hitbox = now
	var opponents := _opponents()

	for i in range(1, HITBOX_SUBSTEPS + 1):
		var s := float(i) / HITBOX_SUBSTEPS
		var a: Vector3 = last[0].lerp(now[0], s)
		var b: Vector3 = last[1].lerp(now[1], s)
		# A raised guard in the way catches the blade before it reaches the body. It
		# catches on touch, or at the closest point if the blade only brushes past it.
		for other in opponents:
			if other.state != State.BLOCK or not other.is_facing(self):
				continue
			if not profile.physical_blocks and other.block_dir != required_block(attack_dir):
				continue
			var guard := other.hitbox_segment()
			var points := Geometry3D.get_closest_points_between_segments(a, b, guard[0], guard[1])
			var distance := points[0].distance_to(points[1])
			var previous: float = _guard_distance.get(other, INF)
			_guard_distance[other] = distance
			var touching := distance <= profile.blade_radius * 2.0 + profile.block_contact_bonus
			var passed_closest := distance > previous and previous <= profile.guard_catch_distance
			if touching or passed_closest:
				return _on_contact(other, true, points[0].lerp(points[1], 0.5))
		if _stop_hitting:
			continue
		for other in opponents:
			if other in _victims:
				continue
			var hurt := other.hurtbox()
			if hurt.is_empty():
				continue
			var edge := a.lerp(b, profile.edge_start)
			var points := Geometry3D.get_closest_points_between_segments(edge, b, hurt[0], hurt[1])
			if points[0].distance_to(points[1]) <= hurt[2] + profile.blade_radius:
				if _on_contact(other, false, points[0]):
					return true

	if profile.world_collision and _check_world_hit(last[1], now[1]):
		return true
	return false


## Resolves a contact. Returns true if the blade stops (bounce/stagger).
func _on_contact(target: MeleeCombat, blade_contact: bool, point: Vector3) -> bool:
	var result := target.decide_defense(self, attack_dir, _swing_damage, blade_contact)
	if result == Result.MISS:
		return false
	contact_decided.emit(target, result, blade_contact, point, _swing_damage)
	return apply_contact(target, result, blade_contact, point, _swing_damage)


## Plays out a decided contact on both fighters. Returns true if the blade stops.
## Also used by a network guest to replay contacts the host resolved.
func apply_contact(target: MeleeCombat, result: Result, blade_contact: bool, point: Vector3, damage: float) -> bool:
	target.apply_defense(self, result, damage)
	last_contact_blade = blade_contact
	last_swing_damage = damage
	_impact_done = true
	attack_resolved.emit(result, target)
	match result:
		Result.PARRIED:
			_spawn_spark(point)
			_freeze = _t(profile.block_stop)
			_set_state(State.STAGGER, _t(profile.parry_stagger))
			_play([
				_seg(_bounce_pose(profile.block_bounce_amount), profile.block_bounce_time, Ease.OUT, 3.0),
				_seg(POSES["stagger"], 0.2, Ease.IN_OUT),
			])
			return true
		Result.BLOCKED:
			_spawn_spark(point)
			_freeze = _t(profile.block_stop)
			# Knocked back fast, drawn in close to the body, held there as the stun.
			_recover([
				_seg(_bounce_pose(profile.block_bounce_amount), profile.block_bounce_time, Ease.OUT, 3.0),
				_seg(POSES["retract"], 0.15, Ease.OUT, 2.0),
			], profile.blocked_recoil)
			return true
	# HIT or GUARD_BREAK
	_victims.append(target)
	if profile.hit_passes_through:
		_freeze = current_hit_stop()
		_stop_hitting = not profile.attack(attack_dir)["cleave"]
		return false
	# Bite into the target, hold for the hit-stop, then rebound and recover.
	var bite := _mix(_current_pose(), _swing_pose(), profile.hit_bite)
	var back := _mix(bite, _windup_pose(1.0), profile.hit_bounce_amount)
	_recover([
		_seg(bite, profile.hit_bite_time, Ease.OUT, 2.0),
		{"pose": bite, "time": current_hit_stop(), "ease": Ease.LINEAR, "power": 1.0},
		_seg(back, profile.hit_bounce_time, Ease.OUT, 2.5),
	], 0.0)
	return true


## Swing finished without being stopped: carry through, then return to guard.
func _follow_through() -> void:
	var follow := _mix(_windup_pose(1.0), _swing_pose(), 1.0 + profile.follow_through_amount)
	_recover([_seg(follow, profile.follow_through_time, Ease.OUT, 2.0)], 0.0)


## Weapon rebounds back toward the backswing, optionally holds, then returns to guard.
func _bounce(amount: float, time: float, hold: float) -> void:
	_recover([_seg(_bounce_pose(amount), time, Ease.OUT, 2.5)], hold)


func _recover(segments: Array[Dictionary], hold: float) -> void:
	if hold > 0.0:
		segments.append(_seg(segments[-1]["pose"], hold, Ease.LINEAR))
	segments.append(_seg(POSES["idle"], profile.recover_time, Ease.IN_OUT, 2.0))
	var total := 0.0
	for segment in segments:
		total += segment["time"]
	_set_state(State.RECOVER, total)
	_play(segments)


func _stagger(duration: float) -> void:
	if is_dead():
		return
	_set_state(State.STAGGER, _t(duration))
	_play([_seg(POSES["stagger"], 0.15, Ease.OUT, 2.0)])


func _check_world_hit(last_tip: Vector3, tip: Vector3) -> bool:
	# Trace from the shoulder (weapon's parent) to the hitbox tip, so a hand already
	# inside a wall still registers, plus along the tip's path since last frame.
	var space := body.get_world_3d().direct_space_state
	var shoulder: Vector3 = weapon.get_parent().global_position
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(shoulder, tip, 1))
	if hit.is_empty() and last_tip != tip:
		hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(last_tip, tip, 1))
	if hit.is_empty():
		return false
	world_contact_decided.emit(hit["position"])
	apply_world_hit(hit["position"])
	return true


## Plays out a swing glancing off level geometry.
func apply_world_hit(point: Vector3) -> void:
	_impact_done = true
	_spawn_spark(point)
	_freeze = _t(profile.hit_stop)
	world_hit.emit(point)
	_bounce(profile.world_bounce_amount, profile.hit_bounce_time, 0.15)


func _take_damage(amount: float) -> void:
	health = maxf(health - amount, 0.0)
	if health <= 0.0 and immortal:
		health = max_health
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_set_state(State.DEAD)
		_anim_queue.clear()
		_segment = {}
		died.emit()


func _spend(amount: float) -> void:
	if infinite_stamina:
		return
	stamina = maxf(stamina - amount, 0.0)
	_regen_timer = profile.regen_delay
	stamina_changed.emit(stamina, max_stamina)


func _regen_stamina(delta: float) -> void:
	_regen_timer -= delta
	if _regen_timer > 0.0 or stamina >= max_stamina or is_attacking() or is_dead():
		return
	var rate := profile.stamina_regen * (0.5 if state == State.BLOCK else 1.0)
	stamina = minf(stamina + rate * delta, max_stamina)
	stamina_changed.emit(stamina, max_stamina)


func _set_state(new_state: State, duration := 0.0) -> void:
	state = new_state
	_timer = 0.0
	_state_duration = duration
	if _blade and _glow_material:
		_blade.material_override = _glow_material if is_attacking() else null
	state_changed.emit(new_state)


## Converts a profile duration to real seconds using the global combat speed.
func _t(seconds: float) -> float:
	return seconds / maxf(profile.combat_speed, 0.01)


func _flat_forward() -> Vector3:
	var forward := -body.global_basis.z
	forward.y = 0.0
	return forward.normalized()


# --- Weapon animation ------------------------------------------------------

func _windup_pose(amount: float) -> Array:
	return _mix(POSES["idle"], POSES["windup_" + DIR_NAMES[attack_dir]], amount)


func _swing_pose() -> Array:
	return POSES["swing_" + DIR_NAMES[attack_dir]]


## Current pose pulled back toward the windup by `amount`.
func _bounce_pose(amount: float) -> Array:
	return _mix(_current_pose(), _windup_pose(1.0), amount)


## Blends two poses; t > 1 extrapolates past `b`.
func _mix(a: Array, b: Array, t: float) -> Array:
	return [a[0].lerp(b[0], t), a[1].lerp(b[1], t)]


func _current_pose() -> Array:
	return [weapon.position, weapon.rotation_degrees]


## Builds an animation segment. `time` is in profile seconds (scaled by combat speed).
func _seg(pose: Array, time: float, ease_type: Ease, power := 2.0) -> Dictionary:
	return {"pose": pose, "time": _t(time), "ease": ease_type, "power": power}


func _play(segments: Array[Dictionary]) -> void:
	if weapon == null:
		return
	_anim_queue = segments
	_next_segment()


func _next_segment() -> void:
	while not _anim_queue.is_empty():
		_segment = _anim_queue.pop_front()
		_segment_from = _current_pose()
		_segment_t = 0.0
		if _segment["time"] > 0.0:
			return
		_snap_to(_segment["pose"])
	_segment = {}


func _update_animation(delta: float) -> void:
	if _segment.is_empty():
		return
	_segment_t = minf(_segment_t + delta / _segment["time"], 1.0)
	var k := _ease(_segment_t, _segment["ease"], _segment["power"])
	_snap_to(_mix(_segment_from, _segment["pose"], k))
	if _segment_t >= 1.0:
		_next_segment()


func _snap_to(pose: Array) -> void:
	weapon.position = pose[0]
	weapon.rotation_degrees = pose[1]


func _ease(t: float, ease_type: Ease, power: float) -> float:
	match ease_type:
		Ease.IN:
			return pow(t, power)
		Ease.OUT:
			return 1.0 - pow(1.0 - t, power)
		Ease.IN_OUT:
			return 0.5 * pow(2.0 * t, power) if t < 0.5 else 1.0 - 0.5 * pow(2.0 * (1.0 - t), power)
	return t


## World-space point along the blade (0 = base, 1 = tip).
func _blade_point(t: float) -> Vector3:
	return weapon.global_transform * Vector3(0.0, lerpf(BLADE_BASE, BLADE_TIP, t), 0.0)


func _spawn_spark(point: Vector3) -> void:
	var spark := MeshInstance3D.new()
	spark.mesh = _spark_mesh
	spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(spark)
	spark.global_position = point
	var tween := spark.create_tween()
	tween.tween_property(spark, "scale", Vector3.ONE * 2.5, 0.06)
	tween.tween_property(spark, "scale", Vector3.ZERO, 0.15)
	tween.tween_callback(spark.queue_free)
