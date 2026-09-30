extends Control
## Main menu: pick a mode.

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	Engine.time_scale = 1.0
	$Box/Training.pressed.connect(get_tree().change_scene_to_file.bind("res://scenes/training.tscn"))
	$Box/Waves.pressed.connect(get_tree().change_scene_to_file.bind("res://scenes/main.tscn"))
	$Box/Lan.pressed.connect(get_tree().change_scene_to_file.bind("res://scenes/lobby.tscn"))
	$Box/Quit.pressed.connect(get_tree().quit)
	$Box/Training.grab_focus()
