class_name DotPlatformUsers
extends DotUserManager

## dot-user's profile manager, telling the platform's profile store which keys the site
## issued.
##
## [b]Why a subclass and not a setting.[/b] Whether a key belongs to the site is a fact
## about the IDENTITY (dot-auth's scoped introspection puts the site's key in the
## `scoped_key` claim), and a store is only ever handed the key. [method key_for] is the
## one place both are in hand, and the manager calls it before it reads the store, so the
## store knows where the key lives before its first request. See [DotPlatformProfileStore].

## The site's profile store, set before this enters the tree. Null keeps every profile on
## this server, which is what a manager with no integration credential does.
var site_store: DotUserStore = null


func _build_store() -> DotResult:
	var built: DotResult = super._build_store()

	# An operator who configured the backbone backend themselves pointed every key at a
	# site of their choosing; that is theirs, and it is not routed.
	if not built.ok or site_store == null or config.backend == "backbone":
		return built

	return DotResult.success(DotPlatformProfileStore.over(site_store, built.value))


func key_for(identity: Object) -> DotResult:
	var keyed: DotResult = super.key_for(identity)

	if keyed.ok and store is DotPlatformProfileStore and _site_issued(identity):
		(store as DotPlatformProfileStore).note_issued(str(keyed.value))

	return keyed


## Whether the key [method key_for] resolved came from the site rather than this server.
##
## dot-user takes the claim's key whenever the claim is there and well formed (and refuses
## the identity when it is not), so the claim being present on a key that resolved is the
## whole test.
static func _site_issued(identity: Object) -> bool:
	var claims: Variant = identity.get("claims")
	return claims is Dictionary and (claims as Dictionary).has("scoped_key")
