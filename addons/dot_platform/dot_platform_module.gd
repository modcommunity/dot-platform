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
## [b]Admission gates the spawn.[/b] dot-server's signon has a PROFILE stage between
## authentication and content (dot-server API level 7). The module holds every
## authenticated player there while [method DotPlatformHub.admit] runs, so the player
## appears already wearing their profile name and avatar, and a refusal
## ([code]require_avatar[/code], [code]require_profile[/code]) is a refusal of somebody
## nobody saw join rather than a kick.
##
## [b]And the old path stays.[/b] A session announced past the stage (a server older than
## it, a host that adopted the session, a guest who signed in after spawning) is admitted
## the way it always was, after the spawn, and a refusal there is a kick. That is also what
## a game's suite drives when it calls the state handler by hand.

# No CHANNEL constant: this module logs -- admission, refusal, onboarding -- through
# DotModule.log_info/log_warn, which write on "mod.platform". A second name here was one
# nothing wrote to, so `log channel platform.module debug` turned up nothing at all.

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

## The name this module holds the PROFILE stage under. See [method DotServer.hold_profile].
const HOLD := "platform"

## dot-server session userid -> session, for every player this module is holding in the
## PROFILE stage. Kept so an unload can let them go: a hold whose holder has gone is
## released by nothing, and the player would sit there until the stage's timeout.
var _holding: Dictionary = {}


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
		# The moment the real name and avatar exist. On a server with the PROFILE stage
		# that is before the spawn and a game finds nobody to redraw; admission can still
		# finish AFTER the game has seated somebody (an older server, a slow store let in
		# early, an identity that changed), and then a game that read the name and avatar
		# at seating read a guest's and has to redraw.
		server.events.declare(
			"player_admitted",
			"A connected player's profile and avatar are resolved; carries userid, peer_id."
		)
		server.events.declare(
			"player_renamed",
			"platform_name changed a connected player's name; carries userid, peer_id, name."
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

	# Let everybody we were holding in. Their admission is abandoned with the module, so
	# they enter with what dot-server knows, the way they would on a server without one.
	for userid in _holding.keys():
		_release(_holding[userid])

	_keys_by_userid.clear()
	_admitting.clear()
	_holding.clear()


# --- The join --------------------------------------------------------------

func _on_client_state_changed(session: DotClientSession) -> void:
	# An identity means dot-server has finished authenticating. Every later state
	# change also carries one, which is why the in-flight guard exists rather than
	# matching on a specific state: a session announced past the PROFILE stage (an older
	# server, an adopted session, an identity that changed) is still admitted, late.
	if session.identity == null:
		return

	# A refusal is announced too (REJECTED), with the identity still on it; admitting a
	# session that is on its way out read the stores again for nobody.
	if not session.is_active():
		return

	# The hub belongs to whatever built it, and a game change may have freed it. Admitting
	# through a freed hub crashed the server; a module left without one admits nobody.
	if not is_instance_valid(platform):
		return

	if _admitting.has(session.userid) or _keys_by_userid.has(session.userid):
		return

	_admitting[session.userid] = true

	# Claimed now, synchronously, from inside dot-server's own announcement: the server
	# looks at the holds as soon as its handlers return, and one taken after an await
	# would find the player already downloading.
	var gated := _hold(session)

	_admit(session, gated)


## Holds [param session] in dot-server's PROFILE stage. False when it is not in the stage
## or the server has no such stage, which means admission runs after the spawn.
##
## [b]By name, through [method Object.call].[/b] `server.hold_profile(...)` would not
## parse against a dot-server older than the stage, and this addon would then fail to load
## on every server that has not been updated, rather than admitting late as it used to.
func _hold(session: DotClientSession) -> bool:
	if server == null or not server.has_method("hold_profile"):
		return false
	if not bool(server.call("hold_profile", session, HOLD)):
		return false
	_holding[session.userid] = session

	# [b]A slow store must not keep a player out[/b] unless the configuration says what it
	# is waiting for is required. Past the admission budget, an optional admission lets the
	# player in and finishes behind them, as it did before the stage existed. A required
	# one keeps holding: letting them in would be the very spawn the stage exists to
	# prevent, and dot-server's own profile timeout is the ceiling.
	if not _required():
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			var budget := platform.config.admission_timeout_sec + 0.5
			# A bound method, not a lambda: a connection to a method is dropped when this
			# module is freed, and a lambda would run against a freed module after an unload.
			tree.create_timer(budget).timeout.connect(_on_admission_budget.bind(session, budget))
	return true


func _on_admission_budget(session: DotClientSession, budget: float) -> void:
	if _holding.get(session.userid) != session:
		return
	log_warn("admission is slow; letting the player in before it finishes", {
		"user": session.label(), "seconds": budget,
	})
	_release(session)


func _required() -> bool:
	return platform != null and platform.config != null \
		and (platform.config.require_avatar or platform.config.require_profile)


## Ends this module's hold, if it still has one. The server sends the player on once
## nobody else holds them.
func _release(session: DotClientSession) -> void:
	if _holding.get(session.userid) != session:
		return
	_holding.erase(session.userid)
	if server != null and server.has_method("release_profile"):
		server.call("release_profile", session, HOLD)


## Runs admission for one session.
##
## Not awaited by the caller: [signal DotServer.client_state_changed] is emitted from
## inside the server's own signon path, and suspending there would leave the server
## mid-transition while a store is queried. [param gated] says the session is held in
## the PROFILE stage, so whatever happens here, it ends by releasing or refusing it.
func _admit(session: DotClientSession, gated: bool) -> void:
	var admitted: DotResult = await platform.admit(session.identity)

	_admitting.erase(session.userid)

	# The player may have given up and left while the store was being read. Anything
	# written to the session now would be written to a session the server has already
	# torn down.
	if not session.is_active():
		_holding.erase(session.userid)
		if admitted.ok:
			platform.release((admitted.value as DotPlatformPlayer).key())
		return

	if not admitted.ok:
		log_warn("admission refused", {
			"user": session.label(), "reason": str(admitted.error)
		})

		# Still held: refused before they appear, with the platform's sentence. Past the
		# stage (late admission, or the hold was let go): the only answer left is a kick.
		# This called `kick_session`, which DotServer has never had, so every late refusal
		# was a script error and the player stayed in.
		_holding.erase(session.userid)
		if server != null:
			var refused := (
				server.has_method("refuse_profile")
				and bool(server.call("refuse_profile", session, admitted.error.message, admitted.error))
			)
			if not refused:
				server.kick(session, admitted.error.message)

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
		"before_spawn": gated and _holding.has(session.userid),
	})

	if server != null and server.events != null:
		server.events.notify("player_admitted", {
			"userid": session.userid, "peer_id": session.peer_id,
		})

	# Last: the name and the platform state are on the session before dot-server moves the
	# player on, so the game seats them as who they are rather than redrawing a guest.
	_release(session)


## Whether this module's admission runs before the spawn on the server it is loaded in,
## that is, whether that dot-server has the PROFILE stage. A game that redraws on
## `player_admitted` still has to: a late admission (see the class notes) fires it after.
func gates_spawn() -> bool:
	return server != null and server.has_method("hold_profile")


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	var key: String = _keys_by_userid.get(session.userid, "")

	_admitting.erase(session.userid)
	_holding.erase(session.userid)

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

	# The profile changed and the session did not, so the game went on calling them by the
	# old name: in chat, on the scoreboard, over their head. Applied here the way admission
	# applies it, and announced, because only the game knows where it drew the name.
	var session := server.session_by_userid(userid) if server != null else null

	if session != null and platform.config.apply_profile_name:
		session.display_name = str(renamed.value)

		if server.events != null:
			server.events.notify("player_renamed", {
				"userid": userid, "peer_id": session.peer_id, "name": session.display_name,
			})

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
