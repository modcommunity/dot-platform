class_name DotPlatformIdentity
extends Node

## Who a player is, for a game: content delivery, a profile, an avatar, and one admission
## flow, built in the order they depend on each other.
##
## [codeblock]
## dot-cloud    downloads and mounts content. Registers `dot_cloud_client`.
## dot-auth     reports this server to its site listing, when asked to.
## dot-user     the profile that follows a player between servers.
## dot-avatar   what they look like, over the GAME's schema.
## dot-platform joins the three into ONE admission, as its own DotModule.
## [/codeblock]
##
## [b]This is the identity layer every game had a copy of.[/b] game-arena's was 262 lines
## and game-g2gfast's 215, and with the class names taken out they differed in one line:
## which avatar schema, and which stock avatar a player without one gets. Those are the two
## things a game hands this; everything else is the chain.
##
## [b]Authentication is not here.[/b] Proving who somebody is happens in dot-server's
## handshake, against whatever `dot_auth_server` the host registered; a deployment turns it
## on for every game it runs, and a game does not get a say. What this layer does is
## everything AFTER that: turning the proven identity into a scoped profile, a name and an
## avatar.
##
## [b]dot-cloud is registered or it is not built at all.[/b] Four call sites in two other
## addons look it up under `dot_cloud_client`, and every one of them treats an absent cloud
## as "this deployment ships its content in its build" — a legitimate configuration, and
## therefore indistinguishable from `DotCloudClient` once failing to publish itself, which
## left dot-server, dot-user-avatar and dot-map all finding null without one error between
## them. A registered client that failed to start is a third thing: present, found, and
## unable to do anything.
##
## [codeblock]
## var identity := DotPlatformIdentity.new()
## identity.avatar_schema = MyAvatars.schema()
## identity.stock_avatar_fn = MyAvatars.stock_avatar
## add_child(identity)
## await identity.setup()
## # By PATH: DotModuleHost constructs the module itself, and finds the hub this
## # registered. platform_module() is for a host that adds the node by hand.
## await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
## [/codeblock]
##
## A dot-game module returns one from `_make_identity()` and needs none of the last line:
## [code]DotGameModule[/code] loads the platform module itself.

const CHANNEL := "platform.identity"

@export_group("Content")

## Where delivered content is fetched from. Empty means everything ships in the build.
@export var content_urls: PackedStringArray = PackedStringArray()

## Directories searched before the network. A server serving content off its own disk.
@export var content_dirs: PackedStringArray = PackedStringArray()

@export_group("Backbone")

## Report the player count, the map and the roster to the site listing.
##
## Off by default. A server that phones home without its operator asking is a server
## nobody would run, and dot-auth's own defaults agree.
@export var report_to_backbone: bool = false

## Where the backbone is. Empty uses [DotAuthConfig]'s own default.
##
## [b]A default endpoint is a security property, not a convenience.[/b] dot-auth once
## shipped a domain that was not the site and was registered to nobody, so every deployment
## that did not override it aimed the opening request of an authentication flow at a name
## any stranger could buy.
@export var backbone_url: String = ""

@export_group("Admission")

## Refuse a player whose profile could not be resolved.
##
## Off. An unreachable profile store is a reason to let somebody play as a guest, not a
## reason to leave them at a loading screen.
@export var require_profile: bool = false

@export_group("Avatars")

## The game's avatar schema. Set before [method setup].
##
## [b]The game's own, never a second one.[/b] A game's renderer conforms every document to
## its schema before drawing it, so a manager validating against a different schema would
## accept avatars the renderer then silently rewrote. Null builds no avatar manager, and
## nobody has an avatar — which dot-platform already answers.
var avatar_schema: DotAvatarSchema = null

## `func(player_key: StringName) -> DotAvatar`: the avatar a player with none of their own
## gets. Unset, [method DotAvatarSchema.default_avatar] — which dresses everybody alike.
##
## A game usually derives it from the key, so two stock players are not identical and one
## player is the same on every machine and every visit.
var stock_avatar_fn: Callable = Callable()

var cloud: DotCloudClient = null
var users: DotUserManager = null
var avatars: DotAvatarManager = null
var platform: DotPlatformHub = null
var backbone: DotBackboneClient = null

var _module: DotPlatformModule = null


## Builds the whole chain. Returns the platform hub.
func setup() -> DotResult:
	# Awaited, and typed, every one. Each step may reach a network — a content source, a
	# profile store, an avatar store — and an un-awaited GDScript coroutine returns at its
	# first suspension, so the branch after it would be testing a property of a Signal.
	var clouded: DotResult = await _build_cloud()

	if not clouded.ok:
		return clouded

	if report_to_backbone:
		# Not fatal. A server that cannot reach the backbone is a server that runs without
		# a site listing, which is every LAN server there has ever been.
		var reached: DotResult = await _build_backbone()
		DotLog.result(CHANNEL, "the backbone client", reached)

	var usered: DotResult = await _build_users()

	if not usered.ok:
		return usered

	var avatared: DotResult = await _build_avatars()

	if not avatared.ok:
		return avatared

	var platformed: DotResult = await _build_platform()
	return platformed


