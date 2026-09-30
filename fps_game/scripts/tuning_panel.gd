extends Control
## In-game combat tuning (F1). Builds a slider for every ranged float and a checkbox for
## every bool exported by the CombatProfile, grouped by the profile's export groups.
## Changes apply live to the shared profile; Save writes them back to its .tres file
## (works when running from the editor).

@export var profile: CombatProfile

var _rows: VBoxContainer
var _status: Label
var _time_scale_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()
	_build_ui()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_tuning"):
		visible = not visible
		if visible:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif not get_tree().paused:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


# --- UI construction -------------------------------------------------------

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -440.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.97)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	panel.add_child(layout)

	var title := Label.new()
	title.text = "COMBAT TUNING  (F1 to close)"
	title.add_theme_font_size_override("font_size", 18)
	layout.add_child(title)

	var buttons := HBoxContainer.new()
	layout.add_child(buttons)
	_add_button(buttons, "Save", _save)
	_add_button(buttons, "Revert to saved", _revert)
	_add_button(buttons, "Defaults", _reset_defaults)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.modulate = Color(0.7, 0.9, 0.7)
	layout.add_child(_status)

	# Slow motion is a debug aid, not part of the profile.
	var time_row := HBoxContainer.new()
	layout.add_child(time_row)
	var time_name := Label.new()
	time_name.text = "Slow motion (time scale)"
	time_name.custom_minimum_size.x = 190
	time_name.add_theme_font_size_override("font_size", 13)
	time_row.add_child(time_name)
	var time_slider := HSlider.new()
	time_slider.min_value = 0.1
	time_slider.max_value = 1.0
	time_slider.step = 0.05
	time_slider.value = Engine.time_scale
	time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	time_row.add_child(time_slider)
	_time_scale_label = Label.new()
	_time_scale_label.custom_minimum_size.x = 48
	_time_scale_label.text = "%.2f" % Engine.time_scale
	_time_scale_label.add_theme_font_size_override("font_size", 13)
	time_row.add_child(_time_scale_label)
	time_slider.value_changed.connect(func(value: float) -> void:
		Engine.time_scale = value
		_time_scale_label.text = "%.2f" % value)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	_build_rows()


func _build_rows() -> void:
	for child in _rows.get_children():
		child.queue_free()
	if profile == null:
		return
	# Headers are only added once a tunable follows them, which skips engine groups.
	var pending_header := ""
	for prop in profile.get_property_list():
		var usage: int = prop["usage"]
		if usage & PROPERTY_USAGE_GROUP:
			pending_header = prop["name"]
		elif usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR:
			if pending_header != "":
				_add_header(pending_header)
				pending_header = ""
			if prop["type"] == TYPE_FLOAT and prop["hint"] == PROPERTY_HINT_RANGE:
				_add_slider(prop["name"], prop["hint_string"])
			elif prop["type"] == TYPE_BOOL:
				_add_checkbox(prop["name"])


func _add_header(text: String) -> void:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_size_override("font_size", 14)
	label.modulate = Color(1.0, 0.8, 0.4)
	if _rows.get_child_count() > 0:
		var spacer := Control.new()
		spacer.custom_minimum_size.y = 6
		_rows.add_child(spacer)
	_rows.add_child(label)


func _add_slider(property: String, hint: String) -> void:
	var parts := hint.split(",")
	var row := HBoxContainer.new()
	_rows.add_child(row)

	var name_label := Label.new()
	name_label.text = property.capitalize()
	name_label.custom_minimum_size.x = 190
	name_label.add_theme_font_size_override("font_size", 13)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = float(parts[0])
	slider.max_value = float(parts[1])
	slider.step = float(parts[2]) if parts.size() > 2 else 0.01
	slider.value = profile.get(property)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size.x = 48
	value_label.text = _format(slider.value, slider.step)
	value_label.add_theme_font_size_override("font_size", 13)
	row.add_child(value_label)

	slider.value_changed.connect(func(value: float) -> void:
		profile.set(property, value)
		value_label.text = _format(value, slider.step)
		_status.text = "Unsaved changes")


func _add_checkbox(property: String) -> void:
	var box := CheckBox.new()
	box.text = property.capitalize()
	box.button_pressed = profile.get(property)
	box.add_theme_font_size_override("font_size", 13)
	box.toggled.connect(func(on: bool) -> void:
		profile.set(property, on)
		_status.text = "Unsaved changes")
	_rows.add_child(box)


func _add_button(parent: Control, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)


func _format(value: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % roundi(value)
	if step >= 0.01:
		return "%.2f" % value
	return "%.3f" % value


# --- Actions ---------------------------------------------------------------

func _save() -> void:
	var error := ResourceSaver.save(profile)
	_status.text = "Saved to %s" % profile.resource_path if error == OK else "Save failed (error %d)" % error


func _revert() -> void:
	var saved := ResourceLoader.load(profile.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_copy_values(saved, profile)
	_build_rows()
	_status.text = "Reverted to saved values"


func _reset_defaults() -> void:
	_copy_values(CombatProfile.new(), profile)
	_build_rows()
	_status.text = "Defaults loaded (not saved yet)"


func _copy_values(from: Resource, to: Resource) -> void:
	for prop in to.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and prop["usage"] & PROPERTY_USAGE_STORAGE:
			to.set(prop["name"], from.get(prop["name"]))
