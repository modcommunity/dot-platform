# dot-platform

Joins dot-auth, dot-user and dot-user-avatar into one admission flow, and binds it to
a dot-server.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, then
[`../../PLATFORM.md`](../../PLATFORM.md), which is the design this implements.

## Why this exists

Every other addon in the family is deliberately unaware of the others. That is the
rule that makes them adoptable one at a time, and it is worth keeping. The cost is
that **the handoffs between them existed only in prose** — each addon passed its own
self-test in isolation and nothing ran two of them together.

That is not a theoretical gap. The first time a real client was run against a real
server in one process, it found two bugs in dot-server that made joining impossible
in every configuration. Both had been there since the addon was written. See "What
the examples found".

So this repository is two things: a small addon that does the joining, and the
examples that are the only place the family is exercised as a whole.

## The one translation

```
identity.uid          "backbone:acc-1"     global; a server must never see this
   -> profile.user_key  "sWrM4ym4beWFH0Nx"  scoped; what everything else keys on
   -> avatar filed under the SAME scoped key
```

`DotPlatformHub` is the only place this happens. Keying the avatar on
`identity.uid` would pass every test in every other repository and quietly undo
dot-user's scoping, which is the single security property the platform design rests
on.

`DotPlatformPlayer.account_uid()` is named to be conspicuous. Anything that stores,
logs or transmits its result is undoing the scoping; it exists because admission needs
it exactly once.

## Everything optional stays optional

The managers are found through `DotRegistry`, never imported, and every absence has a
defined answer — no dot-user means no profile and no scoped key; no dot-user-avatar
means nobody has an avatar and nothing asks; neither means a player with a name and
nothing else. `_test_absent_addons` covers all three.

This is not politeness. A platform that required all three to start would be unusable
on day one of a project, which is when people decide whether to adopt something.

## What the examples found

Both bugs were in dot-server, both were on the join path, and both were invisible to
dot-server's own 104-check self-test because that runs a server with no client. Its
CLAUDE.md already said the handshake was uncovered; this is what was under it.

**Godot refuses an RPC unless both ends declare the same set of `@rpc` methods.** It
compares a checksum. `DotClientLink` declared `submit_chat` and `_receive_chat`, which
on the server live on `DotChatManager` — a different node. So the checksum differed
and *every* RPC between client and server was refused, handshake included. A client
opened a socket and then timed out with no other symptom. Fixed by moving them to
`DotClientChat`, a child named `Chat` to match the server's node, because **the name
is the routing**.

**A server with no game scene could not be joined.** `_load_game`'s empty-scene
branch reported ready and returned without entering `PLAYING`, starting the heartbeat
or emitting `spawned` — so the server spawned the session while the client sat in
`LOADING` sending nothing, until it was timed out for being idle. The comment beside
that branch calls a scene-less server "legitimate for a lobby". Both endings now go
through `_enter_playing()` so they cannot drift again.

The general lesson is the family's own: **a code path that only one deployment shape
reaches is a code path nothing has run.**

## Two MultiplayerAPI instances in one process

`sandbox_server` runs a server and a client in one tree. Both want
`SceneTree.multiplayer` and there is one of those, so each half gets its own via
`SceneTree.set_multiplayer(api, subtree_path)`.

Two things about that are worth knowing before touching this file:

- **RPCs are addressed by node path relative to each API root.** The client's
  `DotClientLink` is therefore named `Server`, matching the server's `DotServer`
  node under its own root. Any other name and every RPC fails with
  `Node not found: Server`. In a normal two-process deployment this is invisible
  because both are just "the game node".
- **This is the same mechanism dot-core needs for listening on UDP and WebSocket at
  once**, which is the open question in `PLATFORM.md`. This example is a working
  demonstration that the approach holds.

## The ordering limitation, and the fix that belongs in dot-server

dot-server's signon runs `CONNECTING -> AUTHENTICATING -> DOWNLOADING -> LOADING ->
SPAWNED`, and there is no cancellable stage between authentication and content. So
`DotPlatformModule` runs admission off `DotServer.client_state_changed` and finishes
shortly **after** dot-server has admitted the player, rather than gating it.

For a sandbox that is fine: a player briefly present with a default avatar is not a
problem, and both dot-user and dot-user-avatar degrade to something usable. For
`require_avatar` it is not enough.

The honest fix is a `PROFILE` stage in `DotClientSession` with its own timeout, for
the reason the existing stages are separate: a player stuck choosing a hairstyle has a
different problem from one stuck authenticating, and an operator has to be able to
tell which. This module is deliberately structured so that lands as a smaller file
rather than a rewrite.

## A naming mistake worth not repeating

The class is `DotPlatformHub`, not `DotPlatform`, because **dot-core already has a
`DotPlatform`** — the capability helper behind `DotPlatform.has_threads()`.
`class_name` is global in Godot and these addons install side by side, so the
collision was not a style problem: it made dot-core's own scripts fail to parse the
moment this addon was present, and the errors pointed at dot-auth, which mentions
neither class.

Check a proposed `class_name` against every addon in the family, not just the one
being written.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/dot_*/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

godot --headless --path . res://examples/seam_selftest.tscn      # 73 checks, 8 sections
godot --headless --path . res://examples/sandbox_server.tscn     # 26 checks
```

Every other addon is symlinked in and gitignored; `addons/dot_platform/` is the only
thing this repository ships. Create the links before validating:

