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

const CHECKS := 90

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 9

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

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
	await _test_game_identity()
	await _test_site_profiles()

	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	DotPaths.remove_tree(PROFILE_DIR)
	DotPaths.remove_tree(AVATAR_DIR)
	if FileAccess.file_exists(SCOPE_KEY):
		DirAccess.open("user://").remove(SCOPE_KEY.get_file())
	DotRegistry.clear()


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


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
	_section("dot-auth to dot-user")

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
	_done()


func _test_profile_to_avatar() -> void:
	_section("dot-user to dot-user-avatar")

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
	_done()


func _test_scoping_across_servers() -> void:
	_section("scoping across servers")

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
	_done()


func _test_full_admission() -> void:
	_section("full admission")

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
	_done()


func _test_degraded_paths() -> void:
	_section("degraded paths")

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
	_done()


func _test_absent_addons() -> void:
	_section("absent addons")

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
	_done()


func _test_wardrobe() -> void:
	_section("changing an avatar")

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
	_done()


## [DotPlatformIdentity]: the layer every game built for itself, built once.
##
## What a game relies on is the fallback order of [method DotPlatformIdentity.avatar_for]
## — the platform's answer, then the game's stock avatar, then the schema's default — and
## that the chain it builds is the one the hub finds through the registry. A layer that
## built the managers without registering them would set up cleanly and admit everybody
## with no profile and no avatar, which every other check here would also call success.
func _test_game_identity() -> void:
	_section("the shared identity layer")

	var stock := _schema.default_avatar()
	stock.set_part(&"hair", &"hair_free")
	var asked: Array[StringName] = []

	var identity := DotPlatformIdentity.new()
	identity.avatar_schema = _schema
	identity.stock_avatar_fn = func(key: StringName) -> DotAvatar:
		asked.append(key)
		return stock
	add_child(identity)

	var ready: DotResult = await identity.setup()

	if not _check(ready.ok, "it builds the whole chain", str(ready.error)):
		identity.queue_free()
		return

	_check(identity.cloud == null, "with no content sources, no cloud client")
	_check(
		identity.platform != null and identity.platform.users() == identity.users
			and identity.platform.avatars() == identity.avatars,
		"and the hub finds ITS profile and avatar managers through the registry"
	)
	_check(
		identity.avatars != null and identity.avatars.schema == _schema,
		"validating against the game's schema, not one of its own"
	)
	_check(
		identity.platform_module().platform == identity.platform
			and identity.platform_module() == identity.platform_module(),
		"and hands out one platform module bound to that hub"
	)

	var unknown := identity.avatar_for("u404")
	_check(
		unknown == stock and asked.has(&"u404"),
		"a player the platform does not hold gets the game's stock avatar, by key",
		str(asked)
	)

	var authenticated: DotResult = await _authenticate("acc-11", "Hedy", SERVER_A)
	var admitted: DotResult = await identity.platform.admit(authenticated.value)

	if _check(admitted.ok, "a player is admitted through it", str(admitted.error)):
		var player: DotPlatformPlayer = admitted.value
		_check(
			identity.avatar_for(player.key()) == player.avatar and player.avatar != null,
			"and is drawn in what the platform resolved for them, not the stock one"
		)
		# With nothing stored, what the platform resolves is the GAME's stock look for this
		# player's scoped key — not the schema's one default, which is everybody alike.
		_check(
			player.avatar.digest() == stock.digest() and asked.has(StringName(player.key())),
			"a first-time player is resolved to the game's stock look, by their scoped key",
			str(asked)
		)

	identity.stock_avatar_fn = Callable()
	var plain := identity.avatar_for("u405")
	_check(
		plain != null and plain.digest() == _schema.default_avatar().digest(),
		"with no stock function, a stranger gets the schema's default — never null"
	)

	identity.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	# A game with no avatars at all: no manager, and null is the honest answer.
	var bare := DotPlatformIdentity.new()
	add_child(bare)
	var bare_ready: DotResult = await bare.setup()
	_check(
		bare_ready.ok and bare.avatars == null and bare.avatar_for("u1") == null,
		"no schema builds no avatar manager, and nobody has an avatar",
		str(bare_ready.error)
	)
	bare.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	# A host with an integration credential: avatars come from the SITE. Without this the
	# manager's store was a local file, and every avatar a member chose on the site stayed
	# there. A plain object with a config stands in for dot-auth's client, as the registry
	# lookup is duck-typed on purpose.
	var credential := DotAuthConfig.new()
	credential.backbone_url = "https://site.example"
	credential.integration_token = "tmci_test"
	var fake_client := FakeBackboneHolder.new()
	fake_client.config = credential
	DotRegistry.register(&"dot_backbone_client", fake_client)

	var sited := DotPlatformIdentity.new()
	sited.avatar_schema = _schema
	var translated_from: Array = []
	sited.avatar_translate_fn = func(foreign: DotAvatar) -> DotAvatar:
		translated_from.append(foreign.schema_id)
		return _schema.default_avatar()
	add_child(sited)
	await sited.setup()
	var site_store := sited.avatars.store as DotAvatarStoreBackbone if sited.avatars != null else null
	_check(
		site_store != null and site_store.base_url == "https://site.example/api/integration/v1"
			and site_store.read_only,
		"with the host's integration credential, avatars are read from the site, read only",
		str(sited.avatars.store) if sited.avatars != null else "no manager"
	)
	# The store's HTTP client has to be in the tree or no request leaves the process: it
	# was an orphan once, and every member wore the game's stock look on every server.
	_check(
		site_store != null and site_store.http != null and site_store.http.is_inside_tree(),
		"and the site store's HTTP client is in the tree, so a read reaches the network"
	)
	var foreign := DotAvatar.make(&"builtin")
	var as_ours: Variant = sited.avatars.translate_fn.call(foreign) if sited.avatars != null else null
	_check(
		as_ours is DotAvatar and translated_from == [&"builtin"],
		"and a site avatar reaches the game's own translation"
	)
	sited.avatar_translate_fn = Callable()
	_check(
		sited.avatars != null and sited.avatars.translate_fn.call(foreign) == null,
		"which, unset, leaves the member in the game's stock look"
	)
	sited.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()
	_done()


