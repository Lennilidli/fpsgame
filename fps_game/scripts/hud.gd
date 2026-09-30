extends CanvasLayer
## On-screen UI plus pause and game-over menus. Runs while the tree is paused.
##
## The direction indicator around the crosshair shows the selected direction (white),
## a charging attack (yellow), the raised block (blue), and where to block an
## incoming enemy attack (red, turning green once the block matches).

const COLOR_IDLE := Color(1, 1, 1, 0.18)
const COLOR_SELECTED := Color(1, 1, 1, 0.75)
const COLOR_WINDUP := Color(1.0, 0.85, 0.3)
const COLOR_SWING := Color(1.0, 0.55, 0.15)
const COLOR_BLOCK := Color(0.4, 0.7, 1.0)
const COLOR_THREAT := Color(1.0, 0.2, 0.2)
const COLOR_THREAT_COVERED := Color(0.3, 1.0, 0.4)

@export var show_block_hints := true ## Red arrow showing where to block incoming attacks.
@export var threat_range := 4.0

@onready var health_bar: ProgressBar = $HealthBar
@onready var health_label: Label = $HealthBar/HealthLabel
@onready var stamina_bar: ProgressBar = $StaminaBar
@onready var wave_label: Label = $WaveLabel
@onready var kills_label: Label = $KillsLabel
@onready var message_label: Label = $MessageLabel
@onready var result_label: Label = $ResultLabel
@onready var damage_flash: ColorRect = $DamageFlash
@onready var pause_panel: Control = $PausePanel
@onready var game_over_panel: Control = $GameOverPanel
@onready var game_over_stats: Label = $GameOverPanel/Box/Stats
@onready var arrows := {
	MeleeCombat.Dir.OVERHEAD: $DirIndicator/Overhead,
	MeleeCombat.Dir.THRUST: $DirIndicator/Thrust,
	MeleeCombat.Dir.LEFT: $DirIndicator/Left,
	MeleeCombat.Dir.RIGHT: $DirIndicator/Right,
}

var _player: Node3D
var _game_over := false
var _message_tween: Tween
var _result_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	pause_panel.hide()
	game_over_panel.hide()
	message_label.modulate.a = 0.0
	result_label.modulate.a = 0.0
	$PausePanel/Box/Resume.pressed.connect(_set_paused.bind(false))
	$PausePanel/Box/Quit.pressed.connect(get_tree().quit)
	$GameOverPanel/Box/Restart.pressed.connect(_restart)
	$GameOverPanel/Box/Quit.pressed.connect(get_tree().quit)


func bind_player(player: Node3D) -> void:
	_player = player


func _unhandled_input(event: InputEvent) -> void:
	if _game_over:
		return
	if event.is_action_pressed("pause"):
		_set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not get_tree().paused and not $TuningPanel.is_open():
		# Re-grab the mouse after alt-tabbing out of the window.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(_delta: float) -> void:
	if _player == null or _game_over:
		return
	_update_dir_indicator()


func _update_dir_indicator() -> void:
	var combat: MeleeCombat = _player.combat
	for arrow in arrows.values():
		arrow.color = COLOR_IDLE

	match combat.state:
		MeleeCombat.State.WINDUP:
			arrows[combat.attack_dir].color = COLOR_SELECTED.lerp(COLOR_WINDUP, 0.4 + 0.6 * combat.charge())
		MeleeCombat.State.SWING:
			arrows[combat.attack_dir].color = COLOR_SWING
		MeleeCombat.State.BLOCK:
			arrows[combat.block_dir].color = COLOR_BLOCK
		MeleeCombat.State.IDLE, MeleeCombat.State.RECOVER:
			arrows[_player.intended_dir].color = COLOR_SELECTED

	if show_block_hints:
		var threat := _nearest_threat(combat)
		if threat:
			var needed := MeleeCombat.required_block(threat.attack_dir)
			var covered := combat.state == MeleeCombat.State.BLOCK and combat.block_dir == needed
			arrows[needed].color = COLOR_THREAT_COVERED if covered else COLOR_THREAT


## The closest enemy in front of the player that is winding up or swinging.
func _nearest_threat(player_combat: MeleeCombat) -> MeleeCombat:
	var best: MeleeCombat = null
	var best_distance := threat_range
	var forward := -_player.global_basis.z
	for enemy in get_tree().get_nodes_in_group("enemies"):
		var enemy_combat: MeleeCombat = enemy.combat
		if not enemy_combat.is_attacking():
			continue
		var to_enemy: Vector3 = enemy.global_position - _player.global_position
		to_enemy.y = 0.0
		var distance := to_enemy.length()
		if distance < best_distance and forward.angle_to(to_enemy) < deg_to_rad(80.0):
			best = enemy_combat
			best_distance = distance
	return best


func set_health(current: float, maximum: float) -> void:
	health_bar.max_value = maximum
	health_bar.value = current
	health_label.text = "%d / %d" % [ceili(current), ceili(maximum)]


func set_stamina(current: float, maximum: float) -> void:
	stamina_bar.max_value = maximum
	stamina_bar.value = current


func set_wave(wave: int) -> void:
	wave_label.text = "WAVE %d" % wave


func set_kills(kills: int) -> void:
	kills_label.text = "KILLS %d" % kills


## Feedback for the player's own swings.
func show_attack_result(result: MeleeCombat.Result, _target: MeleeCombat) -> void:
	match result:
		MeleeCombat.Result.HIT:
			_show_result("HIT", Color.WHITE)
		MeleeCombat.Result.BLOCKED:
			_show_result("BLOCKED", Color(0.6, 0.75, 0.9))
		MeleeCombat.Result.PARRIED:
			_show_result("PARRIED - STAGGERED!", Color(1.0, 0.35, 0.3))
		MeleeCombat.Result.GUARD_BREAK:
			_show_result("GUARD BREAK!", Color(1.0, 0.8, 0.2))


## Feedback when the player is attacked.
func show_defense_result(result: MeleeCombat.Result, _attacker: MeleeCombat) -> void:
	match result:
		MeleeCombat.Result.HIT:
			_flash_damage()
		MeleeCombat.Result.BLOCKED:
			_show_result("BLOCK", COLOR_BLOCK)
		MeleeCombat.Result.PARRIED:
			_show_result("PARRY!", Color(1.0, 0.85, 0.2))
		MeleeCombat.Result.GUARD_BREAK:
			_show_result("GUARD BROKEN", Color(1.0, 0.3, 0.3))
			_flash_damage()


func show_message(text: String) -> void:
	message_label.text = text
	if _message_tween:
		_message_tween.kill()
	message_label.modulate.a = 1.0
	_message_tween = create_tween()
	_message_tween.tween_interval(1.6)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.6)


func show_game_over(wave: int, kills: int) -> void:
	_game_over = true
	game_over_stats.text = "You reached wave %d with %d kills." % [wave, kills]
	game_over_panel.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _show_result(text: String, color: Color) -> void:
	result_label.text = text
	result_label.modulate = color
	if _result_tween:
		_result_tween.kill()
	_result_tween = create_tween()
	_result_tween.tween_interval(0.5)
	_result_tween.tween_property(result_label, "modulate:a", 0.0, 0.3)


func _flash_damage() -> void:
	damage_flash.color.a = 0.35
	create_tween().tween_property(damage_flash, "color:a", 0.0, 0.4)


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	pause_panel.visible = paused
	var free_mouse: bool = paused or $TuningPanel.is_open()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if free_mouse else Input.MOUSE_MODE_CAPTURED


func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
