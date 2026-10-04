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

const LEVEL := 3
const OLDEST := 1
