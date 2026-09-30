extends CanvasLayer
## On-screen UI plus pause and game-over menus. Runs while the tree is paused.
##
## The direction indicator around the crosshair shows the selected direction (white),
## a charging attack (yellow), the raised block (blue), a queued next action (faint
## yellow/blue), and where to block an incoming enemy attack (red, green once matched).

const COLOR_IDLE := Color(1, 1, 1, 0.18)
const COLOR_SELECTED := Color(1, 1, 1, 0.75)
const COLOR_WINDUP := Color(1.0, 0.85, 0.3)
const COLOR_SWING := Color(1.0, 0.55, 0.15)
const COLOR_BLOCK := Color(0.4, 0.7, 1.0)
const COLOR_THREAT := Color(1.0, 0.2, 0.2)
const COLOR_QUEUED_ATTACK := Color(1.0, 0.85, 0.3, 0.45)
const COLOR_QUEUED_BLOCK := Color(0.4, 0.7, 1.0, 0.45)
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
@onready var riposte_label: Label = $RiposteLabel
@onready var damage_flash: ColorRect = $DamageFlash
@onready var pause_panel: Control = $PausePanel
@onready var game_over_panel: Control = $GameOverPanel
@onready var game_over_stats: Label = $GameOverPanel/Box/Stats
@onready var combat_log: Label = $CombatLog
@onready var score_label: Label = $ScoreLabel
@onready var opponent_bar: ProgressBar = $OpponentBar
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
var _log_lines: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	pause_panel.hide()
	game_over_panel.hide()
	message_label.modulate.a = 0.0
	result_label.modulate.a = 0.0
	$PausePanel/Box/Resume.pressed.connect(_set_paused.bind(false))
	$PausePanel/Box/Quit.pressed.connect(_quit)
	$GameOverPanel/Box/Restart.pressed.connect(_restart)
	$GameOverPanel/Box/Quit.pressed.connect(_quit)
	score_label.hide()
	opponent_bar.hide()
	$PausePanel/Box/MainMenu.pressed.connect(_to_main_menu)
	$GameOverPanel/Box/MainMenu.pressed.connect(_to_main_menu)
	combat_log.hide()


func bind_player(player: Node3D) -> void:
	_player = player


## Training mode: hides wave info, enables the F2 options panel and the combat log.
func enable_training(settings: Object) -> void:
	wave_label.hide()
	kills_label.hide()
	combat_log.show()
	$TrainingPanel.set_target(settings)
	var combat: MeleeCombat = _player.combat
	combat.attack_resolved.connect(_log_attack)
	combat.defended.connect(_log_defense)
	combat.world_hit.connect(func(_point): _log("Your %s glanced off the wall" % MeleeCombat.DIR_NAMES[combat.attack_dir]))
	_log("F1 combat tuning  |  F2 training options")


func _unhandled_input(event: InputEvent) -> void:
	if _game_over:
		return
	if event.is_action_pressed("pause"):
		_set_paused(not pause_panel.visible)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not pause_panel.visible and not _any_panel_open():
		# Re-grab the mouse after alt-tabbing out of the window.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(_delta: float) -> void:
	if _player == null or _game_over:
		return
	_update_dir_indicator()
	# Riposte ready after a parry: pulse until the counter swing is released or it expires.
	var riposte: bool = _player.combat.has_riposte()
	riposte_label.visible = riposte
	if riposte:
		riposte_label.modulate.a = 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.02)


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

	# Buffered next action shows as a faint arrow.
	if combat.queued == MeleeCombat.Queued.WINDUP:
		arrows[combat.queued_dir].color = COLOR_QUEUED_ATTACK
	elif combat.queued == MeleeCombat.Queued.BLOCK:
		arrows[combat.queued_dir].color = COLOR_QUEUED_BLOCK

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


func _any_panel_open() -> bool:
	for panel in get_tree().get_nodes_in_group("tuning_panels"):
		if panel.visible:
			return true
	return false


