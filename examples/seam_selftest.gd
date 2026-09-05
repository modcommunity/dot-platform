extends Node

## Runs dot-auth, dot-user, dot-user-avatar and dot-platform in one process and
## checks the handoffs between them.
##
## [codeblock]
## godot --headless --path . res://examples/seam_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]This is the test that did not exist.[/b] Each of those addons passes its own
## self-test in isolation and each is deliberately unaware of the others, which is
## what makes them adoptable one at a time — and which meant every boundary between
## them existed only in prose. Nothing here mocks anything: real RSA keys, a real
## ticket, a real [code]DotAuthServer[/code] verifying it offline, real profile and
## avatar managers with real stores.
##
## The property it exists to protect is the one that is invisible when it breaks:
## [b]a game server must never see a player's account id[/b]. It sees a scoped
## derivation, and the avatar is filed under that same derivation. Keying the avatar
## on the account id instead would pass every other test in the family.

const SERVER_A := "eu-west-1"
const SERVER_B := "us-east-2"

const PROFILE_DIR := "user://seam_profiles"
const AVATAR_DIR := "user://seam_avatars"
const SCOPE_KEY := "user://seam_scope.key"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _keys: Dictionary = {}
var _schema: DotAvatarSchema = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-platform seam self-test")
	print("")

	_cleanup()
	_keys = _generate_keys()
	_schema = _build_schema()

	if _keys.is_empty():
		print("  FAIL  could not generate an RSA keypair")
		get_tree().quit(1)
		return

	await _test_identity_to_profile()
	await _test_profile_to_avatar()
	await _test_scoping_across_servers()
	await _test_full_admission()
	await _test_degraded_paths()
	await _test_absent_addons()
	await _test_wardrobe()

	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	DotPaths.remove_tree(PROFILE_DIR)
	DotPaths.remove_tree(AVATAR_DIR)
	if FileAccess.file_exists(SCOPE_KEY):
		DirAccess.open("user://").remove(SCOPE_KEY.get_file())
	DotRegistry.clear()


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Fixtures --------------------------------------------------------------

func _generate_keys() -> Dictionary:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)

	if key == null:
		return {}

	return {
		"private": key.save_to_string(false),
		"public": key.save_to_string(true),
	}


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

	var hair_paid := DotAvatarPart.make(&"hair_paid", &"hair", false)
	hair_paid.colour_channels = 1

	schema.parts = [body_default, hair_free, hair_paid]
	schema.invalidate()

	return schema


## A real identity, of the kind a backbone would produce.
func _identity(account: String, name: String) -> DotAuthIdentity:
	var identity := DotAuthIdentity.new()
	identity.uid = "backbone:%s" % account
	identity.provider = "backbone"
	identity.provider_id = account
	identity.display_name = name
	identity.authenticated_at = int(Time.get_unix_time_from_system())
	return identity


## Mints a real ticket and verifies it through a real DotAuthServer.
##
## Not a shortcut around dot-auth: this is the path a connecting player takes, and
## the identity that comes out is the one the rest of the platform receives.
func _authenticate(
	account: String,
	name: String,
	server_id: String
) -> DotResult:
	var minted := DotAuthTicket.issue(
		_identity(account, name),
		server_id,
		str(_keys["private"]),
		"seam-test",
		300
	)

	if not minted.ok:
		return minted

	var config := DotAuthConfig.new()
	config.strategy = DotAuthConfig.Strategy.TICKET
	config.server_id = server_id
	config.ticket_public_key = str(_keys["public"])

	var auth := DotAuthServer.new()
	auth.config = config
	auth.config_file = ""
	auth.register_service = false
	add_child(auth)

	var authenticated: DotResult = await auth.authenticate(
		{"ticket": str(minted.value)}, "seam"
	)

	auth.queue_free()
	return authenticated


