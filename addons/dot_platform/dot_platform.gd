@tool
class_name DotPlatformHub
extends Node

## Turns an authenticated identity into a player who can enter the world.
##
## [codeblock]
## var platform := DotPlatformHub.new()
## add_child(platform)
##
## var admitted := await platform.admit(identity)
## var player: DotPlatformPlayer = admitted.value
## [/codeblock]
##
## [b]This is the seam nothing else was testing.[/b] dot-auth, dot-user and
## dot-user-avatar each pass their own self-tests in isolation, and each is
## deliberately unaware of the others — that independence is what makes them
## adoptable one at a time. The cost is that the handoffs between them existed only in
## documentation. This is the handoff, as code, with a self-test that runs all three
## in one process.
##
## [b]Everything optional stays optional.[/b] The managers are found through
## [DotRegistry], never imported, and each one being absent has a defined answer:
##
## - no dot-user: every player is a guest with a session identity and no profile;
## - no dot-user-avatar: nobody has an avatar and nothing asks for one;
## - neither: [method admit] still returns a usable player, and a game that only
##   wanted authentication has paid nothing for the rest.
##
## That is not politeness. A sandbox that required all three to start would be
## unusable on the first day of a project, which is the day people decide whether to
## adopt something.

const CHANNEL := "platform"
const SERVICE := &"dot_platform"

## Registry names of the addons this joins. Looked up, never imported.
const USER_SERVICE := &"dot_user_manager"
const AVATAR_SERVICE := &"dot_avatar_manager"

## Emitted once a player is fully admitted.
signal player_admitted(player: DotPlatformPlayer)

## Emitted when admission stops. The hook for a rejection message.
signal player_refused(player: DotPlatformPlayer, reason: String)

## Emitted when a player publishes a new avatar.
signal avatar_changed(player: DotPlatformPlayer)

## Emitted when a player leaves and their state is released.
signal player_released(key: String)

@export_group("Configuration")

@export var config: DotPlatformConfig = null

@export var config_file: String = "user://dot_platform.json"

@export var load_layered_config: bool = true

@export_group("Wiring")

@export var register_service: bool = true

@export var service_scope: StringName = &""

## Where a player's entitlements come from.
##
## Takes the identity, returns a [DotAvatarEntitlements]. Unset, every player gets
## whatever is marked free in the schema and nothing else — which is the safe
## default: a bug here should make a cosmetic unwearable, never wearable by everyone.
var entitlement_source: Callable = Callable()

## scoped key -> DotPlatformPlayer, for everyone currently admitted.
var _players: Dictionary = {}

var _registered_name: StringName = &""
var _ready_ok: bool = false

## Admissions that ran out of time and let the player in anyway.
var timed_out_count: int = 0


# --- Lifecycle -------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := setup()

	if not res.ok:
		DotLog.result(CHANNEL, "platform setup", res)


func setup() -> DotResult:
	if config == null:
		config = DotPlatformConfig.new()

	if load_layered_config or config_file != "":
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Platform configuration is not usable.")
	else:
		var valid := config.validate()
		if not valid.ok:
			return valid.wrap("Platform configuration is not usable.")

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &"" else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	_ready_ok = true

	DotLog.info(
		CHANNEL,
		"platform ready",
		{
			"config": config.describe_summary(),
			"profiles": users() != null,
			"avatars": avatars() != null,
		}
	)

	return DotResult.success(null)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


func is_ready() -> bool:
	return _ready_ok


## dot-user's manager, or null.
func users() -> Object:
	return DotRegistry.get_service(USER_SERVICE)


## dot-user-avatar's manager, or null.
func avatars() -> Object:
	return DotRegistry.get_service(AVATAR_SERVICE)


# --- Admission -------------------------------------------------------------

## Takes an authenticated identity all the way to a player who can enter the world.
##
## Never fails for "this player is new" — that is the common case. It fails only when
## the configuration says a missing profile or avatar is disqualifying, or when the
## identity itself is unusable.
func admit(identity: Object) -> DotResult:
	if not _ready_ok:
		return DotResult.fail(
			DotError.CODE_STATE, "The platform is not ready yet."
		)

	if identity == null:
		return DotResult.fail(DotError.CODE_INVALID, "No identity to admit.")

	var player := DotPlatformPlayer.for_identity(identity)
	player.entitlements = _entitlements_for(identity)

	var deadline := (
		Time.get_ticks_msec() + int(config.admission_timeout_sec * 1000.0)
	)

	var profiled := await _resolve_profile(player)

	if not profiled:
		return _refuse(player)

	# The timeout is checked between stages rather than raced against them, because a
	# store call that is already in flight cannot be cancelled and abandoning it would
	# leak the result into the next player's admission.
	if Time.get_ticks_msec() > deadline:
		timed_out_count += 1
		DotLog.warn(
			CHANNEL,
			"admission ran out of time; letting the player in with what resolved",
			{"key": player.key(), "name": player.display_name()}
		)
		return _finish(player)

	var dressed := await _resolve_avatar(player)

	if not dressed:
		return _refuse(player)

	return _finish(player)