func _test_site_profiles() -> void:
	_section("profiles on the site")

	# [b]A real HTTP server on loopback, and the real DotHttp in front of it.[/b] The avatar
	# store's client was an orphan Node for weeks and every check passed, because they all
	# faked the client; nothing here fakes anything between the store and the socket.
	var site := MiniSite.new()
	add_child(site)

	if not _check(site.start(), "a loopback site is listening", "port %d" % site.port):
		site.queue_free()
		return

	var credential := DotAuthConfig.new()
	credential.backbone_url = "http://127.0.0.1:%d" % site.port
	credential.integration_token = "tmci_seam"
	var holder := FakeBackboneHolder.new()
	holder.config = credential
	DotRegistry.register(&"dot_backbone_client", holder)

	var server_a := DotPlatformIdentity.new()
	server_a.avatar_schema = _schema
	add_child(server_a)
	await server_a.setup()

	var routed := server_a.users.store as DotPlatformProfileStore if server_a.users != null else null
	var site_store := routed.site as DotUserStoreBackbone if routed != null else null
	_check(
		site_store != null and routed.local is DotUserStoreLocal
			and site_store.base_url == "http://127.0.0.1:%d/api/integration/v1" % site.port,
		"with the host's credential, profiles route between the site and this server's disk",
		str(server_a.users.store) if server_a.users != null else "no manager"
	)
	_check(
		site_store != null and site_store.http != null and site_store.http.is_inside_tree(),
		"and the site store's HTTP client is in the tree"
	)

	# A member the site issued a key for: what dot-auth's scoped introspection builds.
	var site_key := "SeamSiteKey0000000000a"
	var member: DotAuthIdentity = DotAuthIdentity.from_scoped_user(
		{"key": site_key, "name": "Grace"}
	).value
	var admitted: DotResult = await server_a.platform.admit(member)
	var asked := site.requests_for(site_key)
	_check(
		admitted.ok and asked.size() == 1 and asked[0]["method"] == "GET"
			and asked[0]["auth"] == "Bearer tmci_seam",
		"a site-issued player's profile is read from the site, on the server's credential",
		str(asked)
	)

	var player: DotPlatformPlayer = admitted.value if admitted.ok else null
	var profile: DotUserProfile = player.profile if player != null else null
	_check(
		profile != null and profile.user_key == site_key and not player.degraded,
		"a 404 there is a first-time player with a real profile, not a degraded one"
	)

	if profile != null:
		profile.set_preference("crosshair", "dot")
	server_a.platform.release(site_key)
	await _settle(func() -> bool: return site.profiles.has(site_key))
	_check(
		site.profiles.has(site_key)
			and (site.profiles[site_key] as Dictionary).get("preferences", {}).get("crosshair") == "dot",
		"and saved to the site when they leave",
		str(site.requests_for(site_key))
	)

	# A player whose key this server derived itself: the site never minted it, and
	# sending it would make every read a first-time player and every save an ERROR.
	var local_player: DotResult = await _authenticate("acc-site-1", "Linus", SERVER_A)
	var local_admit: DotResult = await server_a.platform.admit(local_player.value)
	var local_key: String = (local_admit.value as DotPlatformPlayer).key() if local_admit.ok else ""
	server_a.platform.release(local_key)
	await get_tree().create_timer(0.3).timeout
	_check(
		local_admit.ok and local_key != "" and site.requests_for(local_key).is_empty()
			and site.requests_for("").size() == 2,
		"a locally derived key never reaches the site's profile routes, read or save",
		"%s; %s" % [local_key, str(site.requests_for(""))]
	)
	_check(
		routed != null and routed.local_requests >= 2 and FileAccess.file_exists(
			"user://profiles/%s.json" % local_key
		),
		"its profile is on this server's disk",
		str(routed.describe()) if routed != null else ""
	)

	# Server B: another process sharing the credential's scope. The profile followed.
	server_a.queue_free()
	await get_tree().process_frame
	DotRegistry.unregister(&"dot_user_manager")
	DotRegistry.unregister(&"dot_avatar_manager")
	DotRegistry.unregister(&"dot_platform")

	var server_b := DotPlatformIdentity.new()
	server_b.avatar_schema = _schema
	add_child(server_b)
	await server_b.setup()
	var again: DotResult = await server_b.platform.admit(member)
	var followed: DotUserProfile = (again.value as DotPlatformPlayer).profile if again.ok else null
	_check(
		followed != null and followed.preferences.get("crosshair") == "dot",
		"on another server, the same member arrives with the profile they left",
		str(followed.to_dict()) if followed != null else str(again.error)
	)
	server_b.queue_free()
	await get_tree().process_frame
	DotRegistry.unregister(&"dot_user_manager")
	DotRegistry.unregister(&"dot_avatar_manager")
	DotRegistry.unregister(&"dot_platform")

	# A credential enrolled before the profile scopes: the site answers 403. Said once,
	# and the server keeps profiles itself, rather than degrading every member.
	site.refuse_with = 403
	var refused := DotPlatformIdentity.new()
	refused.avatar_schema = _schema
	add_child(refused)
	await refused.setup()
	var turned: DotResult = await refused.platform.admit(member)
	var turned_player: DotPlatformPlayer = turned.value if turned.ok else null
	var refused_store := refused.users.store as DotPlatformProfileStore
	_check(
		turned_player != null and not turned_player.degraded and refused_store != null
			and refused_store.site_refused,
		"a credential without the profile scopes falls back to this server's disk, not to a guest"
	)
	var before := site.requests_for("").size()
	refused.platform.release(site_key)
	await get_tree().create_timer(0.3).timeout
	_check(
		site.requests_for("").size() == before and refused_store != null
			and refused_store.store_count > 0 and refused_store.local_requests >= 2,
		"and saves there, without asking the site again",
		str(refused_store.describe()) if refused_store != null else ""
	)
	refused.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	# No credential at all: a LAN server, exactly as before.
	var lan := DotPlatformIdentity.new()
	add_child(lan)
	await lan.setup()
	_check(
		lan.users != null and lan.users.store is DotUserStoreLocal,
		"with no credential, profiles are this server's own"
	)
	lan.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	# And a host that turned it off keeps them local with the credential present.
	DotRegistry.register(&"dot_backbone_client", holder)
	var off := DotPlatformIdentity.new()
	off.use_backbone_profiles = false
	add_child(off)
	await off.setup()
	_check(
		off.users != null and off.users.store is DotUserStoreLocal,
		"use_backbone_profiles off keeps them local with a credential present"
	)
	off.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()

	site.queue_free()
	DotPaths.remove_tree("user://profiles")
	_done()


