# History

Bugs worth recognising if they come back. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## What the first run together found

Both bugs were in dot-server, both were on the join path, and both were invisible to dot-server's own self-test because that runs a server with no client.

**Godot refuses an RPC unless both ends declare the same set of `@rpc` methods.** It compares a checksum. `DotClientLink` declared `submit_chat` and `_receive_chat`, which on the server live on `DotChatManager`, a different node. So the checksum differed and *every* RPC between client and server was refused, handshake included. A client opened a socket and then timed out with no other symptom. Fixed by moving them to `DotClientChat`, a child named `Chat` to match the server's node, because **the name is the routing**.

**A server with no game scene could not be joined.** The empty-scene branch of the load reported ready and returned without entering `PLAYING`, starting the heartbeat or emitting `spawned`, so the server spawned the session while the client sat in `LOADING` sending nothing, until it was timed out for being idle. A scene-less server is legitimate for a lobby. Both endings now go through `_enter_playing()` so they cannot drift again.

The lesson is the family's own: **a code path that only one deployment shape reaches is a code path nothing has run.**

## A class name that broke dot-core

The hub is `DotPlatformHub`, not `DotPlatform`, because **dot-core already has a `DotPlatform`** (the capability helper behind `DotPlatform.has_threads()`). `class_name` is global and these addons install side by side, so the collision made dot-core's own scripts fail to parse the moment this addon was present, and the errors pointed at dot-auth, which mentions neither class. Check a proposed `class_name` against every addon in the family, not just the one being written.

## Settings and moments nothing acted on

`DotPlatformConfig.broadcast_avatar_changes` was documented from the first version and read by nothing. Admission finished after the spawn, so games read a guest's name and avatar and nothing told them when the real ones existed; `platform_name` changed the profile and not the session, so the game went on using the old name. The three server events in [design](design.md#three-server-events-tell-the-game-when-to-redraw) are the fix.

## Every player wore the same default

Before `stock_avatar_fn` was handed on as `default_avatar_fn`, every first-time player admitted with nothing stored wore the schema's one default, identically, in every game using the identity layer. The seam suite's "resolved to the game's stock look" check covers it.

## A module nothing loaded leaked its hub

A game's own copy of the identity layer leaked the module it built when no server loaded it, with the hub it held; the seam suite's leaked-resources count at exit found it. The layer now frees an unparented module as it is deleted.

## A member's site avatar reached no game

It reached none, for four independent reasons, and this addon held two: the identity layer built its avatar manager over a LOCAL store, so nothing was ever read from the site; and the site's document is over its `builtin` schema, which every game's schema refused. `use_backbone_avatars` and `avatar_translate_fn` fixed those. The other two were dot-auth's (the key the site resolves) and dot-server-deploy's (authentication off).

## A freed hub crashed the server

A game change freed the hub while its module stayed loaded, and the next admission crashed the server. dot-game now unloads the module it loaded, and `_on_client_state_changed` checks the hub is still valid.

## Admission after the spawn, and a refusal that was a script error

Until dot-server had a `PROFILE` stage (2026-10-11), the module ran admission off `client_state_changed` and finished after dot-server had spawned the player: every player was seated as a guest and redrawn a moment later (which is why the three server events exist), and `require_avatar` could only act on somebody everyone had already seen join. It could not even do that: the refusal called `server.kick_session(...)`, which `DotServer` has never had. It parsed (the call is not checked against the script class), so the first refusal on a real server was `Invalid call. Nonexistent function 'kick_session'`, the admission coroutine died, and the refused player stayed in the game. Nothing ran a refusal through the module: `seam_selftest` calls the hub directly and `sandbox_server` only admitted. `sandbox_server` now refuses one player in the stage and one after it, and the second check fails with the old call put back.

