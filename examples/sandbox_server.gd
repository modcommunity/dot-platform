extends Node

## A real server, a real client, one process, over a real socket.
##
## [codeblock]
## godot --headless --path . res://examples/sandbox_server.tscn
## [/codeblock]
##
## Exits non-zero on failure.
##
## [b]What this proves that the seam test cannot.[/b] The seam test calls
## [method DotPlatformHub.admit] directly. This boots a [DotServer], loads
## [DotPlatformModule] into it, connects a [DotClientLink] over loopback, and lets
## the whole signon run: transport, challenge, credentials, authentication, content,
## load, spawn — with the platform resolving a profile and an avatar along the way.
## Nothing is called by hand.
##
## [b]Two MultiplayerAPI instances in one process.[/b] A server and a client both want
## [code]SceneTree.multiplayer[/code], and there is one of those. Godot's answer is
## [method SceneTree.set_multiplayer], which scopes an API to a subtree — so the
## server half and the client half each get their own, rooted at different nodes, and
## [code]multiplayer[/code] inside each resolves to the right one.
##
## That is worth more than this test: it is the same mechanism dot-core needs for
## listening on UDP and WebSocket at once, which is the open question in
## [code]PLATFORM.md[/code]. If this works, that approach works.

const PORT := 27077
const PROFILE_DIR := "user://sandbox_profiles"
const AVATAR_DIR := "user://sandbox_avatars"
const SCOPE_KEY := "user://sandbox_scope.key"
const SERVER_DIR := "user://sandbox_server"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server: DotServer = null
var _link: DotClientLink = null
var _hub: DotPlatformHub = null
var _users: DotUserManager = null
var _avatars: DotAvatarManager = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-platform sandbox server")
	print("")

	_cleanup()

	var built := await _build()

	if built:
		await _test_join()

	_teardown()
	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	DotPaths.remove_tree(PROFILE_DIR)
	DotPaths.remove_tree(AVATAR_DIR)
	DotPaths.remove_tree(SERVER_DIR)
	if FileAccess.file_exists(SCOPE_KEY):
		DirAccess.open("user://").remove(SCOPE_KEY.get_file())


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Building both halves --------------------------------------------------

func _build() -> bool:
	print("bringing up the sandbox")

	# The server half and the client half live under separate subtrees, each with its
	# own MultiplayerAPI. Without this the second one to set multiplayer_peer wins and
	# the first silently stops receiving anything.
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), server_side.get_path())
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), client_side.get_path())

	_check(
		get_tree().get_multiplayer(server_side.get_path())
			!= get_tree().get_multiplayer(client_side.get_path()),
		"the two halves have separate MultiplayerAPI instances"
	)

	# --- platform services (shared; they are not networked) ---
	_users = DotUserManager.new()
	_users.register_service = true
	_users.load_layered_config = false
	_users.config_file = ""
	_users.server_id = "sandbox"

	var user_config := DotUserConfig.new()
	user_config.backend = "local"
	user_config.directory = PROFILE_DIR
	user_config.scope = "server:sandbox"
	user_config.scope_key_file = SCOPE_KEY
	user_config.allow_guest_profiles = true
	_users.config = user_config
	add_child(_users)

	var users_ready: DotResult = await _users.setup()
	if not _check(users_ready.ok, "profiles are up", str(users_ready.error)):
		return false

	_avatars = DotAvatarManager.new()
	_avatars.schema = _build_schema()
	_avatars.register_service = true
	_avatars.load_layered_config = false
	_avatars.config_file = ""

	var avatar_config := DotAvatarConfig.new()
	avatar_config.backend = "local"
	avatar_config.directory = AVATAR_DIR
	_avatars.config = avatar_config
	add_child(_avatars)

	var avatars_ready: DotResult = await _avatars.setup()
	if not _check(avatars_ready.ok, "avatars are up", str(avatars_ready.error)):
		return false

	_hub = DotPlatformHub.new()
	_hub.register_service = true
	_hub.load_layered_config = false
	_hub.config_file = ""
	_hub.config = DotPlatformConfig.new()
	add_child(_hub)

	var hub_ready: DotResult = await _hub.setup()
	if not _check(hub_ready.ok, "the platform is up", str(hub_ready.error)):
		return false

	# --- authentication: guests, so no backbone is involved ---
	var auth_config := DotAuthConfig.new()
	auth_config.strategy = DotAuthConfig.Strategy.ANONYMOUS
	auth_config.allow_guests = true

	var auth := DotAuthServer.new()
	auth.name = "Auth"
	auth.config = auth_config
	auth.config_file = ""
	auth.register_service = true
	server_side.add_child(auth)

	# --- the server ---
	var config := DotServerConfig.new()
	config.hostname = "sandbox"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens", str(booted.error)):
		return false

	# The module finds the hub through DotRegistry, which is why load_module taking a
	# path rather than an instance is not a problem.
	var loaded := _server.modules.load_module(
		"res://addons/dot_platform/dot_platform_module.gd"
	)

	if not _check(loaded.ok, "the platform module loads into the server", str(loaded.error)):
		return false

	_check(
		_server.modules.has_module("platform"),
		"and is listed among the server's modules"
	)

	# --- the client ---
	_link = DotClientLink.new()
	# Named "Server", which looks wrong and is not.
	#
	# Godot addresses an RPC by the receiver's node path relative to its
	# MultiplayerAPI root, so a call from the server's node at ServerSide/Server
	# arrives addressed to "Server" and is looked up under the client's root. Give the
	# client's node any other name and every RPC fails with "Node not found: Server",
	# which is what the first version of this file did.
	#
	# So DotClientLink must sit at the same relative path as DotServer. In a normal
	# two-process deployment that is invisible — both are just "the game node" — and
	# in one process it is the whole difference between a working handshake and a
	# client that connects, says nothing, and times out.
	_link.name = "Server"
	_link.player_name = "Sandbox Visitor"
	client_side.add_child(_link)

	return true


