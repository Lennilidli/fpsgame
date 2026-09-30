extends Control
## LAN 1v1 lobby: host a match, or join one by IP or from the discovered list.

@onready var status: Label = $Box/Status
@onready var address: LineEdit = $Box/JoinRow/Address
@onready var hosts: ItemList = $Box/Hosts


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	status.text = Net.last_message if Net.last_message != "" else "Host a match, or join one on your network."
	Net.last_message = ""
	Net.status_changed.connect(func(text: String) -> void: status.text = text)
	Net.hosts_changed.connect(_refresh_hosts)
	Net.start_discovery()
	$Box/Host.pressed.connect(_host)
	$Box/JoinRow/Join.pressed.connect(func() -> void: _join(address.text.strip_edges()))
	address.text_submitted.connect(func(text: String) -> void: _join(text.strip_edges()))
	hosts.item_activated.connect(func(index: int) -> void: _join(hosts.get_item_metadata(index)))
	$Box/Back.pressed.connect(_back)


func _host() -> void:
	Net.stop_discovery()
	Net.host()
	_set_busy(Net.active)


func _join(ip: String) -> void:
	if ip == "":
		status.text = "Enter the host's IP address."
		return
	Net.stop_discovery()
	Net.join(ip)
	_set_busy(Net.active)


func _back() -> void:
	Net.leave()
	get_tree().change_scene_to_file(Net.MENU_SCENE)


func _set_busy(busy: bool) -> void:
	$Box/Host.disabled = busy
	$Box/JoinRow/Join.disabled = busy
	address.editable = not busy
	$Box/Back.text = "Cancel" if busy else "Back"


func _refresh_hosts(found: Dictionary) -> void:
	hosts.clear()
	for ip in found:
		var index := hosts.add_item("%s  (%s)" % [found[ip], ip])
		hosts.set_item_metadata(index, ip)
