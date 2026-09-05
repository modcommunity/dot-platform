@tool
class_name DotPlatformConfig
extends DotConfig

## How admission behaves. Layered like every [DotConfig]: exported defaults, then a
## JSON file, then [code]DOT_PLATFORM_*[/code] environment variables, then
## [code]--platform-*[/code] arguments.

@export_group("Admission")

## Refuse a player whose profile could not be resolved.
##
## Off is the default and is the right one for a sandbox: dot-user already degrades to
## a session-only profile when its store cannot answer, so the player keeps playing
## and loses nothing that was saved. On is for a server where the profile carries
## something the game cannot run without.
@export var require_profile: bool = false

## Refuse a player who has no avatar rather than dressing them in the default.
##
## Off means a first-time player spawns in the schema's default and can change it
## whenever they like — which is what a sandbox wants. On is the "make an avatar
## before you play" flow, and needs a client that can actually show the editor.
@export var require_avatar: bool = false

## Seconds admission may take before the player is let in anyway.
##
## [b]A player must never be held indefinitely because a store is slow.[/b] Past this
## they enter with whatever resolved, which for a sandbox is a default avatar and a
## session-only profile. The alternative is a queue of people watching a loading bar
## because a backbone is having a bad afternoon.
@export_range(0.5, 120.0, 0.5) var admission_timeout_sec: float = 8.0

@export_group("Presentation")

## Push the platform's display name onto the dot-server session.
##
## dot-server takes the name from the identity; the profile's is the one the player
## actually chose, so for a guest who renamed themselves the two differ. On means the
## scoreboard shows what the player picked.
@export var apply_profile_name: bool = true

## Tell every other client when somebody's avatar changes.
##
## What makes a wardrobe change visible without a reconnect. Costs one small message
## per change per observer.
@export var broadcast_avatar_changes: bool = true

@export_group("Onboarding")

## Consider a player onboarded once they have published any avatar.
##
## The alternative is trusting [code]DotUserProfile.onboarded[/code] alone, which a
## player can end up with set while having no avatar — for instance if the avatar
## store was wiped and the profile store was not.
@export var onboarded_needs_avatar: bool = true


func env_prefix() -> String:
	return "DOT_PLATFORM_"


func cli_prefix() -> String:
	return "--platform-"


func validate() -> DotResult:
	if require_avatar and admission_timeout_sec < 2.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"require_avatar needs a longer admission timeout.",
			"a person is choosing a hairstyle, not waiting on a socket"
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "%s%s timeout %.0fs" % [
		"profile-required " if require_profile else "",
		"avatar-required" if require_avatar else "avatar-optional",
		admission_timeout_sec,
	]
