extends Node3D
## 1v1 PvP duel over the network, first to ROUNDS_TO_WIN rounds.
##
## Both peers simulate both fighters. Each peer moves its own fighter and forwards its
## combat inputs, so both simulations play the same actions. Only the host detects hits;
## it sends every contact to the guest, which replays it. The host also runs the rounds
## and periodically corrects the guest's health and stamina.

const ROUNDS_TO_WIN := 3
const COUNTDOWN := ["3", "2", "1", "FIGHT!"]

@export var player_scene: PackedScene

@onready var hud: CanvasLayer = $HUD
@onready var spawns: Array[Node3D] = [$SpawnHost, $SpawnGuest]

var fighters := {} ## peer id -> player
var local_fighter: CharacterBody3D
var remote_fighter: CharacterBody3D
var score := {}
var _round_active := false
var _vitals_timer := 0.0


func _ready() -> void:
	Engine.time_scale = 1.0
	var my_id := multiplayer.get_unique_id()
	var ids: Array[int] = [1, Net.opponent_id if Net.is_host else my_id]
	var colors := [Color(0.25, 0.45, 0.85), Color(0.8, 0.25, 0.2)]
	for i in 2:
		var fighter: CharacterBody3D = player_scene.instantiate()
		fighter.name = "Fighter%d" % ids[i]
		fighter.set_multiplayer_authority(ids[i])
		fighter.transform = spawns[i].transform
		fighter.collision_mask = 7 # world + both fighters
		$Fighters.add_child(fighter)
		fighter.combat.team = i
		fighter.combat.resolves_contacts = Net.is_host
		fighter.set_body_color(colors[i])
		fighters[ids[i]] = fighter
		score[ids[i]] = 0
		if Net.is_host:
			fighter.combat.contact_decided.connect(_send_contact.bind(fighter))
			fighter.combat.world_contact_decided.connect(_send_world_hit.bind(fighter))
			fighter.combat.died.connect(_on_fighter_died.bind(fighter))

	local_fighter = fighters[my_id]
	remote_fighter = fighters[ids[1] if my_id == ids[0] else ids[0]]
	local_fighter.input_locked = true

	var combat: MeleeCombat = local_fighter.combat
	combat.health_changed.connect(hud.set_health)
	combat.stamina_changed.connect(hud.set_stamina)
	combat.attack_resolved.connect(hud.show_attack_result)
	combat.defended.connect(hud.show_defense_result)
	remote_fighter.combat.health_changed.connect(hud.set_opponent_health)
	hud.bind_player(local_fighter)
	hud.enable_pvp()
	_update_score()
	hud.show_message("WAITING FOR OPPONENT...")

	if Net.active and not Net.is_host:
		_guest_loaded.rpc_id(1)


func _physics_process(delta: float) -> void:
	if not Net.is_host or not local_fighter.net_sync:
		return
	_vitals_timer -= delta
	if _vitals_timer <= 0.0:
		_vitals_timer = 0.2
		var vitals := []
		for id in fighters:
			var c: MeleeCombat = fighters[id].combat
			vitals.append([id, c.health, c.stamina])
		_sync_vitals.rpc(vitals)


# --- Rounds (host drives, both play) ---------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _guest_loaded() -> void:
	if Net.is_host:
		_begin_round.rpc(score)


@rpc("authority", "call_local", "reliable")
func _begin_round(scores: Dictionary) -> void:
	score = scores
	_update_score()
	var ids := fighters.keys()
	for i in ids.size():
		fighters[ids[i]].reset_for_round(spawns[i].global_transform)
	local_fighter.net_sync = true
	local_fighter.input_locked = true
	for text in COUNTDOWN:
		hud.show_message(text)
		await get_tree().create_timer(0.8).timeout
		if not is_inside_tree():
			return
	local_fighter.input_locked = false
	_round_active = true


func _on_fighter_died(fighter: CharacterBody3D) -> void:
	if not _round_active:
		return
	_round_active = false
	var winner: int = fighters.find_key(remote_fighter if fighter == local_fighter else local_fighter)
	score[winner] += 1
	var match_over: bool = score[winner] >= ROUNDS_TO_WIN
	_end_round.rpc(winner, score, match_over)
	await get_tree().create_timer(5.0 if match_over else 3.0).timeout
	if not is_inside_tree() or not Net.active:
		return
	if match_over:
		for id in score:
			score[id] = 0
	_begin_round.rpc(score)


@rpc("authority", "call_local", "reliable")
func _end_round(winner: int, scores: Dictionary, match_over: bool) -> void:
	_round_active = false
	score = scores
	_update_score()
	local_fighter.input_locked = true
	var won := winner == multiplayer.get_unique_id()
	if match_over:
		hud.show_message("VICTORY!" if won else "DEFEAT")
	else:
		hud.show_message("ROUND WON" if won else "ROUND LOST")


func _update_score() -> void:
	var mine: int = score.get(multiplayer.get_unique_id(), 0)
	var theirs: int = score.get(fighters.find_key(remote_fighter), 0)
	hud.set_score("YOU  %d  -  %d  OPPONENT      (first to %d)" % [mine, theirs, ROUNDS_TO_WIN])


# --- Contacts (host -> guest) -------------------------------------------------

func _send_contact(target: MeleeCombat, result: MeleeCombat.Result, blade_contact: bool, point: Vector3, damage: float, zones: String, attacker: CharacterBody3D) -> void:
	_replay_contact.rpc(attacker.name, target.body.name, result, blade_contact, point, damage, zones)


func _send_world_hit(point: Vector3, attacker: CharacterBody3D) -> void:
	_replay_world_hit.rpc(attacker.name, point)


@rpc("authority", "call_remote", "reliable")
func _replay_contact(attacker_name: String, target_name: String, result: int, blade_contact: bool, point: Vector3, damage: float, zones: String) -> void:
	var attacker: MeleeCombat = $Fighters.get_node(attacker_name).combat
	var target: MeleeCombat = $Fighters.get_node(target_name).combat
	attacker.apply_contact(target, result as MeleeCombat.Result, blade_contact, point, damage, zones)


@rpc("authority", "call_remote", "reliable")
func _replay_world_hit(attacker_name: String, point: Vector3) -> void:
	$Fighters.get_node(attacker_name).combat.apply_world_hit(point)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_vitals(vitals: Array) -> void:
	for entry in vitals:
		if not fighters.has(entry[0]):
			continue
		var c: MeleeCombat = fighters[entry[0]].combat
		c.health = entry[1]
		c.stamina = entry[2]
		c.emit_state()