# --- Combat log (training) -------------------------------------------------

func _log_attack(result: MeleeCombat.Result, _target: MeleeCombat) -> void:
	var combat: MeleeCombat = _player.combat
	var swing := "%s  charge %d%%" % [MeleeCombat.DIR_NAMES[combat.attack_dir].capitalize(), roundi(combat.last_swing_charge * 100.0)]
	if combat.last_swing_riposte:
		swing += "  RIPOSTE"
	match result:
		MeleeCombat.Result.MISS:
			_log("%s  -> miss" % swing)
		MeleeCombat.Result.HIT:
			_log("%s  -> HIT %d dmg" % [swing, roundi(combat.last_swing_damage)])
		MeleeCombat.Result.BLOCKED:
			_log("%s  -> blocked" % swing)
		MeleeCombat.Result.PARRIED:
			_log("%s  -> PARRIED, you are staggered" % swing)
		MeleeCombat.Result.GUARD_BREAK:
			_log("%s  -> GUARD BREAK" % swing)


func _log_defense(result: MeleeCombat.Result, attacker: MeleeCombat) -> void:
	var combat: MeleeCombat = _player.combat
	var incoming: String = MeleeCombat.DIR_NAMES[attacker.attack_dir].capitalize()
	var needed: String = MeleeCombat.DIR_NAMES[MeleeCombat.required_block(attacker.attack_dir)]
	var block_info := "block was up %d ms (parry window %d ms)" % [roundi(combat.last_block_age * 1000.0), roundi(combat._t(combat.profile.parry_window) * 1000.0)]
	match result:
		MeleeCombat.Result.HIT:
			if combat.last_block_age >= 0.0:
				_log("Enemy %s HIT you: you blocked %s, needed %s" % [incoming, MeleeCombat.DIR_NAMES[combat.block_dir], needed])
			else:
				_log("Enemy %s HIT you: no block (needed %s)" % [incoming, needed])
		MeleeCombat.Result.BLOCKED:
			_log("Blocked enemy %s: %s" % [incoming, block_info])
		MeleeCombat.Result.PARRIED:
			_log("PARRIED enemy %s: %s" % [incoming, block_info])
		MeleeCombat.Result.GUARD_BREAK:
			_log("Guard broken by enemy %s (out of stamina)" % incoming)


func _log(line: String) -> void:
	_log_lines.append(line)
	if _log_lines.size() > 8:
		_log_lines.pop_front()
	combat_log.text = "\n".join(_log_lines)


## PvP mode: score and opponent health, no wave info, fixed settings (no tuning
## panels), no block hints, and Esc opens the menu without pausing the match.
func enable_pvp() -> void:
	wave_label.hide()
	kills_label.hide()
	score_label.show()
	opponent_bar.show()
	show_block_hints = false
	$TuningPanel.set_target(null)
	$TuningPanel.hide()
	$ControlsLabel.text = $ControlsLabel.text.replace("\nF1 = combat tuning panel, F2 = training options", "")
	$ControlsLabel.text = $ControlsLabel.text.replace("\nRed arrow = incoming attack, block there", "")
	$PausePanel/Box/MainMenu.text = "Leave Match"


func set_score(text: String) -> void:
	score_label.text = text


func set_opponent_health(current: float, maximum: float) -> void:
	opponent_bar.max_value = maximum
	opponent_bar.value = current


func _quit() -> void:
	if Net.active:
		Net.leave()
	get_tree().quit()


func _to_main_menu() -> void:
	if Net.active:
		Net.leave("You left the match.")
		return
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _set_paused(paused: bool) -> void:
	# A network match keeps running; the menu only frees the mouse (which stops input).
	if not Net.active:
		get_tree().paused = paused
	pause_panel.visible = paused
	var free_mouse := paused or _any_panel_open()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if free_mouse else Input.MOUSE_MODE_CAPTURED


func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
