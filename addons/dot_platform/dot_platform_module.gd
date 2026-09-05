class_name DotPlatformModule
extends DotModule

## Binds a [DotPlatformHub] to a running dot-server, as a module rather than a fork.
##
## [b]Why a module.[/b] dot-server's extension points exist so a game never has to
## edit it, and a platform is exactly the kind of thing that would otherwise be
## tempted to. Everything here goes through [code]DotModule[/code]'s own helpers, so
## unloading it removes every command, cvar and hook it added — the reason those
## helpers exist is that a module which registers a command and is then unloaded
## leaves the console calling into a freed object.
##
## [codeblock]
## var module := DotPlatformModule.new()
## module.platform = platform
## server.modules.load_module(module)
## [/codeblock]
##
## [b]The one thing this cannot do yet.[/b] dot-server's signon runs
## CONNECTING to AUTHENTICATING to DOWNLOADING to LOADING to SPAWNED, and there is no
## cancellable stage between authentication and content. So admission runs off
## [signal DotServer.client_state_changed] and completes shortly [i]after[/i] the
## player is admitted by dot-server rather than gating it.
##
## For a sandbox that is fine — a player briefly present with a default avatar is not
## a problem, and dot-user and dot-user-avatar both degrade to something usable. For
## [code]require_avatar[/code] it is not enough, and the honest fix is a PROFILE
## stage in [code]DotClientSession[/code] with its own timeout, exactly as the
## existing stages have. That is a change to dot-server, it is written up in
## [code]PLATFORM.md[/code], and this module is deliberately structured so it becomes
## a smaller file rather than a rewrite when the stage lands.

const CHANNEL := "platform.module"

## The platform this module wires in. Required.
var platform: DotPlatformHub = null

## dot-server session userid -> scoped platform key.
##
## Kept because dot-server keys everything on its own session ids and the platform
## keys everything on scoped ids, and the translation has to live somewhere. Here,
## once, rather than at every call site.
var _keys_by_userid: Dictionary = {}

## Admissions in flight, so a client whose state changes twice is not admitted twice.
var _admitting: Dictionary = {}


func _module_name() -> String:
	return "platform"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "Profiles and avatars for connecting players."


func _module_author() -> String:
	return "dot"


func _module_load() -> DotResult:
	if platform == null:
		platform = DotRegistry.get_service(DotPlatformHub.SERVICE) as DotPlatformHub

	if platform == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The platform module needs a DotPlatformHub.",
			"assign module.platform, or add a DotPlatformHub that registers itself"
		)

	if server == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The platform module needs a server."
		)

	server.client_state_changed.connect(_on_client_state_changed)
	server.client_disconnected.connect(_on_client_disconnected)

	# What broadcast_avatar_changes does: a wardrobe change becomes a server event a
	# game module hooks to redress the player for everybody. The config knob was
	# documented from the first version and read by nothing.
	if server.events != null:
		server.events.declare(
			"player_avatar_changed", "A connected player's avatar changed; carries userid."
		)
	if not platform.avatar_changed.is_connected(_on_avatar_changed):
		platform.avatar_changed.connect(_on_avatar_changed)

	add_command(
		"platform_status",
		_cmd_status,
		"Show what the platform knows about connected players."
	)

	add_command(
		"platform_name",
		_cmd_name,
		"Change a player's display name: platform_name <userid> <name>"
	)

	log_info("platform module loaded", platform.describe())

	return DotResult.success(true)


func _module_unload() -> void:
	if platform != null and platform.avatar_changed.is_connected(_on_avatar_changed):
		platform.avatar_changed.disconnect(_on_avatar_changed)
	if server != null:
		if server.client_state_changed.is_connected(_on_client_state_changed):
			server.client_state_changed.disconnect(_on_client_state_changed)
		if server.client_disconnected.is_connected(_on_client_disconnected):
			server.client_disconnected.disconnect(_on_client_disconnected)

	_keys_by_userid.clear()
	_admitting.clear()


