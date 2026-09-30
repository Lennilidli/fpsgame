extends Node3D
## Training ground: no waves, no death. Every export here shows up in the F2 panel
## and applies live to the player and the dummies.

@export var enemy_scene: PackedScene

@export_group("Player")
@export var invulnerable := true:
	set(value):
		invulnerable = value
		_apply_player_settings()
@export var infinite_stamina := false:
	set(value):
		infinite_stamina = value
		_apply_player_settings()
## Show the enemy block hint (red arrow) while training.
@export var block_hints := true:
	set(value):
		block_hints = value
		if is_node_ready():
			hud.show_block_hints = value

@export_group("Attacker dummy")
@export_enum("Random", "Cycle", "Overhead", "Thrust", "Left", "Right") var attack_pattern := 0
## Seconds between the attacker's swings.
@export_range(0.5, 6.0, 0.1) var attack_interval := 2.5
## How long the attacker charges before releasing.
@export_range(0.3, 2.0, 0.05) var attack_hold := 0.8
@export var attacker_feints := false

@export_group("Blocker dummy")
@export_enum("Hold one direction", "Cycle", "React to your windup") var block_mode := 2
@export_enum("Overhead", "Thrust", "Left", "Right") var block_direction := 0
@export_range(0.5, 5.0, 0.1) var block_cycle_time := 1.5
## React mode: chance to pick the correct block.
@export_range(0.0, 1.0, 0.05) var block_skill := 0.7
## React mode: delay before the block goes up.
@export_range(0.05, 0.8, 0.01) var block_reaction := 0.3
## React mode: chance to time a parry.
@export_range(0.0, 1.0, 0.05) var block_parry_chance := 0.2

@export_group("Sparring partner")
## Spawns a full AI opponent in the ring.
@export var sparring_enabled := false:
	set(value):
		sparring_enabled = value
		if is_node_ready():
			_update_sparring_partner()
@export_range(1, 10, 1) var sparring_level := 1:
	set(value):
		sparring_level = value
		if is_node_ready() and is_instance_valid(_partner):
			_partner.apply_difficulty(value)

@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var sparring_spawn: Marker3D = $SparringSpawn

var _partner: Node3D


func _ready() -> void:
	var combat: MeleeCombat = player.combat
	combat.health_changed.connect(hud.set_health)
	combat.stamina_changed.connect(hud.set_stamina)
	combat.attack_resolved.connect(hud.show_attack_result)
	combat.defended.connect(hud.show_defense_result)
	_apply_player_settings()
	combat.emit_state()
	hud.bind_player(player)
	hud.show_block_hints = block_hints
	hud.enable_training(self)

	for dummy in get_tree().get_nodes_in_group("dummies"):
		dummy.settings = self
		dummy.target = player
	hud.show_message("TRAINING GROUND")


func _apply_player_settings() -> void:
	if not is_node_ready():
		return
	player.combat.immortal = invulnerable
	player.combat.infinite_stamina = infinite_stamina


func _update_sparring_partner() -> void:
	if sparring_enabled and not is_instance_valid(_partner):
		_partner = enemy_scene.instantiate()
		_partner.target = player
		_partner.apply_difficulty(sparring_level)
		_partner.position = sparring_spawn.global_position
		add_child(_partner)
		_partner.combat.immortal = true
		hud.show_message("SPARRING PARTNER (level %d)" % sparring_level)
	elif not sparring_enabled and is_instance_valid(_partner):
		_partner.queue_free()
		_partner = null