func _build_cloud() -> DotResult:
	if content_urls.is_empty() and content_dirs.is_empty():
		# [b]No sources means no client, and building one anyway is worse than not.[/b]
		# `DotCloudClient.start` refuses when signing is required and no trusted key is
		# configured — correctly, because a client that mounts unsigned content will mount
		# anything a server sends it — and says so with a red line on every boot: the shape
		# this family calls "a warning that reads like a setting nobody has filled in".
		DotLog.info(CHANNEL, "content ships in this build", {
			"reason": "no content sources are configured"
		})
		return DotResult.success(null)

	cloud = DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.http_base_urls = content_urls
	cloud.local_search_dirs = content_dirs
	# Registered: the line whose absence cost four silent failures. See the class note.
	cloud.register_service = true
	add_child(cloud)

	var started: DotResult = await cloud.start()

	if not started.ok:
		# Downgraded rather than fatal: a game whose content ships in its build is the
		# ordinary case rather than a broken one.
		DotLog.info(CHANNEL, "content delivery is off", {"why": started.error.message})

	return DotResult.success(cloud)


func _build_backbone() -> DotResult:
	var config := DotAuthConfig.new()

	if backbone_url != "":
		config.backbone_url = backbone_url

	backbone = DotBackboneClient.new()
	backbone.name = "Backbone"
	backbone.config = config
	backbone.auto_report = true
	add_child(backbone)

	var ready: DotResult = await backbone.start()
	return ready


func _build_users() -> DotResult:
	users = DotUserManager.new()
	users.name = "Users"
	users.register_service = true
	add_child(users)

	var ready: DotResult = await users.setup()
	return ready


func _build_avatars() -> DotResult:
	if avatar_schema == null:
		DotLog.info(CHANNEL, "no avatars", {"reason": "the game gave no avatar schema"})
		return DotResult.success(null)

	avatars = DotAvatarManager.new()
	avatars.name = "Avatars"
	avatars.schema = avatar_schema
	# [b]The game's stock look for somebody with nothing stored, not the schema's one
	# document.[/b] Admission resolves a first-time player to the manager's default, and a
	# game prefers the platform's answer to its own — so without this, everybody the
	# platform had admitted was the same person, and the per-player variety a game draws
	# lasted exactly until the profile arrived. Asked with the scoped key, so a player is
	# the same person on every visit. Read at call time, so a game may set it late.
	avatars.default_avatar_fn = func(user_key: String) -> DotAvatar:
		if not stock_avatar_fn.is_valid():
			return null
		var stock: Variant = stock_avatar_fn.call(StringName(user_key))
		return stock as DotAvatar if stock is DotAvatar else null
	avatars.register_service = true
	add_child(avatars)

	var ready: DotResult = await avatars.setup()
	return ready


func _build_platform() -> DotResult:
	var config := DotPlatformConfig.new()
	config.require_profile = require_profile
	# Never. A player without an avatar gets a stock document that is a real avatar over
	# the same schema; refusing them would be refusing somebody for the colour of a capsule.
	config.require_avatar = false
	config.apply_profile_name = true
	config.broadcast_avatar_changes = true

	platform = DotPlatformHub.new()
	platform.name = "Platform"
	platform.config = config
	platform.load_layered_config = false
	platform.register_service = true
	add_child(platform)

	var ready: DotResult = await platform.setup()
	return ready


## The module a [DotServer] loads to put this in front of joining players.
##
## dot-platform ships its own [DotModule], which is the right shape: everything it
## registers is removed again when it unloads, and a game that wanted a different admission
## flow replaces one module rather than editing another.
func platform_module() -> DotPlatformModule:
	if _module == null:
		_module = DotPlatformModule.new()
		_module.platform = platform

	return _module


func _notification(what: int) -> void:
	# [b]The module is a Node outside the tree until a server loads it.[/b] One nothing
	# loaded — a dot-game module loads dot-platform's own by path, and a test asks only to
	# compare it — has no parent to free it, and outlives this layer as a leaked instance
	# holding the hub it was bound to. One a server DID load is the server's to free.
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_module) \
			and _module.get_parent() == null:
		_module.free()


## An avatar for a player: theirs if the platform resolved one, a stock one if not.
##
## [b]Never null while there is a schema, and that is the contract.[/b] A caller that had
## to branch on "did this player have an avatar" would be a caller that draws nothing for a
## guest, and a server full of invisible guests is worse than one full of identical ones.
## Null only when the game gave no schema, which is a game with no avatars.
func avatar_for(player_key: String) -> DotAvatar:
	if platform != null:
		var held := platform.player(player_key)

		if held != null and held.avatar != null:
			return held.avatar

	if stock_avatar_fn.is_valid():
		var stock: Variant = stock_avatar_fn.call(StringName(player_key))

		if stock is DotAvatar:
			return stock as DotAvatar

	if avatar_schema != null:
		return avatar_schema.default_avatar()

	return null


func describe() -> Dictionary:
	return {
		"cloud": cloud.describe() if cloud != null else {},
		"users": users.describe() if users != null else {},
		"avatars": avatars.describe() if avatars != null else {},
		"platform": platform.describe() if platform != null else {},
		"backbone": backbone.describe() if backbone != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if platform != null:
		out.append_array(platform.describe_lines())

	if users != null:
		out.append_array(users.describe_lines())

	if avatars != null:
		out.append_array(avatars.describe_lines())

	return out