func _resolve_profile(player: DotPlatformPlayer) -> bool:
	var manager := users()

	if manager == null:
		# No dot-user installed. The player has no profile and everything downstream
		# has to cope, which is why key() is allowed to be empty.
		player.stage = DotPlatformPlayer.Stage.PROFILED
		return true

	var resolved: DotResult = await manager.call("resolve", player.identity)

	if not resolved.ok:
		if config.require_profile:
			player.refuse(resolved.error)
			return false

		DotLog.warn(
			CHANNEL,
			"could not resolve a profile; admitting without one",
			{"error": str(resolved.error)}
		)
		player.stage = DotPlatformPlayer.Stage.PROFILED
		return true

	player.profile = resolved.value

	# dot-user marks a stand-in profile by leaving created_at at zero, and refuses to
	# persist one. Carrying that fact forward matters: a game that wrote to this
	# profile would be writing to something that is deliberately never saved, and the
	# change would vanish without an error.
	if manager.has_method("is_persistable"):
		player.degraded = not bool(
			manager.call("is_persistable", player.profile)
		)

	player.stage = DotPlatformPlayer.Stage.PROFILED
	return true


func _resolve_avatar(player: DotPlatformPlayer) -> bool:
	var manager := avatars()

	if manager == null:
		player.stage = DotPlatformPlayer.Stage.DRESSED
		return true

	var key := player.key()

	if key == "":
		# No profile, so no scoped key to file an avatar under. Refusing to invent one
		# is the point: the only other option is keying on the account id, which is
		# exactly the correlation dot-user's scoping exists to prevent.
		DotLog.debug(
			CHANNEL,
			"no profile key, so no avatar; install dot-user to give players one"
		)
		player.stage = DotPlatformPlayer.Stage.DRESSED
		return true

	var had_avatar: bool = await _stored_avatar_exists(manager, key)

	var resolved: DotResult = await manager.call(
		"resolve", key, player.entitlements
	)

	if not resolved.ok:
		if config.require_avatar:
			player.refuse(resolved.error)
			return false

		DotLog.warn(
			CHANNEL,
			"could not resolve an avatar; admitting without one",
			{"key": key, "error": str(resolved.error)}
		)
		player.stage = DotPlatformPlayer.Stage.DRESSED
		return true

	player.avatar = resolved.value
	player.needs_onboarding = _needs_onboarding(player, had_avatar)

	if config.require_avatar and player.needs_onboarding:
		player.refuse(DotError.make(
			DotError.CODE_STATE,
			"Make an avatar before joining.",
			key
		))
		return false

	player.stage = DotPlatformPlayer.Stage.DRESSED
	return true


## Whether the store already held an avatar for this player.
##
## Asked before resolving, because [code]resolve[/code] hands back the schema default
## for a player who has none — so afterwards there is no way to tell a first-time
## player from one wearing exactly the defaults.
func _stored_avatar_exists(manager: Object, key: String) -> bool:
	var store: Variant = manager.get("store")

	if store == null or not (store is Object):
		return false

	var fetched: DotResult = await (store as Object).call("fetch", key)

	return fetched.ok and fetched.value != null


func _needs_onboarding(player: DotPlatformPlayer, had_avatar: bool) -> bool:
	if config.onboarded_needs_avatar and not had_avatar:
		return true

	if player.profile != null:
		return not player.profile.onboarded

	return false


func _entitlements_for(identity: Object) -> DotAvatarEntitlements:
	if not entitlement_source.is_valid():
		# Nothing owned. A part is wearable only if the schema marks it free, which is
		# the safe direction to fail in.
		return DotAvatarEntitlements.none()

	var supplied: Variant = entitlement_source.call(identity)

	if supplied is DotAvatarEntitlements:
		return supplied

	DotLog.warn(
		CHANNEL,
		"the entitlement source returned something else; granting nothing",
		{"got": type_string(typeof(supplied))}
	)

	return DotAvatarEntitlements.none()