## Waits up to two seconds for [param ready] to hold, a frame at a time.
func _settle(ready: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while not bool(ready.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


## The site's four profile routes over a real socket, minimal HTTP/1.1, one request per
## connection. Holds what it was sent so a check can ask who called and with what.
class MiniSite extends Node:
	var port := 0
	## Every request: {method, path, auth, body}.
	var requests: Array = []
	## key -> the profile document last PUT.
	var profiles: Dictionary = {}
	## Non-zero answers every request with this status (a credential missing a scope).
	var refuse_with := 0

	var _server := TCPServer.new()
	var _conns: Array = []

	func start() -> bool:
		if _server.listen(0, "127.0.0.1") != OK:
			return false
		port = _server.get_local_port()
		return port > 0

	## Profile requests for [param key]; empty [param key] is every profile request. The
	## avatar store reads the same site on the same credential, and is not what this asks.
	func requests_for(key: String) -> Array:
		return requests.filter(func(r: Dictionary) -> bool:
			var path := str(r["path"])
			return (path.ends_with("/profile") or path.ends_with("/public")) \
				and (key == "" or path.contains("/%s/" % key)))

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_conns.append({"peer": _server.take_connection(), "buf": PackedByteArray()})

		for conn: Dictionary in _conns.duplicate():
			var peer: StreamPeerTCP = conn["peer"]
			peer.poll()

			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_conns.erase(conn)
				continue

			var waiting := peer.get_available_bytes()

			if waiting > 0:
				var got: Array = peer.get_partial_data(waiting)
				if int(got[0]) == OK:
					# A packed array in a Dictionary is a copy on read: append, then put back.
					var grown: PackedByteArray = conn["buf"]
					grown.append_array(got[1])
					conn["buf"] = grown

			var answer := _answer(conn["buf"])

			if answer.is_empty():
				continue

			peer.put_data(answer)
			peer.disconnect_from_host()
			_conns.erase(conn)

	## The full response once a whole request has arrived, else empty.
	func _answer(buf: PackedByteArray) -> PackedByteArray:
		var text := buf.get_string_from_ascii()
		var head_end := text.find("\r\n\r\n")

		if head_end < 0:
			return PackedByteArray()

		var lines := text.substr(0, head_end).split("\r\n")
		var length := 0
		var auth := ""

		for line in lines:
			var lower := line.to_lower()
			if lower.begins_with("content-length:"):
				length = int(line.substr(15).strip_edges())
			elif lower.begins_with("authorization:"):
				auth = line.substr(14).strip_edges()

		if buf.size() < head_end + 4 + length:
			return PackedByteArray()

		var body := buf.slice(head_end + 4, head_end + 4 + length).get_string_from_utf8()
		var first := lines[0].split(" ")
		var method := first[0]
		var path := first[1] if first.size() > 1 else ""
		requests.append({"method": method, "path": path, "auth": auth, "body": body})

		var status := 200
		var reply: Variant = {"ok": true}
		var parts := path.split("/")
		var key := parts[parts.size() - 2] if parts.size() >= 2 else ""

		if refuse_with != 0:
			status = refuse_with
			reply = {"error": "Missing scope(s): PROFILE_READ."}
		elif not path.begins_with("/api/integration/v1/user/") or auth != "Bearer tmci_seam":
			status = 401
			reply = {"error": "no"}
		elif method == "GET":
			if profiles.has(key):
				reply = {"ok": true, "profile": profiles[key]}
			else:
				status = 404
				reply = {"error": "Not found."}
		elif method == "PUT":
			var doc: Variant = JSON.parse_string(body)
			profiles[key] = doc
		elif method == "DELETE":
			profiles.erase(key)

		var payload := JSON.stringify(reply).to_utf8_buffer()
		var head := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
		var out := head.to_ascii_buffer()
		out.append_array(payload)
		return out


## Stands in for dot-auth's DotBackboneClient in the registry: what the identity layer
## reads is its config, and only that.
class FakeBackboneHolder extends RefCounted:
	var config: DotAuthConfig = null
