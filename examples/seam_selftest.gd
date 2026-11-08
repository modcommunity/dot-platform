extends "res://examples/seam_selftest_base.gd"

## Runs dot-auth, dot-user, dot-user-avatar and dot-platform in one process with nothing
## mocked, and checks the handoffs: a game server must never see an account id, only its
## scoped derivation, and the avatar is filed under that. Run: `res://examples/seam_selftest.tscn`.

const CHECKS := 91

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 9


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

	await _wardrobe_reconnect(hub, users, avatars, player, authenticated, wanted)


## Reconnects keep the wardrobe, and a lost entitlement conforms rather than refuses.
func _wardrobe_reconnect(
	hub: DotPlatformHub, users: DotUserManager, avatars: DotAvatarManager,
	player: DotPlatformPlayer, authenticated: DotResult, wanted: DotAvatar
) -> void:
	# The source is restored first: the player still owns the item, and leaving it
	# cleared would test the wrong thing.
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

	# A player who has lost the entitlement still loads, wearing something else: a revoked
	# item is not a player who cannot log in.
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


## [DotPlatformIdentity]: the avatar fallback order (platform, stock, schema default) and
## that the chain it builds is the one the hub finds through the registry.
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

	await _identity_variants()
	_done()


## A game with no avatars, and a host whose avatars come from the site.
func _identity_variants() -> void:
	# No manager, and null is the honest answer.
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

	# With an integration credential avatars come from the SITE, not a local file. A plain
	# object with a config stands in for dot-auth's client; the registry lookup is duck-typed.
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
	# The store's HTTP client has to be in the tree or no request leaves the process.
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
	# An enrolled server already has the host's client: the identity must use it, not build a token-less second one.
	var reporting := DotPlatformIdentity.new()
	reporting.report_to_backbone = true
	add_child(reporting)
	var reported: DotResult = await reporting._build_backbone()
	_check(
		reported.ok and reporting.backbone == null
			and DotRegistry.get_service(&"dot_backbone_client") == fake_client,
		"with the host's backbone client registered, the identity builds none of its own and still succeeds",
		str(reported.error)
	)
	reporting.queue_free()
	sited.avatar_translate_fn = Callable()
	_check(
		sited.avatars != null and sited.avatars.translate_fn.call(foreign) == null,
		"which, unset, leaves the member in the game's stock look"
	)
	sited.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()


func _test_site_profiles() -> void:
	_section("profiles on the site")

	# A real HTTP server on loopback with the real DotHttp in front: nothing is faked
	# between the store and the socket.
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

	await _site_local_keys(site, server_a, routed)
	await _site_other_servers(site, server_a, member, site_key)
	await _site_without_credential(holder)

	site.queue_free()
	DotPaths.remove_tree("user://profiles")
	_done()


## A key this server derived itself never reaches the site's profile routes.
func _site_local_keys(site: MiniSite, server_a: DotPlatformIdentity, routed: DotPlatformProfileStore) -> void:
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



## Another server follows the profile; a credential without scopes falls back to disk.
func _site_other_servers(
	site: MiniSite, server_a: DotPlatformIdentity, member: DotAuthIdentity, site_key: String
) -> void:
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

	# The site answers 403: the server keeps profiles itself rather than degrading members.
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



## No credential is a LAN server; a host can also turn site profiles off.
func _site_without_credential(holder: Object) -> void:
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
