extends Node
## Dev helper. Run with `-- --screenshot=<path>` to save a frame after startup and quit.
## Does nothing during normal play.

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			_capture(arg.trim_prefix("--screenshot="))


func _capture(path: String) -> void:
	await get_tree().create_timer(3.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("Screenshot saved: ", path)
	get_tree().quit()