func _make_users(scope: String) -> DotUserManager:
	var manager := DotUserManager.new()
	manager.register_service = true
	manager.load_layered_config = false
	manager.config_file = ""
	manager.server_id = scope

	var config := DotUserConfig.new()
	config.backend = "local"
	config.directory = PROFILE_DIR
	config.scope = scope
	config.scope_key_file = SCOPE_KEY
	config.allow_guest_profiles = true
	manager.config = config

	add_child(manager)
	return manager


func _make_avatars() -> DotAvatarManager:
	var manager := DotAvatarManager.new()
	manager.schema = _schema
	manager.register_service = true
	manager.load_layered_config = false
	manager.config_file = ""

	var config := DotAvatarConfig.new()
	config.backend = "local"
	config.directory = AVATAR_DIR
	manager.config = config

	add_child(manager)
	return manager


func _make_platform() -> DotPlatformHub:
	var hub := DotPlatformHub.new()
	hub.register_service = true
	hub.load_layered_config = false
	hub.config_file = ""
	hub.config = DotPlatformConfig.new()
	add_child(hub)
	return hub


# --- The seams -------------------------------------------------------------

func _test_identity_to_profile() -> void:
	print("dot-auth to dot-user")

	var authenticated: DotResult = await _authenticate("acc-1", "Ada", SERVER_A)

	if not _check(authenticated.ok, "a real ticket authenticates", str(authenticated.error)):
		return

	var identity: DotAuthIdentity = authenticated.value

	_check(identity.uid == "backbone:acc-1", "and carries the account id")
	_check(identity.display_name == "Ada", "and the name")

	var users := _make_users("server:%s" % SERVER_A)
	var ready: DotResult = await users.setup()

	if not _check(ready.ok, "dot-user sets up", str(ready.error)):
		return

	# The seam: dot-user duck-types the identity on uid, display_name and is_guest,
	# and DotAuthIdentity satisfies all three without either addon knowing about the
	# other. This is what that claim being true looks like.
	var resolved: DotResult = await users.resolve(identity)

	if not _check(resolved.ok, "dot-user accepts a DotAuthIdentity", str(resolved.error)):
		return

	var profile: DotUserProfile = resolved.value

	_check(profile.display_name == "Ada", "and takes the name from it")

	# The property everything else rests on.
	_check(
		not profile.user_key.contains("acc-1"),
		"the profile key does not contain the account id",
		profile.user_key
	)
	_check(
		profile.user_key != identity.uid,
		"and is not the account id"
	)
	_check(
		DotUserScope.is_well_formed(profile.user_key),
		"it is a well-formed scoped id"
	)

	users.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_profile_to_avatar() -> void:
	print("dot-user to dot-user-avatar")

	var authenticated: DotResult = await _authenticate("acc-2", "Grace", SERVER_A)
	var users := _make_users("server:%s" % SERVER_A)
	await users.setup()

	var avatars := _make_avatars()
	var avatar_ready: DotResult = await avatars.setup()

	if not _check(avatar_ready.ok, "dot-user-avatar sets up", str(avatar_ready.error)):
		return

	var resolved: DotResult = await users.resolve(authenticated.value)
	var profile: DotUserProfile = resolved.value

	# The seam: the avatar is filed under the profile's scoped key. dot-user-avatar
	# accepts it because DotAvatarKey admits the same shape dot-user produces,
	# without the two addons depending on each other.
	_check(
		DotAvatarKey.is_usable(profile.user_key),
		"dot-user-avatar accepts a dot-user scoped key",
		profile.user_key
	)

	var avatar_result: DotResult = await avatars.resolve(
		profile.user_key, DotAvatarEntitlements.none()
	)

	if not _check(avatar_result.ok, "an avatar resolves for that key"):
		return

	var avatar: DotAvatar = avatar_result.value
	_check(avatar.has_slot(&"body"), "with its required slots filled")

	# The other direction: publishing updates the profile's digest through the
	# registry, which is the only place these two addons touch.
	var mine := _schema.default_avatar()
	mine.set_part(&"hair", &"hair_free")
	mine.set_colour(&"hair", 0, Color("aa3311"))

	var published: DotResult = await avatars.publish(
		profile.user_key, mine, DotAvatarEntitlements.none()
	)

	_check(published.ok, "a new avatar publishes")
	_check(
		profile.avatar_id == mine.digest(),
		"and the profile's avatar digest is updated through DotRegistry",
		"profile has '%s', avatar is '%s'" % [profile.avatar_id, mine.digest()]
	)

	users.queue_free()
	avatars.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_scoping_across_servers() -> void:
	print("scoping across servers")

	var on_a: DotResult = await _authenticate("acc-3", "Katherine", SERVER_A)
	var on_b: DotResult = await _authenticate("acc-3", "Katherine", SERVER_B)

	_check(
		(on_a.value as DotAuthIdentity).uid == (on_b.value as DotAuthIdentity).uid,
		"the same person authenticates to the same account id on both servers"
	)

	var users_a := _make_users("server:%s" % SERVER_A)
	await users_a.setup()
	var profile_a: DotUserProfile = (await users_a.resolve(on_a.value)).value
	users_a.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	# A different scope, sharing the same key file — which is the realistic case: one
	# operator running two servers, or two operators given keys by the same issuer.
	var users_b := _make_users("server:%s" % SERVER_B)
	await users_b.setup()
	var profile_b: DotUserProfile = (await users_b.resolve(on_b.value)).value

	# The whole point of the design.
	_check(
		profile_a.user_key != profile_b.user_key,
		"but the two servers see different profile keys",
		"%s vs %s" % [profile_a.user_key, profile_b.user_key]
	)

	# And a ticket for one server is not a login on the other.
	var wrong_server: DotResult = await _authenticate("acc-3", "K", SERVER_A)
	var minted := DotAuthTicket.issue(
		_identity("acc-3", "K"), SERVER_A, str(_keys["private"]), "seam-test", 300
	)
	var verified := DotAuthTicket.verify(
		str(minted.value), str(_keys["public"]), SERVER_B
	)
	_check(
		not verified.ok,
		"a ticket minted for one server is refused by the other"
	)

	users_b.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_full_admission() -> void:
	print("full admission")

	var users := _make_users("server:%s" % SERVER_A)
	await users.setup()
	var avatars := _make_avatars()
	await avatars.setup()
	var hub := _make_platform()
	var ready: DotResult = await hub.setup()

	if not _check(ready.ok, "the platform sets up", str(ready.error)):
		return

	_check(hub.users() != null, "and finds dot-user through DotRegistry")
	_check(hub.avatars() != null, "and dot-user-avatar")

	var authenticated: DotResult = await _authenticate("acc-4", "Margaret", SERVER_A)
	var admitted: DotResult = await hub.admit(authenticated.value)

	if not _check(admitted.ok, "a player is admitted", str(admitted.error)):
		return

	var player: DotPlatformPlayer = admitted.value

	_check(player.is_ready(), "and reaches READY", player.stage_name())
	_check(player.profile != null, "with a profile")
	_check(player.avatar != null, "and an avatar")
	_check(player.display_name() == "Margaret", "and the right name")
	_check(
		player.needs_onboarding,
		"and is flagged for first-time setup, having never made an avatar"
	)

	# The account id is available exactly once, for the derivation, and never leaves.
	_check(
		player.account_uid() == "backbone:acc-4",
		"the account id is reachable for the derivation"
	)
	_check(
		player.key() != player.account_uid(),
		"but the key everything else uses is not it"
	)
	_check(
		not str(player.to_public_dict()).contains("acc-4"),
		"and the public view does not leak it"
	)
	_check(
		not str(player.to_public_dict()).contains("preferences"),
		"nor the player's preferences"
	)

	_check(hub.count() == 1, "the platform is holding one player")
	_check(hub.player(player.key()) == player, "and can find them by key")

	# A returning player is no longer new.
	var again: DotResult = await hub.admit(authenticated.value)
	_check(again.ok, "the same player is admitted again")

	hub.release(player.key())
	_check(hub.count() == 0, "releasing them empties the platform")

	hub.queue_free()
	users.queue_free()
	avatars.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_degraded_paths() -> void:
	print("degraded paths")

	var users := _make_users("server:%s" % SERVER_A)
	await users.setup()
	var avatars := _make_avatars()
	await avatars.setup()
	var hub := _make_platform()
	await hub.setup()

	var authenticated: DotResult = await _authenticate("acc-5", "Dorothy", SERVER_A)

	# A profile store that cannot answer must not stop a player from playing, and
	# must not let anything overwrite the profile it failed to read.
	users.clear_cache()
	var store := users.store as DotUserStoreLocal

	# Point the store somewhere unreadable by removing the directory it is open on
	# and replacing it with a file of the same name.
	DotPaths.remove_tree(PROFILE_DIR)
	var blocker := FileAccess.open(PROFILE_DIR, FileAccess.WRITE)
	if blocker != null:
		blocker.store_string("not a directory")
		blocker.close()

	var admitted: DotResult = await hub.admit(authenticated.value)

	_check(
		admitted.ok,
		"a player is still admitted when the profile store is broken"
	)

	if admitted.ok:
		var player: DotPlatformPlayer = admitted.value
		_check(player.is_ready(), "and reaches READY")
		_check(
			player.avatar != null,
			"and still has an avatar, so they are visible"
		)

	# Put the directory back for the remaining tests.
	if FileAccess.file_exists(PROFILE_DIR):
		DirAccess.open("user://").remove(PROFILE_DIR.get_file())

	hub.queue_free()
	users.queue_free()
	avatars.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_absent_addons() -> void:
	print("absent addons")

	# Nothing registered at all: the platform must still admit a player, or a game
	# that only wanted authentication has been made to install everything.
	var hub := _make_platform()
	await hub.setup()

	_check(hub.users() == null, "no dot-user is installed")
	_check(hub.avatars() == null, "no dot-user-avatar is installed")

	var authenticated: DotResult = await _authenticate("acc-6", "Joan", SERVER_A)
	var admitted: DotResult = await hub.admit(authenticated.value)

	if not _check(admitted.ok, "a player is still admitted", str(admitted.error)):
		hub.queue_free()
		return

	var player: DotPlatformPlayer = admitted.value

	_check(player.is_ready(), "and reaches READY")
	_check(player.profile == null, "with no profile")
	_check(player.avatar == null, "and no avatar")
	_check(
		player.display_name() == "Joan",
		"but still a usable name, taken from the identity"
	)
	_check(player.key() == "", "and no scoped key, because nothing derives one")

	hub.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	# dot-user without dot-user-avatar: a profile, no avatar, and nothing asks.
	var users := _make_users("server:%s" % SERVER_A)
	await users.setup()
	var partial := _make_platform()
	await partial.setup()

	var half: DotResult = await partial.admit(
		(await _authenticate("acc-7", "Hedy", SERVER_A)).value
	)

	_check(half.ok, "dot-user alone is a working configuration")
	_check(
		half.ok and (half.value as DotPlatformPlayer).profile != null,
		"the player has a profile"
	)
	_check(
		half.ok and (half.value as DotPlatformPlayer).avatar == null,
		"and no avatar, without that being an error"
	)

	partial.queue_free()
	users.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_wardrobe() -> void:
	print("changing an avatar")

	var users := _make_users("server:%s" % SERVER_A)
	await users.setup()
	var avatars := _make_avatars()
	await avatars.setup()
	var hub := _make_platform()
	await hub.setup()

	# Entitlements come from the game, resolved once at admission.
	hub.entitlement_source = func(_identity: Object) -> DotAvatarEntitlements:
		return DotAvatarEntitlements.of([&"hair_paid"])

	var authenticated: DotResult = await _authenticate("acc-8", "Radia", SERVER_A)
	var admitted: DotResult = await hub.admit(authenticated.value)

	if not _check(admitted.ok, "a player with entitlements is admitted"):
		return

	var player: DotPlatformPlayer = admitted.value

	_check(
		player.entitlements != null and player.entitlements.holds(&"hair_paid"),
		"and carries what they own"
	)

	var wanted := _schema.default_avatar()
	wanted.set_part(&"hair", &"hair_paid")

	var changed: DotResult = await hub.set_avatar(player.key(), wanted)

	_check(changed.ok, "they can wear something they own", str(changed.error))
	_check(
		not player.needs_onboarding,
		"and are no longer flagged for first-time setup"
	)
	_check(
		player.profile != null and player.profile.onboarded,
		"which is recorded on the profile, so a reconnect does not repeat it"
	)

	# The check that matters: entitlements come from admission, not from the client.
	var forbidden := _schema.default_avatar()
	forbidden.set_part(&"hair", &"hair_paid")

	var stranger: DotResult = await hub.admit(
		(await _authenticate("acc-9", "Evelyn", SERVER_A)).value
	)

	# Reset the source so this player genuinely owns nothing.
	hub.entitlement_source = Callable()
	var poor: DotResult = await hub.admit(
		(await _authenticate("acc-10", "Annie", SERVER_A)).value
	)
	var poor_player: DotPlatformPlayer = poor.value

	var refused: DotResult = await hub.set_avatar(poor_player.key(), forbidden)

	_check(
		not refused.ok,
		"and cannot wear something they do not"
	)
	_check(
		refused.code() == DotError.CODE_FORBIDDEN,
		"with a code the caller can branch on",
		refused.code()
	)

	# A reconnect keeps the wardrobe. The entitlement source is restored first,
	# because the player still owns the item — clearing it above was to give the
	# next player nothing, and leaving it cleared would test the wrong thing.
	hub.entitlement_source = func(_identity: Object) -> DotAvatarEntitlements:
		return DotAvatarEntitlements.of([&"hair_paid"])

	hub.release(player.key())
	avatars.clear_cache()
	users.clear_cache()

	var returning: DotResult = await hub.admit(authenticated.value)

	_check(returning.ok, "the player reconnects")
	_check(
		returning.ok
			and (returning.value as DotPlatformPlayer).avatar.digest() == wanted.digest(),
		"wearing what they chose last time",
		"%s vs %s" % [
			(returning.value as DotPlatformPlayer).avatar.digest(), wanted.digest()
		] if returning.ok else "?"
	)
	_check(
		returning.ok and not (returning.value as DotPlatformPlayer).needs_onboarding,
		"and is not sent back through first-time setup"
	)

	# And the other direction, which the first version of this test hit by accident:
	# a player who has [i]lost[/i] the entitlement still loads, wearing something
	# else. That is dot-user-avatar conforming rather than refusing, and it is the
	# difference between a revoked item and a player who cannot log in.
	hub.entitlement_source = Callable()
	hub.release(player.key())
	avatars.clear_cache()
	users.clear_cache()

	var repossessed: DotResult = await hub.admit(authenticated.value)

	_check(repossessed.ok, "a player who lost the item still connects")

	if repossessed.ok:
		var stripped: DotPlatformPlayer = repossessed.value
		_check(
			not stripped.avatar.has_slot(&"hair"),
			"with the item removed rather than the whole avatar refused"
		)
		_check(
			_schema.validate(stripped.avatar, DotAvatarEntitlements.none()).ok,
			"and what they are left wearing is valid"
		)

	hub.queue_free()
	users.queue_free()
	avatars.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()
