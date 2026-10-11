class_name DotPlatformProfileStore
extends DotUserStore

## Profiles of players the site issued a key for live on the site; everybody else's stay
## on this server.
##
## [b]Why two stores, routed per key.[/b] A player who signed in through the site arrives
## with the key the site minted for this server's credential (dot-auth's scoped
## introspection puts it in the `scoped_key` claim), and the site's profile route resolves
## exactly those keys, so their profile follows them to every server sharing that scope.
## Everybody else — a guest with guest profiles on, a local account, any identity whose key
## dot-user derived from this server's own secret — has a key the site never minted and
## answers [code]404[/code] for: every read would look like a first-time player and every
## save on leave would fail and log an ERROR. So the site store sees only keys the site
## issued ([method note_issued], called by [DotPlatformUsers.key_for]) and the local store
## sees the rest, exactly as it did before the site held profiles.
##
## [b]A credential the site refuses falls back for good.[/b] A server enrolled before its
## credential carried PROFILE_READ / PROFILE_WRITE gets a 401 or 403 on the first read.
## That is a configuration, not an outage, so it is said once, and every key goes to the
## local store for the rest of the process: the behaviour the server had before, rather
## than a session-only profile and a WARN for every player who joins. Any other failure
## (the site unreachable, a timeout) is passed through, and [DotUserManager] degrades that
## one player to a session-only profile that is never written over the real one.

const ROUTER_CHANNEL := "platform.profiles"

## The site's store, over the server's integration credential.
var site: DotUserStore = null

## Where every key the site did not issue lives. Required.
var local: DotUserStore = null

## True once the site refused this server's credential; see the class note.
var site_refused: bool = false

## Keys the site issued, as reported by [method note_issued]. A key is a 22-character
## string per player who has joined, so a long-running server holds a few kilobytes.
var _issued: Dictionary = {}

## Requests routed to each side. Diagnostic.
var site_requests: int = 0
var local_requests: int = 0


## Routes [param site_store] and [param local_store]. Null [param site_store] routes
## everything locally.
static func over(site_store: DotUserStore, local_store: DotUserStore) -> DotUserStore:
	# `new()`, not this class's own name: a script naming itself in an expression can cut
	# Godot 4.7.2's exit teardown short (docs/gdscript-hazards.md).
	var s := new()
	s.site = site_store
	s.local = local_store
	return s


## Marks [param user_key] as one the site issued, so its profile is read and written there.
##
## Called with the key the manager resolved, before the read: [DotPlatformUsers] does it
## from [method DotUserManager.key_for], which is where the claim is in hand.
func note_issued(user_key: String) -> void:
	_issued[user_key] = true


func is_issued(user_key: String) -> bool:
	return _issued.has(user_key)


## The store [param user_key] belongs to.
func store_for(user_key: String) -> DotUserStore:
	if site != null and not site_refused and _issued.has(user_key):
		return site

	return local


func _store_name() -> String:
	return "DotPlatformProfileStore"


func _writable() -> bool:
	return local != null and local.is_writable()


func _open() -> DotResult:
	if local == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "The platform profile store needs a local store."
		)

	var opened: DotResult = await local.open()

	if not opened.ok:
		return opened

	if site != null:
		var reached: DotResult = await site.open()

		if not reached.ok:
			# Not fatal: the site store is reopened on its first use, and a player whose
			# read then fails is degraded to a session-only profile by the manager.
			DotLog.warn(ROUTER_CHANNEL, "the site's profile store did not open", {
				"error": str(reached.error)
			})

	return DotResult.success(true)


func _close() -> void:
	if local != null:
		local.close()

	if site != null:
		site.close()


# [b]The inner stores' own `_fetch` / `_store` / `_remove`, not their public methods.[/b]
# This store's public methods have already checked the key, validated the profile and
# stamped it; going through the inner public method again would do all of that twice and,
# on a failed write, log the ERROR twice — once per store — for one lost save.

func _fetch(user_key: String) -> DotResult:
	var target: DotUserStore = await _ready_store(user_key)
	var res: DotResult = await target._fetch(user_key)

	if target == site and _refused(res):
		return await _fetch(user_key)

	return res


func _store(profile: DotUserProfile) -> DotResult:
	var target: DotUserStore = await _ready_store(profile.user_key)

	if not target.is_writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This profile store is read-only.", target._store_name()
		)

	var res: DotResult = await target._store(profile)

	if target == site and _refused(res):
		return await _store(profile)

	return res


func _remove(user_key: String) -> DotResult:
	var target: DotUserStore = await _ready_store(user_key)
	var res: DotResult = await target._remove(user_key)

	if target == site and _refused(res):
		return await _remove(user_key)

	return res


## [method store_for], opened. A site store that will not open is passed on as it is: its
## request then fails, and the caller degrades that one player.
func _ready_store(user_key: String) -> DotUserStore:
	var target := store_for(user_key)

	if target == site:
		site_requests += 1
	else:
		local_requests += 1

	if not target.is_open():
		await target.open()

	return target


## Whether [param res] is the site refusing this server's credential (401 or 403), and if
## so, stops routing to it. The caller then retries locally.
func _refused(res: DotResult) -> bool:
	if res.ok or res.error == null:
		return false

	if res.error.http_status != 401 and res.error.http_status != 403:
		return false

	site_refused = true
	DotLog.warn(
		ROUTER_CHANNEL,
		"the site refused this server's credential for profiles; they stay on this server",
		{
			"status": res.error.http_status,
			"fix": "grant the server's integration credential PROFILE_READ and PROFILE_WRITE",
		}
	)
	return true


func describe() -> Dictionary:
	var out := super.describe()
	out["site"] = site.describe() if site != null else {}
	out["local"] = local.describe() if local != null else {}
	out["site_refused"] = site_refused
	out["issued_keys"] = _issued.size()
	out["site_requests"] = site_requests
	out["local_requests"] = local_requests
	return out