func _build_schema() -> DotAvatarSchema:
	var schema := DotAvatarSchema.new()
	schema.id = &"sandbox"

	var body := DotAvatarSlot.make(&"body", true, &"body_default")
	var hair := DotAvatarSlot.make(&"hair")
	schema.slots = [body, hair]

	var body_default := DotAvatarPart.make(&"body_default", &"body", true)
	body_default.colour_channels = 1
	var hair_free := DotAvatarPart.make(&"hair_free", &"hair", true)
	hair_free.colour_channels = 1

	schema.parts = [body_default, hair_free]
	schema.invalidate()
	return schema


# --- The join ---------------------------------------------------------------

func _test_join() -> void:
	print("")
	print("a client connects")

	var spawned := [false]
	var refused := [""]

	_link.spawned.connect(func() -> void: spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: refused[0] = reason)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "the client starts connecting", str(connecting.error)):
		return

	# Signon is several round trips plus a profile and an avatar read, all on
	# loopback. Ten seconds is generous; the point is to fail rather than hang.
	var deadline := Time.get_ticks_msec() + 10000

	while not spawned[0] and refused[0] == "" and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	if not _check(
		spawned[0],
		"the client completes signon and spawns",
		refused[0] if refused[0] != "" else "timed out at phase %s" % _link.phase
	):
		return

	_check(_server.sessions().size() == 1, "the server has one session open")

	# Give the module's admission a moment: it runs off client_state_changed and
	# completes shortly after spawn, which is the ordering limitation the module
	# documents.
	var admitted_deadline := Time.get_ticks_msec() + 5000

	while _hub.count() == 0 and Time.get_ticks_msec() < admitted_deadline:
		await get_tree().process_frame

	if not _check(_hub.count() == 1, "the platform admitted them"):
		return

	var player: DotPlatformPlayer = _hub.players()[0]

	_check(player.is_ready(), "and they reached READY", player.stage_name())
	_check(player.is_guest(), "as a guest, since this server has no accounts")
	_check(player.profile != null, "with a profile")
	_check(player.avatar != null, "and an avatar")
	_check(
		player.avatar != null and player.avatar.has_slot(&"body"),
		"whose required slots are filled, so they are visible"
	)
	_check(
		DotUserScope.is_well_formed(player.key()),
		"keyed by a scoped id",
		player.key()
	)
	_check(
		not player.key().contains(player.account_uid()),
		"which does not contain the identity the server authenticated"
	)

	# The module's own view of the same player.
	var module := _server.modules.get_module("platform") as DotPlatformModule
	var sessions := _server.sessions()

	if sessions.size() == 1:
		var carried := module.player_for(sessions[0])
		_check(
			carried == player,
			"and the module put the platform state on it"
		)
		_check(
			sessions[0].display_name == player.display_name(),
			"and applied the profile name to the session",
			"%s vs %s" % [sessions[0].display_name, player.display_name()]
		)

	# The console command, which is how an operator sees any of this.
	var status: DotResult = _server.console.execute(
		"platform_status",
		DotCmdContext.console("platform_status", PackedStringArray())
	)
	_check(status.ok, "platform_status runs", str(status.error) if not status.ok else "")

	print("")
	print("  --- the server's view ---")
	for line in _hub.describe_lines():
		print("  %s" % line)

	# Leaving releases the platform state, or a busy server accumulates every player
	# who has ever connected.
	print("")
	print("the client leaves")

	_link.disconnect_from_server("done")

	var release_deadline := Time.get_ticks_msec() + 5000

	while _hub.count() > 0 and Time.get_ticks_msec() < release_deadline:
		await get_tree().process_frame

	_check(_hub.count() == 0, "the platform released them on disconnect")


func _teardown() -> void:
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("shutdown")

	if _server != null and is_instance_valid(_server):
		_server.shutdown("self-test finished")
