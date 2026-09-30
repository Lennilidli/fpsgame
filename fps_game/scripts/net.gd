extends Node
## LAN multiplayer session (autoload "Net"): hosting and joining over ENet, finding hosts
## with a UDP broadcast, and handing the host's combat settings to the guest so both
## players fight with identical, fixed rules.

signal status_changed(text: String)
signal hosts_changed(hosts: Dictionary) ## ip -> host name

## Bump when anything that affects the match changes; mismatched builds can't connect.
const PROTOCOL := "meleeproto-1"
const GAME_PORT := 7777
const DISCOVERY_PORT := 7778
const PVP_SCENE := "res://scenes/pvp.tscn"
const MENU_SCENE := "res://scenes/menu.tscn"
const PROFILE_PATH := "res://combat/sword_profile.tres"

var active := false
var is_host := false
var opponent_id := 0
## Shown by the lobby after a session ends (e.g. "Opponent disconnected").
var last_message := ""
var found_hosts := {}

var _broadcaster: PacketPeerUDP
var _listener: PacketPeerUDP
var _broadcast_timer := 0.0
var _saved_profile := {} ## The guest's own settings, restored after the match.


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func() -> void: leave("Could not connect to the host."))
	multiplayer.server_disconnected.connect(func() -> void: leave("The host left the match."))


func _process(delta: float) -> void:
	if _broadcaster:
		_broadcast_timer -= delta
		if _broadcast_timer <= 0.0:
			_broadcast_timer = 1.0
			_broadcaster.put_packet(("%s|%s" % [PROTOCOL, OS.get_environment("COMPUTERNAME")]).to_utf8_buffer())
	if _listener:
		while _listener.get_available_packet_count() > 0:
			var packet := _listener.get_packet().get_string_from_utf8().split("|")
			var ip := _listener.get_packet_ip()
			if packet.size() >= 2 and packet[0] == PROTOCOL and not found_hosts.has(ip):
				found_hosts[ip] = packet[1]
				hosts_changed.emit(found_hosts)


# --- Session ---------------------------------------------------------------

func host() -> void:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(GAME_PORT, 1) != OK:
		status_changed.emit("Could not host on port %d (is another game already hosting?)" % GAME_PORT)
		return
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = true
	_start_broadcast()
	status_changed.emit("Hosting on %s - waiting for an opponent..." % local_ip())


func join(address: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, GAME_PORT) != OK:
		status_changed.emit("Invalid address: %s" % address)
		return
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = false
	status_changed.emit("Connecting to %s..." % address)


## Ends the session and returns to the main menu.
func leave(message := "") -> void:
	last_message = message
	_stop_broadcast()
	stop_discovery()
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var was_active := active
	active = false
	is_host = false
	opponent_id = 0
	_restore_profile()
	get_tree().paused = false
	if was_active:
		get_tree().change_scene_to_file(MENU_SCENE)


func local_ip() -> String:
	for address in IP.get_local_addresses():
		if address.begins_with("192.168.") or address.begins_with("10.") or address.begins_with("172."):
			return address
	return "127.0.0.1"


# --- Handshake ---------------------------------------------------------------
# Guest connects -> sends its protocol -> host checks it, sends its combat settings
# and both load the arena.

func _on_connected_to_server() -> void:
	opponent_id = 1
	_hello.rpc_id(1, PROTOCOL)


func _on_peer_connected(id: int) -> void:
	if is_host:
		opponent_id = id


func _on_peer_disconnected(id: int) -> void:
	if active and id == opponent_id:
		leave("Your opponent left the match.")


@rpc("any_peer", "call_remote", "reliable")
func _hello(protocol: String) -> void:
	if not is_host:
		return
	var guest := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		_rejected.rpc_id(guest, "Version mismatch: host runs %s, you run %s." % [PROTOCOL, protocol])
		return
	_stop_broadcast()
	_start_match.rpc_id(guest, _profile_values())
	get_tree().change_scene_to_file(PVP_SCENE)


@rpc("authority", "call_remote", "reliable")
func _start_match(settings: Dictionary) -> void:
	_apply_host_profile(settings)
	get_tree().change_scene_to_file(PVP_SCENE)


@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	leave(reason)


# --- Fixed settings ----------------------------------------------------------

func _profile_values() -> Dictionary:
	var profile: Resource = load(PROFILE_PATH)
	var values := {}
	for prop in profile.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and prop["usage"] & PROPERTY_USAGE_STORAGE:
			values[prop["name"]] = profile.get(prop["name"])
	return values


## The guest fights with the host's settings; its own are restored after the match.
func _apply_host_profile(settings: Dictionary) -> void:
	var profile: Resource = load(PROFILE_PATH)
	_saved_profile = _profile_values()
	for key in settings:
		profile.set(key, settings[key])


func _restore_profile() -> void:
	if _saved_profile.is_empty():
		return
	var profile: Resource = load(PROFILE_PATH)
	for key in _saved_profile:
		profile.set(key, _saved_profile[key])
	_saved_profile = {}


# --- LAN discovery -----------------------------------------------------------

func start_discovery() -> void:
	stop_discovery()
	found_hosts.clear()
	_listener = PacketPeerUDP.new()
	if _listener.bind(DISCOVERY_PORT) != OK:
		_listener = null


func stop_discovery() -> void:
	if _listener:
		_listener.close()
		_listener = null


func _start_broadcast() -> void:
	_broadcaster = PacketPeerUDP.new()
	_broadcaster.set_broadcast_enabled(true)
	_broadcaster.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_broadcast_timer = 0.0


func _stop_broadcast() -> void:
	if _broadcaster:
		_broadcaster.close()
		_broadcaster = null
