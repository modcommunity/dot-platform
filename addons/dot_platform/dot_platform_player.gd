class_name DotPlatformPlayer
extends RefCounted

## Everything the platform knows about one connected person, in one place.
##
## [b]Three addons answer three different questions and none of them knows about the
## others.[/b] dot-auth says who this is; dot-user says what we know about them;
## dot-user-avatar says what they look like. That independence is deliberate — each
## works without the other two — and the cost is that nothing holds the whole picture.
## This does.
##
## The join order is not arbitrary and is the thing most easily got wrong:
##
## [codeblock]
## identity.uid          "backbone:acc-1"    global, never shown to a server
##      -> profile.user_key  "Zm9vYmFy..."  scoped, what everything else keys on
##      -> avatar under the SAME scoped key
## [/codeblock]
##
## Keying the avatar on [code]identity.uid[/code] instead would work perfectly in
## testing and quietly hand every server operator a global identifier — which is the
## exact thing dot-user's scoping exists to prevent. [DotPlatform] is the only place
## that translation happens.

## How far admission got.
enum Stage {
	## Nothing has happened yet.
	NEW,
	## dot-auth vouched for them.
	AUTHENTICATED,
	## dot-user resolved or created a profile.
	PROFILED,
	## dot-user-avatar resolved an avatar.
	DRESSED,
	## Everything resolved and the player may enter the world.
	READY,
	## Admission stopped. See [member refusal].
	REFUSED,
}

## Whatever dot-auth produced. Duck-typed: uid, display_name, is_guest.
##
## Deliberately [Object] rather than [code]DotAuthIdentity[/code]: dot-platform runs
## on a server with no dot-auth installed too, where dot-server supplies its own
## guest identity with the same three fields.
var identity: Object = null

## The profile, when dot-user is installed.
var profile: DotUserProfile = null

## The avatar, when dot-user-avatar is installed.
var avatar: DotAvatar = null

## What this player is allowed to wear.
var entitlements: DotAvatarEntitlements = null

var stage: Stage = Stage.NEW

## Why admission stopped, when [member stage] is [constant Stage.REFUSED].
var refusal: DotError = null

## Whether the player still has to go through first-time setup.
##
## [b]The one thing the platform flow branches on.[/b] Signed in but no avatar means
## the editor opens before they spawn; see [DotPlatform.needs_onboarding].
var needs_onboarding: bool = false

## Set when the profile came back as a session-only stand-in because the store could
## not answer. Nothing here may be persisted.
var degraded: bool = false

## Unix seconds admission started.
var admitted_at: int = 0

## Free-form space for a game's own per-player platform state.
var data: Dictionary = {}


static func for_identity(p_identity: Object) -> DotPlatformPlayer:
	var player := DotPlatformPlayer.new()
	player.identity = p_identity
	player.stage = Stage.AUTHENTICATED if p_identity != null else Stage.NEW
	player.admitted_at = int(Time.get_unix_time_from_system())
	return player


## The scoped id everything below dot-auth keys on.
##
## Empty until the profile resolves. [b]Never the account id[/b] — see the class
## documentation for why that distinction is the whole point.
func key() -> String:
	return profile.user_key if profile != null else ""


## The account id dot-auth issued. Global, and it must not leave this object.
##
## Named to be conspicuous at the call site: anything that stores, logs or transmits
## this is undoing the scoping. It exists because admission needs it exactly once, to
## derive the scoped key.
func account_uid() -> String:
	return str(identity.get("uid")) if identity != null else ""


func is_guest() -> bool:
	return identity != null and bool(identity.get("is_guest"))


func display_name() -> String:
	if profile != null and profile.display_name != "":
		return profile.display_name

	if identity != null:
		var supplied := str(identity.get("display_name"))
		if supplied != "":
			return supplied

	return "unnamed"


func is_ready() -> bool:
	return stage == Stage.READY


func was_refused() -> bool:
	return stage == Stage.REFUSED


func refuse(error: DotError) -> void:
	stage = Stage.REFUSED
	refusal = error


## What another player is allowed to see about this one.
##
## Preferences and the account id are absent by construction. A scoreboard needs a
## name and an avatar digest; anything more is a leak that is very hard to notice,
## because it looks like a working scoreboard.
func to_public_dict() -> Dictionary:
	return {
		"key": key(),
		"name": display_name(),
		"avatar": avatar.digest() if avatar != null else "",
	}


func stage_name() -> String:
	return Stage.keys()[stage]


func describe() -> Dictionary:
	return {
		"stage": stage_name(),
		"key": key() if key() != "" else "<unresolved>",
		"name": display_name(),
		"guest": is_guest(),
		"avatar": avatar.digest() if avatar != null else "<none>",
		"onboarding": needs_onboarding,
		"degraded": degraded,
		"refusal": str(refusal) if refusal != null else "",
	}


func _to_string() -> String:
	return "DotPlatformPlayer(%s '%s' %s)" % [
		key() if key() != "" else "?", display_name(), stage_name()
	]