func _finish(player: DotPlatformPlayer) -> DotResult:
	player.stage = DotPlatformPlayer.Stage.READY

	if player.key() != "":
		_players[player.key()] = player

	player_admitted.emit(player)

	DotLog.info(
		CHANNEL,
		"player admitted",
		{
			"key": player.key(),
			"name": player.display_name(),
			"avatar": player.avatar.digest() if player.avatar != null else "-",
			"onboarding": player.needs_onboarding,
		}
	)

	return DotResult.success(player)


func _refuse(player: DotPlatformPlayer) -> DotResult:
	var reason := (
		player.refusal.message if player.refusal != null else "Refused."
	)

	player_refused.emit(player, reason)

	DotLog.info(
		CHANNEL, "player refused", {"name": player.display_name(), "reason": reason}
	)

	return DotResult.failure(
		player.refusal if player.refusal != null
		else DotError.make(DotError.CODE_FORBIDDEN, "Refused.")
	)


# --- While they are here ----------------------------------------------------

func player(key: String) -> DotPlatformPlayer:
	return _players.get(key)


func players() -> Array[DotPlatformPlayer]:
	var out: Array[DotPlatformPlayer] = []

	for key in _players:
		out.append(_players[key])

	return out


func count() -> int:
	return _players.size()


## Accepts a new avatar from a player and republishes it.
##
## [b]Goes through dot-user-avatar's own validation[/b] rather than trusting what
## arrived, and passes the entitlements resolved at admission — not any the client
## sent, which would make the whole entitlement system a suggestion.
func set_avatar(key: String, avatar: DotAvatar) -> DotResult:
	var target := player(key)

	if target == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "That player is not here.", key
		)

	var manager := avatars()

	if manager == null:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "This server has no avatar support."
		)

	var published: DotResult = await manager.call(
		"publish", key, avatar, target.entitlements
	)

	if not published.ok:
		return published

	target.avatar = avatar
	target.needs_onboarding = false

	# The profile records that first-time setup is done, so a reconnect does not send
	# them back to the editor.
	if target.profile != null and not target.profile.onboarded:
		target.profile.onboarded = true

		var users_manager := users()
		if users_manager != null and not target.degraded:
			var saved: DotResult = await users_manager.call("save", target.profile)
			if not saved.ok:
				DotLog.result(CHANNEL, "recording onboarding", saved)

	avatar_changed.emit(target)

	return DotResult.success(avatar.digest())


## Changes a display name, through dot-user so every name rule applies.
func set_display_name(key: String, requested: String) -> DotResult:
	var target := player(key)

	if target == null:
		return DotResult.fail(DotError.CODE_INVALID, "That player is not here.")

	var manager := users()

	if manager == null or target.profile == null:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "This server has no profiles."
		)

	return manager.call(
		"set_display_name", target.profile, requested, target.is_guest()
	)


## Releases a player's platform state when they leave.
func release(key: String) -> void:
	var target := player(key)

	if target == null:
		return

	_players.erase(key)

	var users_manager := users()
	if users_manager != null and users_manager.has_method("release"):
		users_manager.call("release", key)

	var avatar_manager := avatars()
	if avatar_manager != null and avatar_manager.has_method("release"):
		avatar_manager.call("release", key)

	player_released.emit(key)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"ready": _ready_ok,
		"config": config.describe_summary() if config != null else "<none>",
		"profiles": "dot-user" if users() != null else "<absent>",
		"avatars": "dot-user-avatar" if avatars() != null else "<absent>",
		"players": _players.size(),
		"timed_out": timed_out_count,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("platform     %s" % (
		config.describe_summary() if config != null else "<unconfigured>"
	))
	out.append("profiles     %s" % (
		"dot-user" if users() != null else "not installed"
	))
	out.append("avatars      %s" % (
		"dot-user-avatar" if avatars() != null else "not installed"
	))
	out.append("players      %d admitted" % _players.size())

	if timed_out_count > 0:
		out.append("timed out    %d admission(s)" % timed_out_count)

	for p in players():
		out.append("  %-24s %-16s %s" % [
			p.key(), p.display_name(), p.stage_name()
		])

	return out


# --- A note on the name ----------------------------------------------------
#
# This class is DotPlatformHub, not DotPlatform, because dot-core already has a
# DotPlatform — the capability helper behind DotPlatform.has_threads() and
# DotPlatform.is_web(). class_name is global in Godot and these addons install side
# by side, so the collision was not a style problem: it made dot-core's own scripts
# fail to parse the moment this addon was present, and the errors pointed at
# dot-auth, which does not mention either class.
#
# Worth checking a proposed class_name against every addon in the family before
# taking it, not just against the one being written.
