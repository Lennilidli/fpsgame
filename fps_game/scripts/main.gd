extends Node3D
## Game loop: spawns waves of enemies, handles win/lose flow.
## The arena navmesh is pre-baked; after editing the level, select NavigationRegion3D
## in the editor and click "Bake NavigationMesh".

@export var enemy_scene: PackedScene
@export var first_wave_size := 1
@export var waves_per_extra_enemy := 2 ## Wave size grows by one every N waves.
@export var spawn_interval := 1.5
@export var time_between_waves := 4.0
@export var wave_clear_heal := 35.0

@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var spawn_points: Array[Node] = $SpawnPoints.get_children()

var wave := 0
var kills := 0
var _alive := 0
var _spawning := false
var _game_over := false


func _ready() -> void:
	var combat: MeleeCombat = player.combat
	combat.health_changed.connect(hud.set_health)
	combat.stamina_changed.connect(hud.set_stamina)
	combat.attack_resolved.connect(hud.show_attack_result)
	combat.defended.connect(hud.show_defense_result)
	combat.died.connect(_on_player_died)
	combat.emit_state()
	hud.bind_player(player)
	hud.set_kills(kills)

	await get_tree().create_timer(1.5, false).timeout
	_start_next_wave()


func _start_next_wave() -> void:
	if _game_over:
		return
	wave += 1
	hud.set_wave(wave)
	hud.show_message("WAVE %d" % wave)

	_spawning = true
	var count := first_wave_size + floori(float(wave - 1) / waves_per_extra_enemy)
	for i in count:
		if _game_over:
			return
		_spawn_enemy()
		await get_tree().create_timer(spawn_interval, false).timeout
	_spawning = false
	_check_wave_cleared()


func _spawn_enemy() -> void:
	var enemy := enemy_scene.instantiate()
	enemy.target = player
	enemy.apply_difficulty(wave)
	var point: Node3D = spawn_points.pick_random()
	enemy.position = point.global_position + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
	enemy.died.connect(_on_enemy_died)
	add_child(enemy)
	_alive += 1


func _on_enemy_died(_enemy: Node) -> void:
	kills += 1
	_alive -= 1
	hud.set_kills(kills)
	_check_wave_cleared()


func _check_wave_cleared() -> void:
	if _spawning or _alive > 0 or _game_over:
		return
	player.combat.heal(wave_clear_heal)
	hud.show_message("WAVE CLEARED  +%d HP" % wave_clear_heal)
	await get_tree().create_timer(time_between_waves, false).timeout
	_start_next_wave()


func _on_player_died() -> void:
	_game_over = true
	hud.show_game_over(wave, kills)
