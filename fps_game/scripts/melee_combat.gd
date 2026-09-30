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

const DIR_NAMES := ["overhead", "thrust", "left", "right"]

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

## Blade span along the weapon's local +Y, used for wall collision and sparks.
const BLADE_BASE := 0.12
const BLADE_TIP := 0.95

@export var profile: CombatProfile
@export var team := 0
@export var weapon: Node3D
@export var glow_on_windup := false ## Make the blade glow while attacking (enemy telegraph).

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
## Push applied by hits; bodies add this to their velocity.
var knockback := Vector3.ZERO

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
var _last_tip := Vector3.INF
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


## Extra velocity from knockback and the swing lunge, to add on top of movement.
func movement_bonus() -> Vector3:
	var bonus := knockback
	if state == State.SWING and not _impact_done and _timer >= _t(profile.anticipation_time):
		bonus += _flat_forward() * profile.swing_lunge
	return bonus


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


func heal(amount: float) -> void:
	if is_dead():
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


## Called on the defender by an attacker's swing. Returns what happened.
func receive_attack(attacker: MeleeCombat, dir: Dir, damage: float) -> Result:
	if is_dead():
		return Result.MISS

	var impact := attacker.profile
	var to_attacker := attacker.body.global_position - body.global_position
	to_attacker.y = 0.0
	var push := -to_attacker.normalized() if to_attacker.length() > 0.01 else Vector3.ZERO
	var facing := to_attacker.length() < 0.01 or _flat_forward().angle_to(to_attacker) < deg_to_rad(80.0)

	var result: Result
	if state == State.BLOCK and facing and block_dir == required_block(dir):
		if _block_time <= _t(profile.parry_window):
			result = Result.PARRIED
		else:
			_spend(damage * profile.block_cost_ratio)
			_freeze = _t(impact.block_stop)
			knockback = push * impact.hit_knockback * 0.4
			if stamina <= 0.0:
				result = Result.GUARD_BREAK
				_take_damage(damage * 0.5)
				_stagger(profile.guard_break_stagger)
			else:
				result = Result.BLOCKED
	else:
		result = Result.HIT
		_freeze = _t(impact.hit_stop)
		knockback = push * impact.hit_knockback
		_take_damage(damage)
		if state != State.SWING:
			_stagger(profile.flinch_time)

	defended.emit(result, attacker)
	return result


# --- State machine ---------------------------------------------------------

func _physics_process(delta: float) -> void:
	knockback = knockback.move_toward(Vector3.ZERO, 10.0 * delta)
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
			# Walls can stop the blade anywhere in the strike, even after a miss.
			if profile.world_collision and _timer >= _t(profile.anticipation_time) and _check_world_hit():
				return
			if not _impact_done:
				if _timer >= _impact_time:
					_impact_done = true
					_resolve_impact()
			if state == State.SWING and _timer >= _swing_end_time:
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
	_regen_stamina(delta)


func _begin_swing() -> void:
	var atk := profile.attack(attack_dir)
	_spend(atk["stamina"])
	_swing_damage = base_damage * atk["damage"] * lerpf(profile.charge_min_damage, 1.0, charge())
	_impact_done = false
	_last_tip = Vector3.INF
	_set_state(State.SWING)

	var anticipation := _t(profile.anticipation_time)
	var duration := _t(atk["duration"])
	# "impact" is a fraction of the visible motion; convert it through the swing easing
	# so the hit lands when the blade is actually there.
	_impact_time = anticipation + duration * pow(atk["impact"], 1.0 / profile.swing_ease)
	_swing_end_time = anticipation + duration
	var cocked := _windup_pose(profile.backswing_amount * (1.0 + profile.anticipation_amount))
	_play([
		_seg(cocked, profile.anticipation_time, Ease.OUT, 1.5),
		_seg(_swing_pose(), atk["duration"], Ease.IN, profile.swing_ease),
	])
	swing_started.emit(attack_dir)


func _resolve_impact() -> void:
	var atk := profile.attack(attack_dir)
	var forward := _flat_forward()
	var max_distance: float = profile.reach + atk["reach"] + 0.4 # 0.4 = target body radius

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
		match result:
			Result.PARRIED:
				_spawn_spark(_blade_point(0.7))
				_freeze = _t(profile.block_stop)
				_set_state(State.STAGGER, _t(profile.parry_stagger))
				_play([
					_seg(_bounce_pose(profile.block_bounce_amount), profile.block_bounce_time, Ease.OUT, 2.5),
					_seg(POSES["stagger"], 0.2, Ease.IN_OUT),
				])
				return
			Result.BLOCKED:
				_spawn_spark(_blade_point(0.7))
				_freeze = _t(profile.block_stop)
				_bounce(profile.block_bounce_amount, profile.block_bounce_time, profile.blocked_recoil)
				return
			Result.HIT, Result.GUARD_BREAK:
				_freeze = _t(profile.hit_stop)
				if not profile.hit_passes_through:
					_bounce(profile.hit_bounce_amount, profile.hit_bounce_time, 0.0)
					return


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


func _check_world_hit() -> bool:
	if weapon == null:
		return false
	# Trace from the shoulder (weapon's parent) to the tip, so a hand already inside
	# a wall still registers, plus along the tip's path since last frame.
	var space := body.get_world_3d().direct_space_state
	var tip := _blade_point(1.0)
	var shoulder: Vector3 = weapon.get_parent().global_position
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(shoulder, tip, 1))
	if hit.is_empty() and _last_tip != Vector3.INF:
		hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(_last_tip, tip, 1))
	_last_tip = tip
	if hit.is_empty():
		return false
	_impact_done = true
	_spawn_spark(hit["position"])
	_freeze = _t(profile.hit_stop)
	world_hit.emit(hit["position"])
	_bounce(profile.world_bounce_amount, profile.hit_bounce_time, 0.15)
	return true


func _take_damage(amount: float) -> void:
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_set_state(State.DEAD)
		_anim_queue.clear()
		_segment = {}
		died.emit()


func _spend(amount: float) -> void:
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
