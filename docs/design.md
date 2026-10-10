# Design

Why dot-platform is shaped the way it is. The platform design it implements is [PLATFORM.md](../../../PLATFORM.md).

## Why this exists

Every other addon in the family is deliberately unaware of the others. That is the rule that makes them adoptable one at a time, and it is worth keeping. The cost is that **the handoffs between them existed only in prose**: each addon passed its own self-test in isolation and nothing ran two of them together. The first time a real client was run against a real server in one process, it found two bugs in dot-server that made joining impossible in every configuration ([history](history.md#what-the-first-run-together-found)).

So this repository is two things: a small addon that does the joining, and the examples that are the only place the family is exercised as a whole.

## The one translation

```
identity.uid          "backbone:acc-1"     global; a server must never see this
   -> profile.user_key  "sWrM4ym4beWFH0Nx"  scoped; what everything else keys on
   -> avatar filed under the SAME scoped key
```

`DotPlatformHub` is the only place this happens. Keying the avatar on `identity.uid` would pass every test in every other repository and quietly undo dot-user's scoping, which is the single security property the platform design rests on.

`DotPlatformPlayer.account_uid()` is named to be conspicuous. Anything that stores, logs or transmits its result is undoing the scoping; it exists because admission needs it exactly once.

## Everything optional stays optional

The managers are found through `DotRegistry`, never imported, and every absence has a defined answer: no dot-user means no profile and no scoped key; no dot-user-avatar means nobody has an avatar and nothing asks; neither means a player with a name and nothing else. `seam_selftest`'s "absent addons" section covers all three.

This is not politeness. A platform that required all three to start would be unusable on day one of a project, which is when people decide whether to adopt something.

Optional here means at run time. `dot_platform_player.gd` names types from dot-auth, dot-user and dot-user-avatar, and `DotPlatformIdentity` also names `DotCloudClient`, `DotUserManager`, `DotAvatarManager` and `DotBackboneClient`, so at parse time those addons are required.

## Admission runs after the spawn

dot-server's signon runs `CONNECTING -> AUTHENTICATING -> DOWNLOADING -> LOADING -> SPAWNED`, and there is no cancellable stage between authentication and content. So `DotPlatformModule` runs admission off `DotServer.client_state_changed` and finishes shortly **after** dot-server has admitted the player, rather than gating it.

For a sandbox that is fine: a player briefly present with a default avatar is not a problem, and both dot-user and dot-user-avatar degrade to something usable. For `require_avatar` it is not enough. The fix is a `PROFILE` stage in dot-server's client session with its own timeout, for the reason the existing stages are separate: a player stuck choosing a hairstyle has a different problem from one stuck authenticating, and an operator has to be able to tell which. dot-server has no such stage yet; this module is structured so that it lands as a smaller file rather than a rewrite.

## Three server events tell the game when to redraw

Because admission finishes after the spawn, a game that read the name and avatar when it seated somebody read a guest's. The module fires three server events, each carrying `userid` and `peer_id`, and a game `hook_post`s them and redraws by whatever path it already has (game-g2gfast's bridge rebroadcasts the player's JOIN):

- `player_admitted`, once admission has applied the profile name;
- `player_renamed` (plus `name`), after `session.display_name` is set;
- `player_avatar_changed`, from the hub's `avatar_changed` when `DotPlatformConfig.broadcast_avatar_changes` is on.

dot-platform sends nothing to a client itself, which keeps it out of the netcode's business. `sandbox_server` checks admitted and renamed, and each fails with its line removed.

## A game's identity layer is `DotPlatformIdentity`

Every game built the same chain in front of this addon: dot-cloud (registered, or not built at all), the backbone client when the operator asked for one, dot-user, dot-user-avatar over the game's schema, and a hub, then `avatar_for(key)`. Two games' copies differed in one line once the class names were taken out. It lives here, and a game hands it two things: `avatar_schema` and `stock_avatar_fn`. game-arena and game-g2gfast subclass it; the games on dot-game return one from `_make_identity()`.

- **The stock look is the platform's answer too.** It hands `stock_avatar_fn` to the avatar manager as `default_avatar_fn`, so a first-time player with nothing stored is resolved to the game's stock look for their scoped key rather than the schema's one default.
- **`avatar_for` is never null while there is a schema.** Platform first, then the game's stock function, then `default_avatar()`. A game with no schema builds no avatar manager and gets null, which is the honest answer for a game with no avatars.
- **`platform_module()` is a Node outside the tree until a server loads it.** One nothing loaded would leak with the hub it holds, so the layer frees an unparented module on `NOTIFICATION_PREDELETE`. One a server loaded is the server's.
- **A member's site avatar is read from the site.** With `use_backbone_avatars` (on), the layer finds the host's `dot_backbone_client` in the registry and reads through the site's avatar route on that credential, read only. The site's document is over its `builtin` schema, which every game's schema refuses; `avatar_translate_fn` is the game saying what those choices mean in its terms, passed to `DotAvatarManager.translate_fn`.

## A module whose hub was freed admits nobody

`DotPlatformModule._on_client_state_changed` returns when `platform` is no longer a valid instance. The hub belongs to whatever built it (a game's `DotPlatformIdentity`), and a game change frees it; a module left loaded past that would crash the server on the next admission. dot-game unloads the module it loaded, and this guard keeps any other host that forgets from crashing.

## Two MultiplayerAPI instances in one process

`sandbox_server` runs a server and a client in one tree. Both want `SceneTree.multiplayer` and there is one of those, so each half gets its own via `SceneTree.set_multiplayer(api, subtree_path)`.

**RPCs are addressed by node path relative to each API root.** The client's `DotClientLink` is therefore named `Server`, matching the server's `DotServer` node under its own root. Any other name and every RPC fails with `Node not found: Server`. In a normal two-process deployment this is invisible because both are just "the game node". The same holds for any child with RPCs: **the name is the routing**, and both ends must declare the same set of `@rpc` methods ([history](history.md#what-the-first-run-together-found)).

## Deliberately not here

- **A game.** The sandbox example spawns a player and stops. What they do next is a game, and dot-player-controller and dot-net are what it would be built on.
- **The avatar editor UI.** dot-user-avatar's `choices_for` is what it would use.
- **Matchmaking, discovery, a server browser.** dot-matchmaking and dot-browser.
- **A `PROFILE` signon stage.** It belongs in dot-server; see above.
