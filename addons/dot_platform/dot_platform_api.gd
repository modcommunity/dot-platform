extends RefCounted

## dot-platform's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.
##
## 2: [DotPlatformIdentity], which four games extend or build, and the `player_admitted`
## and `player_renamed` events. A pack that names the class on a host without it does not
## refuse; it fails to PARSE mid-load, which is what this file turns into a sentence.
##
## 3: [member DotPlatformIdentity.avatar_translate_fn] and `use_backbone_avatars` — a
## game that sets the first on an older host is a script that does not compile.
##
## 4: [method DotPlatformModule.gates_spawn]. On a dot-server with the PROFILE stage (its
## level 7) admission finishes before the spawn, so `player_admitted` usually fires before
## `client_spawn`; a game's redraw handler finds nobody seated and does nothing, and the
## player is seated already resolved. Nothing a game called changed meaning, so OLDEST
## stays.
##
## 5: [member DotPlatformIdentity.use_backbone_profiles], [DotPlatformUsers] and
## [DotPlatformProfileStore]. With the host's integration credential a site-issued
## player's profile is read from and saved to the site; `users` is a [DotPlatformUsers],
## which is still a [DotUserManager], so nothing a game called changed meaning and OLDEST
## stays.

const LEVEL := 5
const OLDEST := 1
