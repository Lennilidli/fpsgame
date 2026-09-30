extends Control
## Generic live-tuning panel. Builds a control for every exported property of its target:
## ranged float/int -> slider, bool -> checkbox, enum -> dropdown, grouped by export groups.
##
## The target is either `profile` (a CombatProfile resource, with Save/Revert/Defaults
## writing back to its .tres file; saving works when running from the editor) or any
## object passed to set_target() (changes apply live only).

@export var profile: CombatProfile
@export var title := "COMBAT TUNING"
@export var toggle_action := "toggle_tuning"
@export var dock_left := false
@export var show_time_scale := true

var _target: Object
var _rows: VBoxContainer
var _status: Label
var _time_scale_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("tuning_panels")
	hide()
	_target = profile
	_build_ui()


func is_open() -> bool:
	return visible


## Points the panel at another object and rebuilds its controls.
func set_target(target: Object) -> void:
	_target = target
	_build_rows()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(toggle_action) or _target == null:
		return
	visible = not visible
	get_viewport().set_input_as_handled()
	if visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not get_tree().paused and not _other_panel_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _other_panel_open() -> bool:
	for panel in get_tree().get_nodes_in_group("tuning_panels"):
		if panel != self and panel.visible:
			return true
	return false


# --- UI construction -------------------------------------------------------

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE if dock_left else Control.PRESET_RIGHT_WIDE)
	if dock_left:
		offset_right = 440.0
	else:
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

	var title_label := Label.new()
	var key := OS.get_keycode_string(_action_key())
	title_label.text = "%s  (%s to close)" % [title, key]
	title_label.add_theme_font_size_override("font_size", 18)
	layout.add_child(title_label)

	if profile:
		var buttons := HBoxContainer.new()
		layout.add_child(buttons)
		_add_button(buttons, "Save", _save)
		_add_button(buttons, "Revert to saved", _revert)
		_add_button(buttons, "Defaults", _reset_defaults)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.modulate = Color(0.7, 0.9, 0.7)
	layout.add_child(_status)

	if show_time_scale:
		_add_time_scale(layout)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	_build_rows()


## Slow motion is a debug aid, not part of the target.
func _add_time_scale(layout: Control) -> void:
	var row := _new_row(layout, "Slow motion (time scale)")
	var slider := _new_slider(row, 0.1, 1.0, 0.05, Engine.time_scale)
	_time_scale_label = _new_value_label(row, "%.2f" % Engine.time_scale)
	slider.value_changed.connect(func(value: float) -> void:
		Engine.time_scale = value
		_time_scale_label.text = "%.2f" % value)


func _build_rows() -> void:
	if _rows == null:
		return
	for child in _rows.get_children():
		child.queue_free()
	if _target == null:
		return
	# Headers are only added once a tunable follows them, which skips engine groups.
	var pending_header := ""
	for prop in _target.get_property_list():
		var usage: int = prop["usage"]
		if usage & PROPERTY_USAGE_GROUP:
			pending_header = prop["name"]
			continue
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR):
			continue
		var type: int = prop["type"]
		var hint: int = prop["hint"]
		var is_range := (type == TYPE_FLOAT or type == TYPE_INT) and hint == PROPERTY_HINT_RANGE
		var is_enum := type == TYPE_INT and hint == PROPERTY_HINT_ENUM
		if not (is_range or is_enum or type == TYPE_BOOL):
			continue
		if pending_header != "":
			_add_header(pending_header)
			pending_header = ""
		if is_range:
			_add_slider(prop["name"], prop["hint_string"], type == TYPE_INT)
		elif is_enum:
			_add_dropdown(prop["name"], prop["hint_string"])
		else:
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


func _add_slider(property: String, hint: String, is_int: bool) -> void:
	var parts := hint.split(",")
	var step := float(parts[2]) if parts.size() > 2 else (1.0 if is_int else 0.01)
	var row := _new_row(_rows, property.capitalize())
	var slider := _new_slider(row, float(parts[0]), float(parts[1]), step, _target.get(property))
	var value_label := _new_value_label(row, _format(slider.value, step))
	slider.value_changed.connect(func(value: float) -> void:
		_target.set(property, roundi(value) if is_int else value)
		value_label.text = _format(value, step)
		_mark_changed())


func _add_dropdown(property: String, hint: String) -> void:
	var row := _new_row(_rows, property.capitalize())
	var dropdown := OptionButton.new()
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dropdown.add_theme_font_size_override("font_size", 13)
	var next_value := 0
	for option in hint.split(","):
		var parts := option.split(":")
		var value := int(parts[1]) if parts.size() > 1 else next_value
		dropdown.add_item(parts[0], value)
		next_value = value + 1
	dropdown.select(dropdown.get_item_index(_target.get(property)))
	row.add_child(dropdown)
	dropdown.item_selected.connect(func(index: int) -> void:
		_target.set(property, dropdown.get_item_id(index))
		_mark_changed())


func _add_checkbox(property: String) -> void:
	var box := CheckBox.new()
	box.text = property.capitalize()
	box.button_pressed = _target.get(property)
	box.add_theme_font_size_override("font_size", 13)
	box.toggled.connect(func(on: bool) -> void:
		_target.set(property, on)
		_mark_changed())
	_rows.add_child(box)


func _new_row(parent: Control, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 190
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)
	return row


func _new_slider(row: Control, min_value: float, max_value: float, step: float, value: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	return slider


func _new_value_label(row: Control, text: String) -> Label:
	var label := Label.new()
	label.custom_minimum_size.x = 48
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)
	return label


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


func _mark_changed() -> void:
	if profile:
		_status.text = "Unsaved changes"


func _action_key() -> Key:
	for event in InputMap.action_get_events(toggle_action):
		if event is InputEventKey:
			return event.physical_keycode
	return KEY_NONE


# --- Profile actions -------------------------------------------------------

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
