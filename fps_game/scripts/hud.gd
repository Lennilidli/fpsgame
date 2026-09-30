extends CanvasLayer
## On-screen UI plus pause and game-over menus. Runs while the tree is paused.

@onready var crosshair: Control = $Crosshair
@onready var health_bar: ProgressBar = $HealthBar
@onready var health_label: Label = $HealthBar/HealthLabel
@onready var ammo_label: Label = $AmmoLabel
@onready var reload_label: Label = $ReloadLabel
@onready var wave_label: Label = $WaveLabel
@onready var kills_label: Label = $KillsLabel
@onready var message_label: Label = $MessageLabel
@onready var damage_flash: ColorRect = $DamageFlash
@onready var pause_panel: Control = $PausePanel
@onready var game_over_panel: Control = $GameOverPanel
@onready var game_over_stats: Label = $GameOverPanel/Box/Stats

var _game_over := false
var _message_tween: Tween
var _crosshair_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	pause_panel.hide()
	game_over_panel.hide()
	reload_label.hide()
	message_label.modulate.a = 0.0
	$PausePanel/Box/Resume.pressed.connect(_set_paused.bind(false))
	$PausePanel/Box/Quit.pressed.connect(get_tree().quit)
	$GameOverPanel/Box/Restart.pressed.connect(_restart)
	$GameOverPanel/Box/Quit.pressed.connect(get_tree().quit)


func _unhandled_input(event: InputEvent) -> void:
	if _game_over:
		return
	if event.is_action_pressed("pause"):
		_set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not get_tree().paused:
		# Re-grab the mouse after alt-tabbing out of the window.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_health(current: int, maximum: int) -> void:
	health_bar.max_value = maximum
	health_bar.value = current
	health_label.text = "%d / %d" % [current, maximum]


func set_ammo(in_mag: int, reserve: int) -> void:
	ammo_label.text = "%d / %d" % [in_mag, reserve]
	ammo_label.modulate = Color(1, 0.35, 0.3) if in_mag == 0 else Color.WHITE


func set_reloading(is_reloading: bool) -> void:
	reload_label.visible = is_reloading


func set_wave(wave: int) -> void:
	wave_label.text = "WAVE %d" % wave


func set_kills(kills: int) -> void:
	kills_label.text = "KILLS %d" % kills


func show_message(text: String) -> void:
	message_label.text = text
	if _message_tween:
		_message_tween.kill()
	message_label.modulate.a = 1.0
	_message_tween = create_tween()
	_message_tween.tween_interval(1.6)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.6)


func show_hit_marker(killed: bool) -> void:
	if _crosshair_tween:
		_crosshair_tween.kill()
	crosshair.modulate = Color(1, 0.2, 0.2) if killed else Color(1, 0.85, 0.3)
	crosshair.scale = Vector2.ONE * (1.6 if killed else 1.25)
	_crosshair_tween = create_tween().set_parallel()
	_crosshair_tween.tween_property(crosshair, "modulate", Color.WHITE, 0.15)
	_crosshair_tween.tween_property(crosshair, "scale", Vector2.ONE, 0.15)


func flash_damage() -> void:
	damage_flash.color.a = 0.35
	create_tween().tween_property(damage_flash, "color:a", 0.0, 0.4)


func show_game_over(wave: int, kills: int) -> void:
	_game_over = true
	game_over_stats.text = "You reached wave %d with %d kills." % [wave, kills]
	game_over_panel.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	pause_panel.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED


func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