```bash
for a in dot_core:dot-core dot_auth:dot-auth dot_user:dot-user \
         dot_user_avatar:dot-user-avatar dot_server:dot-server \
         dot_net:dot-net dot_player_controller:dot-player-controller; do
    ln -sfn "../../${a##*:}/addons/${a%%:*}" "addons/${a%%:*}"
done
```

**`sandbox_server` binds a real port (27077).** A failure there is as likely to be
the environment as the code; it fails rather than hangs, with the client's phase in
the message, which is usually enough to tell them apart.

**Add a case to `seam_selftest` for any change to a handoff.** It is the only test
that runs more than one of these addons at once, and the handoffs are the least
defended part of the family precisely because each addon is careful about its own
boundary and nothing owns the space between them.

## A wardrobe change reaches the game

`DotPlatformConfig.broadcast_avatar_changes` was documented from the first version and
read by nothing. It now does what it says, through the server rather than the wire:
`DotPlatformModule` connects the hub's `avatar_changed` and fires a
`player_avatar_changed` server event carrying the `userid` (and `peer_id`). A game
module `hook_post`s it and redresses the player for everybody by whatever path it
already has — game-g2gfast's bridge rebroadcasts the player's JOIN. dot-platform still
sends nothing to a client itself, which keeps it out of the netcode's business.

**`player_admitted` and `player_renamed` are the same seam for the other two moments.** Admission finishes after dot-server has spawned the player (see the ordering limitation above), so a game that read the name and avatar when it seated somebody read a guest's — and nothing told it when the real ones existed. The module now notifies `player_admitted` (`userid`, `peer_id`) once admission has applied the profile name, and a game hooks it to redraw exactly as it does for a wardrobe change. `platform_name` changed the profile and not the session, so the game went on using the old name; it sets `session.display_name` now and notifies `player_renamed` (`userid`, `peer_id`, `name`). `sandbox_server` checks both, and each fails with its line removed.

## A game's identity layer is `DotPlatformIdentity`

Every game built the same chain in front of this addon: dot-cloud (registered, or not built at all), the backbone client when the operator asked for one, dot-user, dot-user-avatar over the game's schema, and a hub — then `avatar_for(key)`, which falls back from what the platform resolved to a stock avatar. game-arena's copy was 262 lines and game-g2gfast's 215, and with the class names taken out they differed in one line. It lives here now, and a game hands it two things: `avatar_schema` and `stock_avatar_fn`. arena and g2gfast are twenty-line subclasses; mg-smash-copter and mg-buses-from-hell return one from dot-game's `_make_identity()`.

It names `DotCloudClient`, `DotUserManager`, `DotAvatarManager` and `DotBackboneClient`, which the hub itself does not. That adds no dependency: `dot_platform_player.gd` already names types from dot-auth, dot-user and dot-user-avatar, so none of them was ever optional at parse time — only at run time, which is what "Everything optional stays optional" above is about and which the hub still honours.

**And the stock look is the platform's answer too.** It hands `stock_avatar_fn` to the avatar manager as `default_avatar_fn`, so a first-time player admitted with nothing stored is resolved to the game's stock look for their scoped key rather than the schema's one default — which is what every admitted player in arena and g2gfast was wearing, identically, until 2026-10-03. The seam suite's "resolved to the game's stock look" checks it.

**`avatar_for` is never null while there is a schema.** Platform first, then the game's stock function, then `default_avatar()`. A game with no schema builds no avatar manager and gets null, which is the honest answer for a game with no avatars.

**`platform_module()` is a Node outside the tree until a server loads it.** One nothing loaded leaked with the hub it held — arena's copy had the leak, and the seam suite's "2 resources still in use" found it — so the layer frees an unparented module as it is deleted. One a server loaded is the server's.

`seam_selftest`'s eighth section drives it with real managers and a real ticket; "drawn in what the platform resolved for them" fails with the platform lookup removed.

## A module whose hub was freed admits nobody (2026-10-08)

`DotPlatformModule._on_client_state_changed` returns when `platform` is no longer a valid instance. The hub belongs to whatever built it (a game's `DotPlatformIdentity`), and a game change frees it; a module left loaded past that crashed the server on the next admission. dot-game now unloads the module it loaded, and this guard is what keeps any other host that forgets from crashing.

## Things deliberately not here

- **A game.** The sandbox example spawns a player and stops. What they do next —
  building, scripting, physics — is a game, and dot-player-controller and dot-net are
  what it would be built on.
- **The avatar editor UI.** dot-user-avatar's `choices_for` is what it would use.
- **Matchmaking, discovery, a server browser.** Backend work, named as the largest
  real gap in `PLATFORM.md`.
- **A PROFILE signon stage.** It belongs in dot-server; see above.

## A member's site avatar reaches the game (2026-10-04)

Until this date it reached none, for four independent reasons, and this addon held two of them. `DotPlatformIdentity` built its avatar manager over a LOCAL store, so nothing was ever read from the site; it now finds the host's `dot_backbone_client` in the registry and reads through the site's avatar route on that credential, read only (`use_backbone_avatars`, on). And the site's document is over its `builtin` schema, which every game's schema refuses; `avatar_translate_fn` is the game saying what those choices mean in its terms, passed to `DotAvatarManager.translate_fn`. The other two were dot-auth's (the key the site resolves; see its scoped introspection) and dot-server-deploy's (authentication off). `seam_selftest` checks the store and the translation and was armed. API level 3.