# --- The join --------------------------------------------------------------

func _on_client_state_changed(session: DotClientSession) -> void:
	# An identity means dot-server has finished authenticating. Every later state
	# change also carries one, which is why the in-flight guard exists rather than
	# matching on a specific state: the states a client passes through after
	# authentication differ depending on whether the server has content to send.
	if session.identity == null:
		return

	if _admitting.has(session.userid) or _keys_by_userid.has(session.userid):
		return

	_admitting[session.userid] = true
	_admit(session)


## Runs admission for one session.
##
## Not awaited by the caller: [signal DotServer.client_state_changed] is emitted from
## inside the server's own signon path, and suspending there would leave the server
## mid-transition while a store is queried.
func _admit(session: DotClientSession) -> void:
	var admitted: DotResult = await platform.admit(session.identity)

	_admitting.erase(session.userid)

	# The player may have given up and left while the store was being read. Anything
	# written to the session now would be written to a session the server has already
	# torn down.
	if not session.is_active():
		if admitted.ok:
			platform.release((admitted.value as DotPlatformPlayer).key())
		return

	if not admitted.ok:
		log_warn("admission refused", {
			"user": session.label(), "reason": str(admitted.error)
		})

		if server != null:
			server.kick_session(session, admitted.error.message)

		return

	var player: DotPlatformPlayer = admitted.value

	if player.key() != "":
		_keys_by_userid[session.userid] = player.key()

	# Carried on the session so a game's own code, a console command or another
	# module can reach the platform state without a second lookup.
	session.data["platform"] = player

	if platform.config.apply_profile_name and player.display_name() != "":
		session.display_name = player.display_name()

	if player.needs_onboarding:
		log_info("player needs first-time setup", {
			"user": session.label(), "key": player.key()
		})

	log_info("player admitted", {
		"user": session.label(),
		"key": player.key(),
		"avatar": player.avatar.digest() if player.avatar != null else "-",
	})


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	var key: String = _keys_by_userid.get(session.userid, "")

	_admitting.erase(session.userid)

	if key == "":
		return

	_keys_by_userid.erase(session.userid)
	platform.release(key)


# --- Lookups ---------------------------------------------------------------

## The platform state for a dot-server session, or null.
func player_for(session: DotClientSession) -> DotPlatformPlayer:
	if session == null:
		return null

	var carried: Variant = session.data.get("platform")

	return carried if carried is DotPlatformPlayer else null


func key_for_userid(userid: int) -> String:
	return _keys_by_userid.get(userid, "")


# --- Console ---------------------------------------------------------------

func _cmd_status(ctx: DotCmdContext) -> void:
	for line in platform.describe_lines():
		ctx.reply(line)


func _cmd_name(ctx: DotCmdContext) -> void:
	if ctx.args.size() < 2:
		ctx.reply("usage: platform_name <userid> <name>")
		return

	var userid := int(ctx.args[0])
	var key := key_for_userid(userid)

	if key == "":
		ctx.reply("No platform state for userid %d." % userid)
		return

	var requested := " ".join(ctx.args.slice(1))
	var renamed: DotResult = await platform.set_display_name(key, requested)

	if not renamed.ok:
		ctx.reply("Refused: %s" % renamed.error.message)
		return

	ctx.reply("Renamed to '%s'." % renamed.value)


## Finds the session wearing this player and tells the server. A player with no
## session — one whose avatar changed while they were between servers — is nobody's
## business here.
func _on_avatar_changed(player: DotPlatformPlayer) -> void:
	if server == null or server.events == null or platform == null:
		return
	if not platform.config.broadcast_avatar_changes:
		return
	for session in server.playing_sessions():
		if player_for(session) == player:
			server.events.notify("player_avatar_changed", {
				"userid": session.userid, "peer_id": session.peer_id,
			})
			return
